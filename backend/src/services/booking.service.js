const { randomUUID } = require('crypto');
const { Prisma } = require('@prisma/client');
const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const { BOOKING_ACTIONS, assertTransition } = require('../lib/bookingTransitions');
const { findRidesByIds, geographyPoint, utc } = require('./ride.service');
const realtime = require('../realtime/hub');
const notify = require('../lib/notify');

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
  const driverId = await prisma.$transaction(async (tx) => {
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
    return ride.driverId;
  }, TX_OPTIONS);
  notify('bookingRequested', { bookingId: id, driverId });
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

async function loadBooking(id) {
  const booking = await prisma.booking.findUnique({
    where: { id },
    select: {
      id: true,
      rideId: true,
      riderId: true,
      seats: true,
      status: true,
      ride: { select: { driverId: true } },
    },
  });
  if (!booking) throw new AppError('BOOKING_NOT_FOUND', 'Booking not found', 404);
  return booking;
}

/** Loads a booking for an action only the ride's driver may take, and pre-checks the transition. */
async function loadForDriver(driverId, id, action) {
  const booking = await loadBooking(id);
  if (booking.ride.driverId !== driverId) {
    throw new AppError('FORBIDDEN', `Only the ride's driver can ${action} this booking`, 403);
  }
  assertTransition(action, booking.status);
  return booking;
}

/**
 * Applies `action` as one conditional UPDATE guarded by its allowed `from` statuses. If another
 * request changed the booking first, nothing is updated and the fresh status picks the 409.
 */
async function applyTransition(db, action, id) {
  const { from, to } = BOOKING_ACTIONS[action];
  const { count } = await db.booking.updateMany({
    where: { id, status: { in: from } },
    data: { status: to },
  });
  if (count === 0) {
    const { status } = await db.booking.findUniqueOrThrow({
      where: { id },
      select: { status: true },
    });
    assertTransition(action, status);
    throw new AppError('INVALID_TRANSITION', 'The booking was changed by another request', 409);
  }
}

/** Why the seat decrement matched no row, as the 409 to send. */
async function seatUnavailable(tx, booking) {
  // Accepted (or cancelled) concurrently: report that, not the seats it took.
  const { status } = await tx.booking.findUniqueOrThrow({
    where: { id: booking.id },
    select: { status: true },
  });
  assertTransition('accept', status);
  const ride = await tx.ride.findUniqueOrThrow({
    where: { id: booking.rideId },
    select: { status: true, seatsAvailable: true, departureTime: true },
  });
  let reason;
  if (ride.status !== 'OPEN') reason = `the ride is ${ride.status}`;
  else if (ride.departureTime.getTime() <= Date.now()) reason = 'the ride has already departed';
  else reason = `${ride.seatsAvailable} seat(s) left, ${booking.seats} requested`;
  return new AppError('SEAT_UNAVAILABLE', `Cannot accept this booking: ${reason}`, 409);
}

/**
 * Accepts a PENDING booking and takes its seats, in one transaction. The seat check and the
 * decrement are a single conditional UPDATE on the ride (which also locks it, per the lock
 * order), so concurrent accepts queue on the ride row and re-check the seats they find. If the
 * booking was accepted meanwhile, its conditional UPDATE matches nothing and the transaction
 * rolls back, seats included.
 */
async function acceptBooking(driverId, id) {
  const booking = await loadForDriver(driverId, id, 'accept');
  await prisma.$transaction(async (tx) => {
    const seated = await tx.$queryRaw`
      UPDATE "Ride"
      SET "seatsAvailable" = "seatsAvailable" - ${booking.seats}::int,
          "status" = CASE WHEN "seatsAvailable" - ${booking.seats}::int = 0
                          THEN 'FULL'::"RideStatus" ELSE "status" END,
          "updatedAt" = (now() AT TIME ZONE 'UTC')
      WHERE "id" = ${booking.rideId}
        AND "seatsAvailable" >= ${booking.seats}::int
        AND "status" = 'OPEN'
        AND "departureTime" > ${utc(new Date(Date.now()))}
      RETURNING "id"`;
    if (seated.length === 0) throw await seatUnavailable(tx, booking);
    await applyTransition(tx, 'accept', id);
  }, TX_OPTIONS);
  notify('bookingAccepted', { bookingId: id, riderId: booking.riderId });
  return findBookingById(id);
}

/** Rejects a PENDING booking. No seats were taken, so the ride is not touched (or locked). */
async function rejectBooking(driverId, id) {
  const booking = await loadForDriver(driverId, id, 'reject');
  await applyTransition(prisma, 'reject', id);
  notify('bookingRejected', { bookingId: id, riderId: booking.riderId });
  return findBookingById(id);
}

/**
 * The rider cancels a PENDING or ACCEPTED booking on an OPEN or FULL ride. An ACCEPTED booking
 * gives its seats back and a FULL ride reopens, in the same transaction. The status that decides
 * this is read under the ride lock and a row lock, so a concurrent accept cannot slip between.
 */
async function cancelBooking(riderId, id) {
  const booking = await loadBooking(id);
  if (booking.riderId !== riderId) {
    throw new AppError('FORBIDDEN', 'Only the rider who made this booking can cancel it', 403);
  }
  assertTransition('cancel', booking.status);
  const previous = await prisma.$transaction(async (tx) => {
    const ride = await lockRide(tx, booking.rideId);
    const [{ status }] = await tx.$queryRaw`
      SELECT "status"::text AS "status" FROM "Booking" WHERE "id" = ${id} FOR UPDATE`;
    assertTransition('cancel', status);
    if (!['OPEN', 'FULL'].includes(ride.status)) {
      throw new AppError(
        'BOOKING_NOT_CANCELLABLE',
        `A booking on a ${ride.status} ride cannot be cancelled`,
        409,
      );
    }
    await applyTransition(tx, 'cancel', id);
    if (status === 'ACCEPTED') {
      // Ride_seats_check makes a double return fail loudly instead of exceeding seatsTotal.
      await tx.$executeRaw`
        UPDATE "Ride"
        SET "seatsAvailable" = "seatsAvailable" + ${booking.seats}::int,
            "status" = CASE WHEN "status" = 'FULL' THEN 'OPEN'::"RideStatus" ELSE "status" END,
            "updatedAt" = (now() AT TIME ZONE 'UTC')
        WHERE "id" = ${booking.rideId}`;
    }
    return status;
  }, TX_OPTIONS);
  // After the commit: an ACCEPTED rider stops following the ride (others never could).
  if (previous === 'ACCEPTED') await realtime.riderRemoved(booking.rideId, riderId);
  notify('bookingCancelled', {
    bookingId: id,
    driverId: booking.ride.driverId,
    wasAccepted: previous === 'ACCEPTED',
  });
  return findBookingById(id);
}

module.exports = {
  requestBooking,
  listRideBookings,
  listMyBookings,
  acceptBooking,
  rejectBooking,
  cancelBooking,
};
