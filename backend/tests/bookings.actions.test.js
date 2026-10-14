const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, createUser, insertRide } = require('./helpers/rides');
const {
  bookingBody,
  requestBooking,
  act,
  insertBooking,
  bookingStatus,
  rideSeats,
  whileRideLocked,
} = require('./helpers/bookings');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

async function setup(rideOverrides = {}) {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, rideOverrides);
  return { driver, rider, rideId };
}

/** `n` riders, each with a PENDING one-seat booking on `rideId`; resolves to the booking ids. */
async function pendingBookings(rideId, n) {
  const ids = [];
  for (let i = 0; i < n; i++) {
    const rider = await createUser(`rider${i}`, 'RIDER');
    ids.push(await insertBooking(rideId, rider.user.id));
  }
  return ids;
}

describe.each(['accept', 'reject', 'cancel'])('POST /bookings/:id/%s', (action) => {
  it('requires authentication', async () => {
    await request(app).post(`/bookings/${randomUUID()}/${action}`).expect(401);
  });

  it('returns 404 for an unknown booking and 400 for a bad id', async () => {
    const user = await createUser('dev');
    const res = await act(user.token, randomUUID(), action).expect(404);
    expect(res.body.error.code).toBe('BOOKING_NOT_FOUND');
    await act(user.token, 'not-a-uuid', action).expect(400);
  });
});

describe('full flow', () => {
  it('request, accept: seats go down; accepting the last seat makes the ride FULL', async () => {
    const { driver, rider, rideId } = await setup({ seatsTotal: 3 });
    const second = await createUser('second', 'RIDER');

    const first = await requestBooking(rider.token, rideId, bookingBody({ seats: 2 })).expect(201);
    const res = await act(driver.token, first.body.booking.id, 'accept').expect(200);

    expect(res.body.booking).toMatchObject({ id: first.body.booking.id, status: 'ACCEPTED' });
    expect(await rideSeats(rideId)).toEqual({ seatsTotal: 3, seatsAvailable: 1, status: 'OPEN' });

    const last = await requestBooking(second.token, rideId).expect(201);
    await act(driver.token, last.body.booking.id, 'accept').expect(200);

    expect(await rideSeats(rideId)).toEqual({ seatsTotal: 3, seatsAvailable: 0, status: 'FULL' });
  });
});

describe('POST /bookings/:id/accept', () => {
  it('CONCURRENCY: 1 seat, 5 pending bookings, 5 accepts at once: exactly one wins', async () => {
    const { driver, rideId } = await setup({ seatsTotal: 1 });
    const ids = await pendingBookings(rideId, 5);

    const results = await whileRideLocked(rideId, ids.length, () =>
      Promise.all(ids.map((id) => act(driver.token, id, 'accept'))),
    );

    const codes = results.map((r) => r.status);
    expect(codes.filter((c) => c === 200)).toHaveLength(1);
    expect(codes.filter((c) => c === 409)).toHaveLength(4);
    for (const r of results.filter((x) => x.status === 409)) {
      expect(r.body.error.code).toBe('SEAT_UNAVAILABLE');
    }
    expect(await rideSeats(rideId)).toEqual({ seatsTotal: 1, seatsAvailable: 0, status: 'FULL' });
    const statuses = await Promise.all(ids.map(bookingStatus));
    expect(statuses.filter((s) => s === 'ACCEPTED')).toHaveLength(1);
    expect(statuses.filter((s) => s === 'PENDING')).toHaveLength(4);
  });

  it('CONCURRENCY: the same booking accepted twice at once takes its seats only once', async () => {
    const { driver, rider, rideId } = await setup({ seatsTotal: 4 });
    const id = await insertBooking(rideId, rider.user.id, { seats: 2 });

    const results = await whileRideLocked(rideId, 2, () =>
      Promise.all([act(driver.token, id, 'accept'), act(driver.token, id, 'accept')]),
    );

    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    expect(results.find((r) => r.status === 409).body.error.code).toBe('INVALID_TRANSITION');
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 2, status: 'OPEN' });
    expect(await bookingStatus(id)).toBe('ACCEPTED');
  });

  it('refuses anyone but the ride’s driver (403), including the rider', async () => {
    const { rider, rideId } = await setup();
    const otherDriver = await createUser('other-driver');
    const id = await insertBooking(rideId, rider.user.id);

    for (const user of [otherDriver, rider]) {
      const res = await act(user.token, id, 'accept').expect(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
    }
    expect(await bookingStatus(id)).toBe('PENDING');
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 3 });
  });

  it('returns 409 SEAT_UNAVAILABLE when the booking needs more seats than are left', async () => {
    const { driver, rider, rideId } = await setup({ seatsTotal: 3, seatsAvailable: 1 });
    const id = await insertBooking(rideId, rider.user.id, { seats: 2 });

    const res = await act(driver.token, id, 'accept').expect(409);

    expect(res.body.error).toEqual({
      code: 'SEAT_UNAVAILABLE',
      message: 'Cannot accept this booking: 1 seat(s) left, 2 requested',
    });
    expect(await bookingStatus(id)).toBe('PENDING');
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 1, status: 'OPEN' });
  });

  it('keeps PENDING bookings on a FULL ride, and accepts one once a seat frees up', async () => {
    const { driver, rider, rideId } = await setup({
      seatsTotal: 1,
      seatsAvailable: 0,
      status: 'FULL',
    });
    const holder = await createUser('holder', 'RIDER');
    const accepted = await insertBooking(rideId, holder.user.id, { status: 'ACCEPTED' });
    const waiting = await insertBooking(rideId, rider.user.id);

    const full = await act(driver.token, waiting, 'accept').expect(409);
    expect(full.body.error.message).toBe('Cannot accept this booking: the ride is FULL');
    expect(await bookingStatus(waiting)).toBe('PENDING');

    await act(holder.token, accepted, 'cancel').expect(200);
    await act(driver.token, waiting, 'accept').expect(200);
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 0, status: 'FULL' });
  });

  it('refuses to accept on a ride that has already departed', async () => {
    const { driver, rider, rideId } = await setup({
      departureTime: new Date(Date.now() - 5 * MINUTE),
    });
    const id = await insertBooking(rideId, rider.user.id);
    const res = await act(driver.token, id, 'accept').expect(409);
    expect(res.body.error).toEqual({
      code: 'SEAT_UNAVAILABLE',
      message: 'Cannot accept this booking: the ride has already departed',
    });
  });
});

describe('POST /bookings/:id/reject', () => {
  it('rejects a PENDING booking without touching the seats', async () => {
    const { driver, rider, rideId } = await setup();
    const id = await insertBooking(rideId, rider.user.id);

    const res = await act(driver.token, id, 'reject').expect(200);

    expect(res.body.booking).toMatchObject({ id, status: 'REJECTED' });
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 3, status: 'OPEN' });
  });

  it('refuses anyone but the ride’s driver (403)', async () => {
    const { rider, rideId } = await setup();
    const id = await insertBooking(rideId, rider.user.id);
    await act(rider.token, id, 'reject').expect(403);
    expect(await bookingStatus(id)).toBe('PENDING');
  });
});

describe('POST /bookings/:id/cancel', () => {
  it('cancelling an ACCEPTED booking returns its seats and reopens a FULL ride', async () => {
    const { driver, rider, rideId } = await setup({ seatsTotal: 2 });
    const { body } = await requestBooking(rider.token, rideId, bookingBody({ seats: 2 })).expect(
      201,
    );
    await act(driver.token, body.booking.id, 'accept').expect(200);
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 0, status: 'FULL' });

    const res = await act(rider.token, body.booking.id, 'cancel').expect(200);

    expect(res.body.booking).toMatchObject({ status: 'CANCELLED' });
    expect(await rideSeats(rideId)).toEqual({ seatsTotal: 2, seatsAvailable: 2, status: 'OPEN' });
  });

  it('cancelling a PENDING booking leaves the seats alone', async () => {
    const { rider, rideId } = await setup({ seatsTotal: 3, seatsAvailable: 2 });
    const id = await insertBooking(rideId, rider.user.id);
    await act(rider.token, id, 'cancel').expect(200);
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 2, status: 'OPEN' });
  });

  it('CONCURRENCY: an ACCEPTED booking cancelled twice at once returns its seats once', async () => {
    const { rider, rideId } = await setup({ seatsTotal: 3, seatsAvailable: 1 });
    const id = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED', seats: 2 });

    const results = await whileRideLocked(rideId, 2, () =>
      Promise.all([act(rider.token, id, 'cancel'), act(rider.token, id, 'cancel')]),
    );

    expect(results.map((r) => r.status).sort()).toEqual([200, 409]);
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 3 });
  });

  it('refuses anyone but the rider who booked (403), including the driver', async () => {
    const { driver, rider, rideId } = await setup();
    const id = await insertBooking(rideId, rider.user.id);
    const res = await act(driver.token, id, 'cancel').expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('refuses to cancel on a ride that is no longer OPEN or FULL', async () => {
    const { rider, rideId } = await setup({ status: 'IN_PROGRESS' });
    const id = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    const res = await act(rider.token, id, 'cancel').expect(409);
    expect(res.body.error.code).toBe('BOOKING_NOT_CANCELLABLE');
    expect(await bookingStatus(id)).toBe('ACCEPTED');
  });
});

describe('invalid transitions return 409', () => {
  it.each([
    ['accept', 'ACCEPTED', 'driver'],
    ['accept', 'REJECTED', 'driver'],
    ['accept', 'CANCELLED', 'driver'],
    ['reject', 'ACCEPTED', 'driver'],
    ['reject', 'REJECTED', 'driver'],
    ['reject', 'CANCELLED', 'driver'],
    ['cancel', 'REJECTED', 'rider'],
    ['cancel', 'CANCELLED', 'rider'],
  ])('%s on a %s booking', async (action, status, actor) => {
    const users = await setup({ seatsTotal: 3, seatsAvailable: 2 });
    const id = await insertBooking(users.rideId, users.rider.user.id, { status });

    const res = await act(users[actor].token, id, action).expect(409);

    expect(res.body.error.code).toBe('INVALID_TRANSITION');
    expect(await bookingStatus(id)).toBe(status);
    expect(await rideSeats(users.rideId)).toMatchObject({ seatsAvailable: 2 });
  });
});
