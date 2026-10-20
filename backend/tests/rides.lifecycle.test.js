const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, bearer, createUser, insertRide } = require('./helpers/rides');
const {
  insertBooking,
  bookingStatus,
  rideSeats,
  requestBooking,
  act,
} = require('./helpers/bookings');
const { startRealtimeServer, nextEvent, record, ask, settle } = require('./helpers/sockets');

let rt;
beforeAll(async () => {
  rt = await startRealtimeServer();
});
beforeEach(() => resetDb());
afterEach(() => {
  jest.restoreAllMocks();
  rt.disconnectAll();
});
afterAll(async () => {
  await rt.close();
  await prisma.$disconnect();
});

const start = (token, id) => request(app).post(`/rides/${id}/start`).set(bearer(token));
const complete = (token, id) => request(app).post(`/rides/${id}/complete`).set(bearer(token));
const statusOf = async (id) => (await rideSeats(id)).status;

/** A ride departing `departsIn` from now (default 10 minutes), with one ACCEPTED rider. */
async function setup({ status = 'OPEN', departsIn = 10 * MINUTE } = {}) {
  const driver = await createUser('driver');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, {
    status,
    departureTime: new Date(Date.now() + departsIn),
    seatsTotal: 2,
    seatsAvailable: status === 'FULL' ? 0 : 1,
  });
  const bookingId = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
  return { driver, rider, rideId, bookingId };
}

/** A socket of `token`'s user in the ride's room. */
async function joined(token, rideId) {
  const socket = await rt.connect(token);
  expect(await ask(socket, 'ride:join', { rideId })).toMatchObject({ ok: true });
  return socket;
}

describe('POST /rides/:id/start', () => {
  it('requires authentication', async () => {
    await request(app).post(`/rides/${randomUUID()}/start`).expect(401);
  });

  it('rejects a malformed id', async () => {
    const { driver } = await setup();
    const res = await start(driver.token, 'not-a-uuid').expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('answers 404 for an unknown ride', async () => {
    const { driver } = await setup();
    const res = await start(driver.token, randomUUID()).expect(404);
    expect(res.body.error.code).toBe('RIDE_NOT_FOUND');
  });

  it.each([
    ['a rider on the ride', 'rider'],
    ['another driver', 'other'],
  ])('refuses %s (403) and changes nothing', async (_label, who) => {
    const ctx = await setup();
    const other = await createUser('other');
    const token = who === 'rider' ? ctx.rider.token : other.token;

    const res = await start(token, ctx.rideId).expect(403);

    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(await statusOf(ctx.rideId)).toBe('OPEN');
  });

  it.each(['IN_PROGRESS', 'COMPLETED', 'CANCELLED'])('refuses a %s ride (409)', async (status) => {
    const { driver, rideId } = await setup({ status });
    const res = await start(driver.token, rideId).expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_STARTABLE');
    expect(await statusOf(rideId)).toBe(status);
  });

  it.each([
    ['more than 30 minutes before departure', 31 * MINUTE, /before its departure/],
    ['more than 30 minutes after departure', -31 * MINUTE, /after its departure/],
  ])('refuses a start %s (409)', async (_label, departsIn, message) => {
    const { driver, rideId } = await setup({ departsIn });
    const res = await start(driver.token, rideId).expect(409);
    expect(res.body.error).toEqual({ code: 'RIDE_NOT_STARTABLE', message: expect.any(String) });
    expect(res.body.error.message).toMatch(message);
    expect(await statusOf(rideId)).toBe('OPEN');
  });

  it.each([
    ['an OPEN ride 29 minutes before departure', 'OPEN', 29 * MINUTE],
    ['a FULL ride 29 minutes after departure', 'FULL', -29 * MINUTE],
  ])('starts %s', async (_label, status, departsIn) => {
    const { driver, rideId } = await setup({ status, departsIn });
    const res = await start(driver.token, rideId).expect(200);
    expect(res.body.ride).toMatchObject({ id: rideId, status: 'IN_PROGRESS' });
    expect(await statusOf(rideId)).toBe('IN_PROGRESS');
  });

  it('rejects PENDING bookings and leaves the others alone', async () => {
    const { driver, rideId, bookingId } = await setup();
    const riders = await Promise.all(['p', 'r', 'c'].map((l) => createUser(l, 'RIDER')));
    const pending = await insertBooking(rideId, riders[0].user.id, { status: 'PENDING' });
    const rejected = await insertBooking(rideId, riders[1].user.id, { status: 'REJECTED' });
    const cancelled = await insertBooking(rideId, riders[2].user.id, { status: 'CANCELLED' });

    await start(driver.token, rideId).expect(200);

    expect(await bookingStatus(pending)).toBe('REJECTED');
    expect(await bookingStatus(bookingId)).toBe('ACCEPTED');
    expect(await bookingStatus(rejected)).toBe('REJECTED');
    expect(await bookingStatus(cancelled)).toBe('CANCELLED');
  });

  it('leaves PENDING bookings alone when the start is refused', async () => {
    const { driver, rideId } = await setup({ departsIn: 2 * 60 * MINUTE });
    const other = await createUser('p', 'RIDER');
    const pending = await insertBooking(rideId, other.user.id, { status: 'PENDING' });
    await start(driver.token, rideId).expect(409);
    expect(await bookingStatus(pending)).toBe('PENDING');
  });

  it('emits ride:status to the room after the change is committed', async () => {
    const { driver, rider, rideId } = await setup();
    const riderSocket = await joined(rider.token, rideId);
    const driverSocket = await joined(driver.token, rideId);
    // Read the database the moment the event arrives: it must already show the new status.
    const seen = new Promise((resolve) => {
      riderSocket.once('ride:status', async (payload) => {
        resolve({ payload, stored: await statusOf(rideId) });
      });
    });
    const driverSeen = nextEvent(driverSocket, 'ride:status');

    await start(driver.token, rideId).expect(200);

    expect(await seen).toEqual({
      payload: { rideId, status: 'IN_PROGRESS' },
      stored: 'IN_PROGRESS',
    });
    expect(await driverSeen).toEqual({ rideId, status: 'IN_PROGRESS' });
  });

  it('emits nothing when refused', async () => {
    const { rider, rideId } = await setup();
    const socket = await joined(rider.token, rideId);
    const received = record(socket, 'ride:status');

    await start(rider.token, rideId).expect(403);

    await settle();
    expect(received).toEqual([]);
  });

  it('does not emit to other rides', async () => {
    const { driver, rideId } = await setup();
    const other = await createUser('other');
    const otherRide = await insertRide(other.user.id, {
      departureTime: new Date(Date.now() + 10 * MINUTE),
    });
    const socket = await joined(other.token, otherRide);
    const received = record(socket, 'ride:status');

    await start(driver.token, rideId).expect(200);

    await settle();
    expect(received).toEqual([]);
  });
});

describe('POST /rides/:id/complete', () => {
  it('requires authentication', async () => {
    await request(app).post(`/rides/${randomUUID()}/complete`).expect(401);
  });

  it('rejects a malformed id', async () => {
    const { driver } = await setup();
    const res = await complete(driver.token, 'not-a-uuid').expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });

  it('answers 404 for an unknown ride', async () => {
    const { driver } = await setup();
    const res = await complete(driver.token, randomUUID()).expect(404);
    expect(res.body.error.code).toBe('RIDE_NOT_FOUND');
  });

  it('refuses anyone but the driver (403)', async () => {
    const { rider, rideId } = await setup({ status: 'IN_PROGRESS' });
    const res = await complete(rider.token, rideId).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(await statusOf(rideId)).toBe('IN_PROGRESS');
  });

  it.each(['OPEN', 'FULL', 'COMPLETED', 'CANCELLED'])('refuses a %s ride (409)', async (status) => {
    const { driver, rideId } = await setup({ status });
    const res = await complete(driver.token, rideId).expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_COMPLETABLE');
    expect(await statusOf(rideId)).toBe(status);
  });

  it('completes an IN_PROGRESS ride, keeps bookings ACCEPTED and emits ride:status', async () => {
    const { driver, rider, rideId, bookingId } = await setup({ status: 'IN_PROGRESS' });
    const socket = await joined(rider.token, rideId);
    const seen = nextEvent(socket, 'ride:status');

    const res = await complete(driver.token, rideId).expect(200);

    expect(res.body.ride).toMatchObject({ id: rideId, status: 'COMPLETED' });
    expect(await seen).toEqual({ rideId, status: 'COMPLETED' });
    expect(await bookingStatus(bookingId)).toBe('ACCEPTED');
  });
});

describe('POST /rides/:id/cancel', () => {
  it('emits ride:status CANCELLED to the room', async () => {
    const { driver, rider, rideId } = await setup();
    const socket = await joined(rider.token, rideId);
    const seen = nextEvent(socket, 'ride:status');

    await request(app).post(`/rides/${rideId}/cancel`).set(bearer(driver.token)).expect(200);

    expect(await seen).toEqual({ rideId, status: 'CANCELLED' });
  });
});

describe.each(['IN_PROGRESS', 'COMPLETED'])('on a %s ride', (status) => {
  it('the driver cannot cancel the ride (409)', async () => {
    const { driver, rideId } = await setup({ status });
    const res = await request(app)
      .post(`/rides/${rideId}/cancel`)
      .set(bearer(driver.token))
      .expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_CANCELLABLE');
    expect(await statusOf(rideId)).toBe(status);
  });

  it('a rider cannot cancel their accepted booking (409)', async () => {
    const { rider, rideId, bookingId } = await setup({ status });
    const res = await act(rider.token, bookingId, 'cancel').expect(409);
    expect(res.body.error.code).toBe('BOOKING_NOT_CANCELLABLE');
    expect(await bookingStatus(bookingId)).toBe('ACCEPTED');
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 1, status });
  });

  it('the driver cannot accept a pending booking (409)', async () => {
    const { driver, rideId } = await setup({ status });
    const late = await createUser('late', 'RIDER');
    const pending = await insertBooking(rideId, late.user.id, { status: 'PENDING' });
    const res = await act(driver.token, pending, 'accept').expect(409);
    expect(res.body.error.code).toBe('SEAT_UNAVAILABLE');
    expect(await bookingStatus(pending)).toBe('PENDING');
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 1 });
  });

  it('nobody can request a seat (409)', async () => {
    const { rideId } = await setup({ status });
    const late = await createUser('late', 'RIDER');
    const res = await requestBooking(late.token, rideId).expect(409);
    expect(res.body.error.code).toBe('RIDE_NOT_BOOKABLE');
  });
});
