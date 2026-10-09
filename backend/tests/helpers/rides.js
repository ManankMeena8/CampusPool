const { randomUUID } = require('crypto');
const request = require('supertest');
const { signAccessToken } = require('../../src/lib/tokens');
const { app, prisma, emailFor } = require('./auth');

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const bearer = (token) => ({ Authorization: `Bearer ${token}` });

// Asymmetric coordinates (lat far from lng) so a lat/lng swap cannot go unnoticed.
const START = { lat: 12.971599, lng: 77.594566, address: 'MG Road, Bengaluru' };
const END = { lat: 12.9784, lng: 77.6408, address: 'Indiranagar, Bengaluru' };

/** A routing result as routing.service returns it (GeoJSON order: [lng, lat]). */
function fakeRoute(overrides = {}) {
  return {
    geometry: {
      type: 'LineString',
      coordinates: [
        [START.lng, START.lat],
        [77.6006, 12.9756],
        [END.lng, END.lat],
      ],
    },
    distanceMeters: 6844,
    durationSeconds: 812,
    startSnapMeters: 12.3,
    endSnapMeters: 4.1,
    ...overrides,
  };
}

/**
 * Inserts a verified user directly and signs a token for them: ride tests do not need to
 * repeat the signup/OTP flow (covered by the auth tests), which costs several remote queries.
 */
async function createUser(label, role = 'DRIVER') {
  const user = await prisma.user.create({
    data: {
      name: `${label} name`,
      email: emailFor(label),
      passwordHash: 'not-used-by-ride-tests',
      isVerified: true,
      role,
    },
  });
  return { token: signAccessToken(user), user };
}

function rideBody(overrides = {}) {
  return {
    start: START,
    end: END,
    departureTime: new Date(Date.now() + DAY).toISOString(),
    seats: 3,
    pricePerSeat: 50,
    notes: 'Leaving from gate 2',
    ...overrides,
  };
}

function postRide(token, body = rideBody()) {
  return request(app).post('/rides').set(bearer(token)).send(body);
}

// Length of one degree of latitude near START (~13°N) on the WGS84 ellipsoid PostGIS measures on.
const METERS_PER_DEGREE_LAT = 110650;

/** `point` moved `meters` due north (approximate: tests compare distances with a tolerance). */
function offsetNorth(point, meters) {
  return { ...point, lat: point.lat + meters / METERS_PER_DEGREE_LAT };
}

/**
 * Inserts a ride directly, skipping POST /rides: tests can then create rides in any status, in
 * the past, or overlapping, at a fraction of the remote round-trips. Resolves to its id.
 */
async function insertRide(driverId, overrides = {}) {
  const {
    start = START,
    end = END,
    departureTime = new Date(Date.now() + DAY),
    status = 'OPEN',
    seatsTotal = 3,
    seatsAvailable = seatsTotal,
  } = overrides;
  const id = randomUUID();
  await prisma.$executeRaw`
    INSERT INTO "Ride" (
      "id", "driverId", "startAddress", "endAddress", "startPoint", "endPoint",
      "departureTime", "seatsTotal", "seatsAvailable", "status", "createdAt", "updatedAt"
    ) VALUES (
      ${id}, ${driverId}, ${start.address}, ${end.address},
      ST_SetSRID(ST_MakePoint(${start.lng}::float8, ${start.lat}::float8), 4326)::geography,
      ST_SetSRID(ST_MakePoint(${end.lng}::float8, ${end.lat}::float8), 4326)::geography,
      (${departureTime.toISOString()}::timestamptz AT TIME ZONE 'UTC'),
      ${seatsTotal}, ${seatsAvailable}, ${status}::"RideStatus", now(), now()
    )`;
  return id;
}

module.exports = {
  offsetNorth,
  insertRide,
  MINUTE,
  HOUR,
  DAY,
  START,
  END,
  bearer,
  fakeRoute,
  createUser,
  rideBody,
  postRide,
};
