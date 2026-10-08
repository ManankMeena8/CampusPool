const { randomUUID } = require('crypto');
const { Prisma } = require('@prisma/client');
const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const routing = require('./routing.service');

const HOUR_MS = 60 * 60 * 1000;
const OVERLAP_WINDOW_MS = HOUR_MS;
const SNAP_WARNING_METERS = 300;
const ACTIVE_STATUSES = ['OPEN', 'FULL', 'IN_PROGRESS'];
const CANCELLABLE_STATUSES = ['OPEN', 'FULL'];

/** Rejects if the driver has an active ride departing less than an hour before or after `departureTime`. */
async function assertNoOverlap(db, driverId, departureTime) {
  const clash = await db.ride.findFirst({
    where: {
      driverId,
      status: { in: ACTIVE_STATUSES },
      departureTime: {
        gt: new Date(departureTime.getTime() - OVERLAP_WINDOW_MS),
        lt: new Date(departureTime.getTime() + OVERLAP_WINDOW_MS),
      },
    },
    select: { departureTime: true },
  });
  if (clash) {
    throw new AppError(
      'RIDE_OVERLAP',
      `You already have a ride departing at ${clash.departureTime.toISOString()}; ` +
        'rides must be at least 1 hour apart',
      409,
    );
  }
}

function snapWarnings(route) {
  if (!route) return [];
  const warnings = [];
  if (route.startSnapMeters > SNAP_WARNING_METERS) warnings.push('start point is far from a road');
  if (route.endSnapMeters > SNAP_WARNING_METERS) warnings.push('end point is far from a road');
  return warnings;
}

// Geo columns come back as GeoJSON; the driver only by public fields (no email or phone).
const RIDE_COLUMNS = Prisma.sql`
  r."id", r."driverId", r."status"::text AS "status",
  r."startAddress", r."endAddress",
  ST_AsGeoJSON(r."startPoint")::json AS "startPoint",
  ST_AsGeoJSON(r."endPoint")::json AS "endPoint",
  r."distanceMeters", r."durationSeconds", r."departureTime",
  r."seatsTotal", r."seatsAvailable", r."pricePerSeat", r."notes",
  r."createdAt", r."updatedAt",
  u."name" AS "driverName", u."ratingAvg" AS "driverRatingAvg",
  u."ratingCount" AS "driverRatingCount"`;

// Timestamps are stored as UTC without a zone; convert explicitly, whatever the session time zone.
const utc = (date) => Prisma.sql`(${date.toISOString()}::timestamptz AT TIME ZONE 'UTC')`;

/** One ride with its route line, or null. */
async function findRideById(id) {
  const rows = await prisma.$queryRaw`
    SELECT ${RIDE_COLUMNS}, ST_AsGeoJSON(r."routeLine")::json AS "routeLine"
    FROM "Ride" r
    JOIN "User" u ON u."id" = r."driverId"
    WHERE r."id" = ${id}`;
  return rows[0] ?? null;
}

/**
 * All of a driver's rides, without route lines: rides departing now or later first (soonest
 * first), then past ones (most recent first). Status is not considered, so an OPEN ride whose
 * departure has passed sorts with the past ones but is still OPEN.
 */
function findRidesByDriver(driverId) {
  const now = utc(new Date(Date.now()));
  return prisma.$queryRaw`
    SELECT ${RIDE_COLUMNS}
    FROM "Ride" r
    JOIN "User" u ON u."id" = r."driverId"
    WHERE r."driverId" = ${driverId}
    ORDER BY (r."departureTime" >= ${now}) DESC,
             CASE WHEN r."departureTime" >= ${now} THEN r."departureTime" END ASC,
             r."departureTime" DESC`;
}

async function getRide(id) {
  const ride = await findRideById(id);
  if (!ride) throw new AppError('RIDE_NOT_FOUND', 'Ride not found', 404);
  return ride;
}

async function createRide(driverId, input) {
  const { start, end, departureTime, seats, pricePerSeat, notes } = input;

  // Fail fast before spending a routing call; re-checked under a lock below.
  await assertNoOverlap(prisma, driverId, departureTime);

  // Outside the transaction: never hold a row lock while waiting on the network.
  const route = await routing.getDrivingRoute(start, end);
  const routeGeoJson = route ? JSON.stringify(route.geometry) : null;

  const id = randomUUID();
  await prisma.$transaction(
    async (tx) => {
      // Serializes concurrent posts by the same driver so both cannot pass the overlap check.
      await tx.$queryRaw`SELECT 1 FROM "User" WHERE "id" = ${driverId} FOR UPDATE`;
      await assertNoOverlap(tx, driverId, departureTime);
      await tx.$executeRaw`
        INSERT INTO "Ride" (
          "id", "driverId", "startAddress", "endAddress", "startPoint", "endPoint", "routeLine",
          "distanceMeters", "durationSeconds", "departureTime",
          "seatsTotal", "seatsAvailable", "pricePerSeat", "notes", "createdAt", "updatedAt"
        ) VALUES (
          ${id}, ${driverId}, ${start.address}, ${end.address},
          ST_SetSRID(ST_MakePoint(${start.lng}::float8, ${start.lat}::float8), 4326)::geography,
          ST_SetSRID(ST_MakePoint(${end.lng}::float8, ${end.lat}::float8), 4326)::geography,
          ST_SetSRID(ST_GeomFromGeoJSON(${routeGeoJson}::text), 4326)::geography,
          ${route?.distanceMeters ?? null}::int, ${route?.durationSeconds ?? null}::int,
          ${utc(departureTime)},
          ${seats}, ${seats}, ${pricePerSeat}, ${notes},
          (now() AT TIME ZONE 'UTC'), (now() AT TIME ZONE 'UTC')
        )`;
    },
    { timeout: 15000 }, // the test/dev database is remote (~250 ms per query)
  );

  return { ride: await findRideById(id), warnings: snapWarnings(route) };
}

/**
 * Cancels the ride if `driverId` drives it and it is OPEN or FULL. The check and the update are
 * one conditional UPDATE, so a concurrent status change cannot slip in between; the ride is only
 * re-read to pick the right error.
 */
async function cancelRide(driverId, id) {
  const { count } = await prisma.ride.updateMany({
    where: { id, driverId, status: { in: CANCELLABLE_STATUSES } },
    data: { status: 'CANCELLED' },
  });
  if (count === 0) {
    const ride = await prisma.ride.findUnique({
      where: { id },
      select: { driverId: true, status: true },
    });
    if (!ride) throw new AppError('RIDE_NOT_FOUND', 'Ride not found', 404);
    if (ride.driverId !== driverId) {
      throw new AppError('FORBIDDEN', 'Only the driver can cancel this ride', 403);
    }
    throw new AppError(
      'RIDE_NOT_CANCELLABLE',
      `A ${ride.status} ride cannot be cancelled; only OPEN or FULL rides can`,
      409,
    );
  }
  return findRideById(id);
}

module.exports = {
  cancelRide,
  createRide,
  getRide,
  findRidesByDriver,
  OVERLAP_WINDOW_MS,
  SNAP_WARNING_METERS,
};
