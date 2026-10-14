const { randomUUID } = require('crypto');
const { Prisma } = require('@prisma/client');
const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const { findRidesByIds, geographyPoint, utc } = require('./ride.service');

/*
 * Lock order: every transaction that touches both a ride and its bookings locks the Ride row
 * first, then Booking rows. Ride cancel must update the ride before its bookings, so anything
 * else taking them the other way round could deadlock against it.
 */

// Rows wait on each other's locks under contention (concurrent accepts on one ride).
const TX_OPTIONS = { maxWait: 10000, timeout: 15000 };

// Geo columns come back as GeoJSON.
const BOOKING_COLUMNS = Prisma.sql`
  b."id", b."rideId", b."riderId", b."status"::text AS "status", b."seats",
  b."pickupAddress", b."dropAddress",
  ST_AsGeoJSON(b."pickupPoint")::json AS "pickupPoint",
  ST_AsGeoJSON(b."dropPoint")::json AS "dropPoint",
  b."createdAt", b."updatedAt"`;

async function findBookingById(id) {
  const rows =
    await prisma.$queryRaw`SELECT ${BOOKING_COLUMNS} FROM "Booking" b WHERE b."id" = ${id}`;
  return rows[0];
}

/** Locks the ride for the rest of the transaction; null if it does not exist. */
async function lockRide(tx, rideId, mode = Prisma.sql`FOR UPDATE`) {
  const rows = await tx.$queryRaw`
    SELECT "driverId", "status"::text AS "status", "departureTime", "seatsAvailable"
    FROM "Ride" WHERE "id" = ${rideId} ${mode}`;
  return rows[0] ?? null;
}

/**
 * Requests `seats` on an OPEN, future ride the rider does not drive. The ride is share-locked so
 * it cannot be cancelled between the checks and the insert (which would strand a PENDING booking
 * on a CANCELLED ride). The partial unique index decides duplicates, so concurrent requests by
 * the same rider cannot both get in.
 */
async function requestBooking(riderId, rideId, { pickup, drop, seats }) {
  const id = randomUUID();
  await prisma.$transaction(async (tx) => {
    const ride = await lockRide(tx, rideId, Prisma.sql`FOR SHARE`);
    if (!ride) throw new AppError('RIDE_NOT_FOUND', 'Ride not found', 404);
    if (ride.driverId === riderId) {
      throw new AppError('CANNOT_BOOK_OWN_RIDE', 'You cannot book a seat on your own ride', 403);
    }
    if (ride.status !== 'OPEN') {
      throw new AppError('RIDE_NOT_BOOKABLE', `This ride is ${ride.status}`, 409);
    }
    if (ride.departureTime.getTime() <= Date.now()) {
      throw new AppError('RIDE_NOT_BOOKABLE', 'This ride has already departed', 409);
    }
    if (seats > ride.seatsAvailable) {
      throw new AppError(
        'NOT_ENOUGH_SEATS',
        `Only ${ride.seatsAvailable} seat(s) are available on this ride`,
        409,
      );
    }
    const inserted = await tx.$queryRaw`
      INSERT INTO "Booking" (
        "id", "rideId", "riderId", "pickupAddress", "dropAddress", "pickupPoint", "dropPoint",
        "seats", "createdAt", "updatedAt"
      ) VALUES (
        ${id}, ${rideId}, ${riderId}, ${pickup.address}, ${drop.address},
        ${geographyPoint(pickup)}, ${geographyPoint(drop)},
        ${seats}::int, (now() AT TIME ZONE 'UTC'), (now() AT TIME ZONE 'UTC')
      )
      ON CONFLICT ("rideId", "riderId") WHERE "status" IN ('PENDING', 'ACCEPTED') DO NOTHING
      RETURNING "id"`;
    if (inserted.length === 0) {
      throw new AppError(
        'BOOKING_EXISTS',
        'You already have a pending or accepted booking on this ride',
        409,
      );
    }
  }, TX_OPTIONS);
  return findBookingById(id);
}

/** All bookings on a ride the user drives, oldest first, with each rider's public fields. */
async function listRideBookings(userId, rideId) {
  const ride = await prisma.ride.findUnique({ where: { id: rideId }, select: { driverId: true } });
  if (!ride) throw new AppError('RIDE_NOT_FOUND', 'Ride not found', 404);
  if (ride.driverId !== userId) {
    throw new AppError('FORBIDDEN', "Only the driver can see this ride's bookings", 403);
  }
  return prisma.$queryRaw`
    SELECT ${BOOKING_COLUMNS},
           u."name" AS "riderName", u."ratingAvg" AS "riderRatingAvg",
           u."ratingCount" AS "riderRatingCount"
    FROM "Booking" b
    JOIN "User" u ON u."id" = b."riderId"
    WHERE b."rideId" = ${rideId}
    ORDER BY b."createdAt", b."id"`;
}

/**
 * The rider's bookings, each with its ride: rides departing now or later first (soonest first),
 * then past ones (most recent first), as in /rides/mine.
 */
async function listMyBookings(riderId) {
  const now = utc(new Date(Date.now()));
  const bookings = await prisma.$queryRaw`
    SELECT ${BOOKING_COLUMNS}
    FROM "Booking" b
    JOIN "Ride" r ON r."id" = b."rideId"
    WHERE b."riderId" = ${riderId}
    ORDER BY (r."departureTime" >= ${now}) DESC,
             CASE WHEN r."departureTime" >= ${now} THEN r."departureTime" END ASC,
             r."departureTime" DESC, b."createdAt" DESC, b."id"`;
  const rides = await findRidesByIds([...new Set(bookings.map((b) => b.rideId))]);
  const rideById = new Map(rides.map((r) => [r.id, r]));
  return bookings.map((b) => ({ ...b, ride: rideById.get(b.rideId) }));
}

module.exports = { requestBooking, listRideBookings, listMyBookings };
