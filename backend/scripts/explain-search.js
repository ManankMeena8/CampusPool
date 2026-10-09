// Prints the EXPLAIN (ANALYZE, BUFFERS) plan of the real ride search query and checks that a GIST
// index is used. Usage: npm run explain:search
//
// With a handful of rows Postgres scans the whole table whatever the indexes, so this inserts
// ~20k rides spread over ~110 x 110 km around Bengaluru, departing over the next 7 days, then
// runs ANALYZE. Everything happens in one transaction that is always rolled back (the rows, the
// throwaway driver and the ANALYZE statistics), so the dev database is left as it was.
const { assertDevelopment } = require('./devOnly');

assertDevelopment('explain:search');

const { randomUUID } = require('crypto');
const { Prisma } = require('@prisma/client');
const prisma = require('../src/lib/prisma');
const { buildSearchQuery } = require('../src/services/ride.service');

const RIDE_COUNT = 20000;
const CENTER = { lat: 12.971599, lng: 77.594566 }; // MG Road, Bengaluru
const SPREAD_DEGREES = 0.5; // each side of CENTER, ~55 km
const GIST_INDEXES = ['Ride_startPoint_idx', 'Ride_endPoint_idx'];
const HOUR_MS = 60 * 60 * 1000;

class Rollback extends Error {}

async function explainWithSeededRides() {
  let plan;
  try {
    await prisma.$transaction(
      async (tx) => {
        const driverId = randomUUID();
        await tx.$executeRaw`
          INSERT INTO "User" ("id", "name", "email", "passwordHash", "role", "isVerified", "updatedAt")
          VALUES (${driverId}, 'EXPLAIN driver', ${`explain-${driverId}@example.invalid`},
                  'not-a-real-hash', 'DRIVER', true, now())`;

        await tx.$executeRaw`SELECT setseed(0.42)`; // same data, and so the same plan, every run
        const half = SPREAD_DEGREES;
        await tx.$executeRaw`
          INSERT INTO "Ride" (
            "id", "driverId", "startAddress", "endAddress", "startPoint", "endPoint",
            "departureTime", "seatsTotal", "seatsAvailable", "status", "createdAt", "updatedAt"
          )
          SELECT gen_random_uuid()::text, ${driverId}, 'explain start', 'explain end',
                 ST_SetSRID(ST_MakePoint(${CENTER.lng}::float8 + (random() * 2 - 1) * ${half}::float8,
                                         ${CENTER.lat}::float8 + (random() * 2 - 1) * ${half}::float8),
                            4326)::geography,
                 ST_SetSRID(ST_MakePoint(${CENTER.lng}::float8 + (random() * 2 - 1) * ${half}::float8,
                                         ${CENTER.lat}::float8 + (random() * 2 - 1) * ${half}::float8),
                            4326)::geography,
                 (now() AT TIME ZONE 'UTC') + interval '1 hour' + random() * interval '7 days',
                 4, 1 + floor(random() * 4)::int,
                 (CASE WHEN random() < 0.9 THEN 'OPEN' ELSE 'CANCELLED' END)::"RideStatus",
                 now(), now()
          FROM generate_series(1, ${RIDE_COUNT}::int)`;
        await tx.$executeRaw`ANALYZE "Ride"`;

        const now = Date.now();
        const query = buildSearchQuery(randomUUID(), {
          pickupLat: CENTER.lat,
          pickupLng: CENTER.lng,
          dropLat: 12.9784,
          dropLng: 77.6408,
          from: new Date(now + HOUR_MS),
          to: new Date(now + 25 * HOUR_MS),
          seats: 1,
          radius: 2000,
          limit: 20,
          offset: 0,
        });
        const rows = await tx.$queryRaw(
          Prisma.sql`EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) ${query}`,
        );
        plan = rows.map((row) => row['QUERY PLAN']).join('\n');
        throw new Rollback();
      },
      { maxWait: 10000, timeout: 120000 }, // the dev database is remote
    );
  } catch (err) {
    if (!(err instanceof Rollback)) throw err;
  }
  return plan;
}

async function main() {
  console.log(`Inserting ${RIDE_COUNT} rides in a transaction that will be rolled back...`);
  const plan = await explainWithSeededRides();
  console.log(`\n${plan}\n`);

  const used = GIST_INDEXES.filter((name) => plan.includes(name));
  if (used.length) {
    console.log(`GIST index used: ${used.join(', ')}`);
  } else {
    console.log(`No GIST index (${GIST_INDEXES.join(', ')}) in the plan.`);
    process.exitCode = 1;
  }
  console.log('Rolled back: no rides, users or statistics were kept.');
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
