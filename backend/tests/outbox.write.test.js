const request = require('supertest');
const outbox = require('../src/services/outbox.service');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, bearer, createUser, insertRide } = require('./helpers/rides');
const { requestBooking, act, insertBooking, bookingStatus } = require('./helpers/bookings');
const { outboxRows } = require('./helpers/outbox');

/*
 * Each notification event must write its outbox rows, one per recipient, in the transaction of
 * the change it announces. Sending them is covered by outbox.jobs.test.js.
 */

beforeEach(resetDb);
afterEach(() => jest.restoreAllMocks());
afterAll(() => prisma.$disconnect());

/** The rows `expected` describes ({ type, to: user, payload }), as outboxRows() returns them. */
const rows = (...expected) =>
  expected
    .map(({ type, to, payload }) => ({ type, to: to.user.id, payload, status: 'PENDING' }))
    .sort((a, b) => `${a.type} ${a.to}`.localeCompare(`${b.type} ${b.to}`));

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
const rideStatus = async (id) => (await prisma.ride.findUniqueOrThrow({ where: { id } })).status;

/*
 * Each case prepares one action and states the rows it must write. `run(status)` performs it,
 * expecting that HTTP status; `unchanged()` asserts that the state it changes is as it was.
 * Shared by the recipient tests and the atomicity tests below.
 */
const CASES = {
  async bookingRequested() {
    const { driver, rider, rideId } = await setup();
    let bookingId;
    return {
      run: async (status = 201) => {
        const res = await requestBooking(rider.token, rideId).expect(status);
        bookingId = res.body.booking?.id;
      },
      expected: () =>
        rows({ type: 'booking.requested', to: driver, payload: { rideId, bookingId } }),
      unchanged: async () => expect(await prisma.booking.count()).toBe(0),
    };
  },

  async bookingAccepted() {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    return {
      run: (status = 200) => act(driver.token, bookingId, 'accept').expect(status),
      expected: () => rows({ type: 'booking.accepted', to: rider, payload: { rideId, bookingId } }),
      unchanged: async () => {
        expect(await bookingStatus(bookingId)).toBe('PENDING');
        // The seat the accept took went back with the rollback.
        const ride = await prisma.ride.findUniqueOrThrow({ where: { id: rideId } });
        expect(ride.seatsAvailable).toBe(ride.seatsTotal);
      },
    };
  },

  async bookingRejected() {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    return {
      run: (status = 200) => act(driver.token, bookingId, 'reject').expect(status),
      expected: () => rows({ type: 'booking.rejected', to: rider, payload: { rideId, bookingId } }),
      unchanged: async () => expect(await bookingStatus(bookingId)).toBe('PENDING'),
    };
  },

  async bookingCancelled() {
    const { driver, rider, rideId } = await setup({ seatsAvailable: 2 });
    const bookingId = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    return {
      run: (status = 200) => act(rider.token, bookingId, 'cancel').expect(status),
      expected: () =>
        rows({
          type: 'booking.cancelled',
          to: driver,
          payload: { rideId, bookingId, wasAccepted: true },
        }),
      unchanged: async () => expect(await bookingStatus(bookingId)).toBe('ACCEPTED'),
    };
  },

  async rideCancelled() {
    const { driver, rider, other, rideId } = await setup({ seatsAvailable: 2 });
    const third = await createUser('third', 'RIDER');
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    const pending = await insertBooking(rideId, other.user.id);
    await insertBooking(rideId, third.user.id, { status: 'REJECTED' });
    return {
      run: (status = 200) => cancelRide(driver.token, rideId).expect(status),
      expected: () =>
        rows(
          { type: 'ride.cancelled', to: rider, payload: { rideId } },
          { type: 'ride.cancelled', to: other, payload: { rideId } },
        ),
      unchanged: async () => {
        expect(await rideStatus(rideId)).toBe('OPEN');
        expect(await bookingStatus(pending)).toBe('PENDING');
      },
    };
  },

  async rideStarted() {
    const { driver, rider, other, rideId } = await setup({ seatsAvailable: 1 });
    const third = await createUser('third', 'RIDER');
    const gone = await createUser('gone', 'RIDER');
    const fourth = await createUser('fourth', 'RIDER');
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    await insertBooking(rideId, fourth.user.id, { status: 'ACCEPTED' });
    const pending = await insertBooking(rideId, other.user.id);
    await insertBooking(rideId, third.user.id, { status: 'REJECTED' });
    await insertBooking(rideId, gone.user.id, { status: 'CANCELLED' });
    return {
      run: (status = 200) => startRide(driver.token, rideId).expect(status),
      expected: () =>
        rows(
          { type: 'ride.started', to: rider, payload: { rideId } },
          { type: 'ride.started', to: fourth, payload: { rideId } },
          { type: 'booking.autoRejected', to: other, payload: { rideId } },
        ),
      unchanged: async () => {
        expect(await rideStatus(rideId)).toBe('OPEN');
        expect(await bookingStatus(pending)).toBe('PENDING');
      },
    };
  },
};

describe('recipients', () => {
  it.each(Object.keys(CASES))('%s writes one PENDING row per recipient', async (name) => {
    const { run, expected } = await CASES[name]();
    await run();
    expect(await outboxRows()).toEqual(expected());
  });

  it('tells the driver when a PENDING request is cancelled, with no seat freed', async () => {
    const { driver, rider, rideId } = await setup();
    const bookingId = await insertBooking(rideId, rider.user.id);
    await act(rider.token, bookingId, 'cancel').expect(200);
    expect(await outboxRows()).toEqual(
      rows({
        type: 'booking.cancelled',
        to: driver,
        payload: { rideId, bookingId, wasAccepted: false },
      }),
    );
  });

  it('starting or cancelling a ride without bookings writes nothing', async () => {
    const { driver, rideId } = await setup();
    await startRide(driver.token, rideId).expect(200);
    const second = await insertRide(driver.user.id, {
      departureTime: new Date(Date.now() + 3 * 60 * MINUTE),
    });
    await cancelRide(driver.token, second).expect(200);
    expect(await outboxRows()).toEqual([]);
  });

  it('completing a ride writes nothing', async () => {
    const { driver, rider, rideId } = await setup({ seatsAvailable: 2 });
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    await startRide(driver.token, rideId).expect(200);
    await prisma.outbox.deleteMany();
    await request(app).post(`/rides/${rideId}/complete`).set(bearer(driver.token)).expect(200);
    expect(await outboxRows()).toEqual([]);
  });
});

describe('refused actions write nothing', () => {
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
      'an accept with no seat left',
      async ({ driver, rider, rideId }) => {
        const bookingId = await insertBooking(rideId, rider.user.id);
        await prisma.ride.update({ where: { id: rideId }, data: { seatsAvailable: 0 } });
        await act(driver.token, bookingId, 'accept').expect(409);
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
        await prisma.outbox.deleteMany();
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
    expect(await outboxRows()).toEqual([]);
  });
});

describe('the rows and the change commit or roll back together', () => {
  it('a transaction that rolls back leaves no outbox row', async () => {
    const { rider } = await setup();
    await expect(
      prisma.$transaction(async (tx) => {
        await outbox.enqueue(tx, 'ride.started', [rider.user.id], { rideId: 'r' });
        // Written, and visible inside the transaction...
        expect(await tx.outbox.count()).toBe(1);
        throw new Error('roll back');
      }),
    ).rejects.toThrow('roll back');
    // ...but gone with it.
    expect(await prisma.outbox.count()).toBe(0);
  });

  it.each(Object.keys(CASES))(
    '%s: when the transaction fails after the outbox insert, both are rolled back',
    async (name) => {
      jest.spyOn(console, 'error').mockImplementation(() => {});
      const { run, unchanged } = await CASES[name]();
      const real = outbox.enqueue;
      // The real insert runs, then the transaction fails.
      jest.spyOn(outbox, 'enqueue').mockImplementation(async (...args) => {
        await real(...args);
        throw new Error('failed after the insert');
      });

      await run(500);

      await unchanged();
      expect(await prisma.outbox.count()).toBe(0);
    },
  );

  it('nudges the relay only after the commit, and survives a nudge that throws', async () => {
    const { rider, rideId } = await setup();
    const seen = [];
    outbox.onNudge(() => {
      seen.push(prisma.outbox.count());
      throw new Error('relay is broken');
    });
    try {
      await requestBooking(rider.token, rideId).expect(201);
    } finally {
      outbox.onNudge(null);
    }
    // Counted through another connection at the moment of the nudge: the row was committed.
    expect(await Promise.all(seen)).toEqual([1]);
  });
});

describe('enqueue', () => {
  it('writes one row per distinct recipient and refuses unknown types', async () => {
    const { rider, other } = await setup();
    await prisma.$transaction((tx) =>
      outbox.enqueue(tx, 'ride.cancelled', [rider.user.id, other.user.id, rider.user.id], {
        rideId: 'r',
      }),
    );
    expect(await prisma.outbox.count()).toBe(2);
    await expect(outbox.enqueue(prisma, 'ride.exploded', [rider.user.id], {})).rejects.toThrow(
      /Unknown notification type/,
    );
  });
});
