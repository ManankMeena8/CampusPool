const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma } = require('./auth');
const { bearer, offsetNorth, START, END } = require('./rides');

// Near the ride's ends but not on them, and asymmetric, so a lat/lng swap cannot go unnoticed.
const PICKUP = { ...offsetNorth(START, 150), address: 'Trinity Circle, Bengaluru' };
const DROP = { ...offsetNorth(END, -150), address: 'CMH Road, Bengaluru' };

function bookingBody(overrides = {}) {
  return { pickup: PICKUP, drop: DROP, seats: 1, ...overrides };
}

function requestBooking(token, rideId, body = bookingBody()) {
  return request(app).post(`/rides/${rideId}/bookings`).set(bearer(token)).send(body);
}

/** POSTs /bookings/:id/<action> (accept, reject or cancel). */
function act(token, bookingId, action) {
  return request(app).post(`/bookings/${bookingId}/${action}`).set(bearer(token));
}

/**
 * Inserts a booking directly, in any status, skipping the request checks. Seats are NOT taken
 * from the ride: set the ride's seatsAvailable to match when inserting ACCEPTED bookings.
 */
async function insertBooking(rideId, riderId, { status = 'PENDING', seats = 1 } = {}) {
  const id = randomUUID();
  await prisma.$executeRaw`
    INSERT INTO "Booking" (
      "id", "rideId", "riderId", "pickupAddress", "dropAddress", "pickupPoint", "dropPoint",
      "seats", "status", "createdAt", "updatedAt"
    ) VALUES (
      ${id}, ${rideId}, ${riderId}, ${PICKUP.address}, ${DROP.address},
      ST_SetSRID(ST_MakePoint(${PICKUP.lng}::float8, ${PICKUP.lat}::float8), 4326)::geography,
      ST_SetSRID(ST_MakePoint(${DROP.lng}::float8, ${DROP.lat}::float8), 4326)::geography,
      ${seats}, ${status}::"BookingStatus", now(), now()
    )`;
  return id;
}

const bookingStatus = async (id) =>
  (await prisma.booking.findUniqueOrThrow({ where: { id }, select: { status: true } })).status;

const rideSeats = (id) =>
  prisma.ride.findUniqueOrThrow({
    where: { id },
    select: { seatsAvailable: true, seatsTotal: true, status: true },
  });

/**
 * Calls `start()` (which sends the concurrent requests) while another connection holds the ride's
 * row lock, and releases it once `waiters` statements are queued on locks. Without this the
 * requests often run one after another and a race-prone implementation can still pass. Throws if
 * they never all queue, rather than pass a test that raced nothing.
 */
async function whileRideLocked(rideId, waiters, start) {
  let pending;
  let queued = 0;
  await prisma.$transaction(
    async (tx) => {
      await tx.$queryRaw`SELECT 1 FROM "Ride" WHERE "id" = ${rideId} FOR UPDATE`;
      pending = start();
      const deadline = Date.now() + 5000;
      while (queued < waiters && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
        // Not through `tx`: pg_stat_activity is snapshotted once per transaction.
        [{ queued }] = await prisma.$queryRaw`
          SELECT count(*)::int AS "queued" FROM pg_stat_activity
          WHERE datname = current_database() AND wait_event_type = 'Lock'`;
      }
    },
    { timeout: 10000 },
  );
  const results = await pending;
  if (queued < waiters) throw new Error(`Only ${queued} of ${waiters} requests queued on locks`);
  return results;
}

module.exports = {
  PICKUP,
  DROP,
  bookingBody,
  requestBooking,
  act,
  insertBooking,
  bookingStatus,
  rideSeats,
  whileRideLocked,
};
