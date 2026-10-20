jest.mock('../src/services/notification.service');

const request = require('supertest');
const notifications = require('../src/services/notification.service');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, bearer, createUser, insertRide } = require('./helpers/rides');
const { requestBooking, act, insertBooking, bookingStatus } = require('./helpers/bookings');

const EVENTS = [
  'bookingRequested',
  'bookingAccepted',
  'bookingRejected',
  'bookingCancelled',
  'bookingAutoRejected',
  'rideCancelled',
  'rideStarted',
];

beforeEach(async () => {
  await resetDb();
  jest.resetAllMocks();
});
afterAll(() => prisma.$disconnect());

/** The events sent, as { event: [payload, ...] }, leaving out those never called. */
function sent() {
  return Object.fromEntries(
    EVENTS.filter((e) => notifications[e].mock.calls.length > 0).map((e) => [
      e,
      notifications[e].mock.calls.map(([payload]) => payload),
    ]),
  );
}

const ids = (...users) => users.map((u) => u.user.id);
// Recipient lists come in database order: compare them as sets.
const normalize = (events) =>
  JSON.parse(JSON.stringify(events, (key, v) => (key === 'riderIds' ? [...v].sort() : v)));

/** A driver, two riders and a ride departing in 10 minutes (so it can be started). */
async function setup(rideOverrides = {}) {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const other = await createUser('other', 'RIDER');
  const rideId = await insertRide(driver.user.id, {
    departureTime: new Date(Date.now() + 10 * MINUTE),
    ...rideOverrides,
  });
  return { driver, rider, other, rideId };
}

const startRide = (token, rideId) => request(app).post(`/rides/${rideId}/start`).set(bearer(token));
const cancelRide = (token, rideId) =>
  request(app).post(`/rides/${rideId}/cancel`).set(bearer(token));

/*
 * Each case performs one action and states the notifications it must send. Shared by the
 * recipient tests and the "sending fails" tests below.
 */
const CASES = {
  async bookingRequested() {
    const { driver, rider, rideId } = await setup();
    const res = await requestBooking(rider.token, rideId).expect(201);
    const bookingId = res.body.booking.id;
    return {
      expected: { bookingRequested: [{ bookingId, driverId: driver.user.id }] },
      committed: async () => expect(await bookingStatus(bookingId)).toBe('PENDING'),
    };
  },

  async bookingAccepted() {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    await act(driver.token, bookingId, 'accept').expect(200);
    return {
      expected: { bookingAccepted: [{ bookingId, riderId: rider.user.id }] },
      committed: async () => expect(await bookingStatus(bookingId)).toBe('ACCEPTED'),
    };
  },

  async bookingRejected() {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    await act(driver.token, bookingId, 'reject').expect(200);
    return {
      expected: { bookingRejected: [{ bookingId, riderId: rider.user.id }] },
      committed: async () => expect(await bookingStatus(bookingId)).toBe('REJECTED'),
    };
  },

  async bookingCancelled() {
    const { driver, rider, rideId } = await setup({ seatsAvailable: 2 });
    const bookingId = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    await act(rider.token, bookingId, 'cancel').expect(200);
    return {
      expected: {
        bookingCancelled: [{ bookingId, driverId: driver.user.id, wasAccepted: true }],
      },
      committed: async () => expect(await bookingStatus(bookingId)).toBe('CANCELLED'),
    };
  },

  async rideCancelled() {
    const { driver, rider, other, rideId } = await setup({ seatsAvailable: 2 });
    const third = await createUser('third', 'RIDER');
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    await insertBooking(rideId, other.user.id);
    await insertBooking(rideId, third.user.id, { status: 'REJECTED' });
    await cancelRide(driver.token, rideId).expect(200);
    return {
      expected: { rideCancelled: [{ rideId, riderIds: ids(rider, other) }] },
      committed: async () =>
        expect((await prisma.ride.findUniqueOrThrow({ where: { id: rideId } })).status).toBe(
          'CANCELLED',
        ),
    };
  },

  async rideStarted() {
    const { driver, rider, other, rideId } = await setup({ seatsAvailable: 2 });
    const third = await createUser('third', 'RIDER');
    const gone = await createUser('gone', 'RIDER');
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    const pending = await insertBooking(rideId, other.user.id);
    await insertBooking(rideId, third.user.id, { status: 'REJECTED' });
    await insertBooking(rideId, gone.user.id, { status: 'CANCELLED' });
    await startRide(driver.token, rideId).expect(200);
    return {
      expected: {
        rideStarted: [{ rideId, riderIds: ids(rider) }],
        bookingAutoRejected: [{ rideId, riderIds: ids(other) }],
      },
      committed: async () => expect(await bookingStatus(pending)).toBe('REJECTED'),
    };
  },
};

describe('recipients', () => {
  it.each(Object.keys(CASES))('%s notifies exactly the right users', async (name) => {
    const { expected } = await CASES[name]();
    expect(normalize(sent())).toEqual(normalize(expected));
  });

  it('tells the driver when a PENDING request is cancelled, with no seat freed', async () => {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    await act(rider.token, bookingId, 'cancel').expect(200);
    expect(sent()).toEqual({
      bookingCancelled: [{ bookingId, driverId: driver.user.id, wasAccepted: false }],
    });
  });

  it('starts a ride without bookings with empty recipient lists', async () => {
    const { driver, rideId } = await setup();
    await startRide(driver.token, rideId).expect(200);
    expect(sent()).toEqual({
      rideStarted: [{ rideId, riderIds: [] }],
      bookingAutoRejected: [{ rideId, riderIds: [] }],
    });
  });
});

describe('refused actions send nothing', () => {
  it.each([
    [
      'a request on a FULL ride',
      async ({ rider, rideId }) => {
        await prisma.ride.update({
          where: { id: rideId },
          data: { status: 'FULL', seatsAvailable: 0 },
        });
        await requestBooking(rider.token, rideId).expect(409);
      },
    ],
    [
      'an accept by someone other than the driver',
      async ({ rider, other, rideId }) => {
        const bookingId = await insertBooking(rideId, rider.user.id);
        await act(other.token, bookingId, 'accept').expect(403);
      },
    ],
    [
      'a reject of an already rejected booking',
      async ({ driver, rider, rideId }) => {
        const bookingId = await insertBooking(rideId, rider.user.id, { status: 'REJECTED' });
        await act(driver.token, bookingId, 'reject').expect(409);
      },
    ],
    [
      'a rider cancel during the ride',
      async ({ rider, rideId }) => {
        const bookingId = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
        await prisma.ride.update({ where: { id: rideId }, data: { status: 'IN_PROGRESS' } });
        await act(rider.token, bookingId, 'cancel').expect(409);
      },
    ],
    [
      'a second ride cancel',
      async ({ driver, rider, rideId }) => {
        await insertBooking(rideId, rider.user.id);
        await cancelRide(driver.token, rideId).expect(200);
        jest.resetAllMocks();
        await cancelRide(driver.token, rideId).expect(409);
      },
    ],
    [
      'a start outside the start window',
      async ({ driver, rider }) => {
        const rideId = await insertRide(driver.user.id, {
          departureTime: new Date(Date.now() + 2 * 60 * MINUTE),
        });
        await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
        await startRide(driver.token, rideId).expect(409);
      },
    ],
  ])('%s', async (_label, run) => {
    await run(await setup());
    expect(sent()).toEqual({});
  });
});

describe('when sending fails, the request still succeeds', () => {
  let errSpy;
  beforeEach(() => {
    errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => errSpy.mockRestore());

  const flush = () => new Promise((resolve) => setImmediate(resolve));

  it.each(
    Object.keys(CASES).flatMap((name) => [
      [name, 'throws'],
      [name, 'rejects'],
    ]),
  )('%s: the notification %s', async (name, how) => {
    for (const event of EVENTS) {
      notifications[event].mockImplementation(() => {
        if (how === 'throws') throw new Error('FCM is down');
        return Promise.reject(new Error('FCM is down'));
      });
    }
    // Each case asserts its own success status, then that its change committed.
    const { expected, committed } = await CASES[name]();
    await committed();
    await flush();

    expect(Object.keys(sent()).sort()).toEqual(Object.keys(expected).sort());
    const logged = errSpy.mock.calls.map(([prefix]) => prefix);
    for (const event of Object.keys(expected)) {
      expect(logged).toContain(`[background] notification ${event} failed:`);
    }
  });
});
