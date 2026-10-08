const { randomUUID } = require('crypto');
const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const routing = require('./routing.service');

const HOUR_MS = 60 * 60 * 1000;
const OVERLAP_WINDOW_MS = HOUR_MS;
const SNAP_WARNING_METERS = 300;
const ACTIVE_STATUSES = ['OPEN', 'FULL', 'IN_PROGRESS'];

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

/**
 * Selects one ride with geo columns as GeoJSON and the driver's public fields.
 * Timestamps are written and compared as UTC explicitly, whatever the session time zone.
 */
async function findRideById(id) {
  const rows = await prisma.$queryRaw`
    SELECT r."id", r."driverId", r."status"::text AS "status",
           r."startAddress", r."endAddress",
           ST_AsGeoJSON(r."startPoint")::json AS "startPoint",
           ST_AsGeoJSON(r."endPoint")::json AS "endPoint",
           ST_AsGeoJSON(r."routeLine")::json AS "routeLine",
           r."distanceMeters", r."durationSeconds", r."departureTime",
           r."seatsTotal", r."seatsAvailable", r."pricePerSeat", r."notes",
           r."createdAt", r."updatedAt",
           u."name" AS "driverName", u."ratingAvg" AS "driverRatingAvg",
           u."ratingCount" AS "driverRatingCount"
    FROM "Ride" r
    JOIN "User" u ON u."id" = r."driverId"
    WHERE r."id" = ${id}`;
  return rows[0] ?? null;
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
          (${departureTime.toISOString()}::timestamptz AT TIME ZONE 'UTC'),
          ${seats}, ${seats}, ${pricePerSeat}, ${notes},
          (now() AT TIME ZONE 'UTC'), (now() AT TIME ZONE 'UTC')
        )`;
    },
    { timeout: 15000 }, // the test/dev database is remote (~250 ms per query)
  );

  return { ride: await findRideById(id), warnings: snapWarnings(route) };
}

module.exports = { createRide, findRideById, OVERLAP_WINDOW_MS, SNAP_WARNING_METERS };
