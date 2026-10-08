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

module.exports = {
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
