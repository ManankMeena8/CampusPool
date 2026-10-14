const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { HOUR, bearer, createUser, insertRide } = require('./helpers/rides');
const { PICKUP, DROP, bookingBody, requestBooking, insertBooking } = require('./helpers/bookings');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

async function rideAndRider(rideOverrides = {}) {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, rideOverrides);
  return { driver, rider, rideId };
}

describe('GET /rides/:id/bookings', () => {
  const list = (token, rideId) => request(app).get(`/rides/${rideId}/bookings`).set(bearer(token));

  it('requires authentication', async () => {
    await request(app).get(`/rides/${randomUUID()}/bookings`).expect(401);
  });

  it('shows the driver every booking, oldest first, with points, seats and the rider by name and rating', async () => {
    const { driver, rider, rideId } = await rideAndRider();
    const second = await createUser('second', 'RIDER');
    await requestBooking(rider.token, rideId, bookingBody({ seats: 2 })).expect(201);
    const rejected = await insertBooking(rideId, second.user.id, { status: 'REJECTED' });
    await prisma.booking.update({
      where: { id: rejected },
      data: { createdAt: new Date(Date.now() + HOUR) },
    });

    const res = await list(driver.token, rideId).expect(200);

    expect(res.body.bookings).toHaveLength(2);
    const [first, last] = res.body.bookings;
    expect(first).toMatchObject({
      status: 'PENDING',
      seats: 2,
      pickup: { address: PICKUP.address },
      drop: { address: DROP.address },
    });
    expect(first.pickup.lat).toBeCloseTo(PICKUP.lat, 6);
    expect(first.pickup.lng).toBeCloseTo(PICKUP.lng, 6);
    expect(first.drop.lat).toBeCloseTo(DROP.lat, 6);
    expect(first.drop.lng).toBeCloseTo(DROP.lng, 6);
    expect(first.rider).toEqual({
      id: rider.user.id,
      name: 'rider name',
      ratingAvg: 0,
      ratingCount: 0,
    });
    expect(last).toMatchObject({ id: rejected, status: 'REJECTED' });
    expect(JSON.stringify(res.body)).not.toMatch(/email|phone|passwordHash|fcmToken/);
  });

  it('returns an empty list for a ride without bookings', async () => {
    const { driver, rideId } = await rideAndRider();
    const res = await list(driver.token, rideId).expect(200);
    expect(res.body).toEqual({ bookings: [] });
  });

  it('refuses anyone but the driver', async () => {
    const { rider, rideId } = await rideAndRider();
    await requestBooking(rider.token, rideId).expect(201);
    const res = await list(rider.token, rideId).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });

  it('returns 404 for an unknown ride and 400 for a bad id', async () => {
    const driver = await createUser('dev');
    await list(driver.token, randomUUID()).expect(404);
    await list(driver.token, 'nope').expect(400);
  });
});

describe('GET /bookings/mine', () => {
  const mine = (token) => request(app).get('/bookings/mine').set(bearer(token));

  it('requires authentication', async () => {
    await request(app).get('/bookings/mine').expect(401);
  });

  it('lists only the rider’s bookings, upcoming first, each with its ride', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const other = await createUser('other', 'RIDER');
    const later = await insertRide(driver.user.id, {
      departureTime: new Date(Date.now() + 5 * HOUR),
    });
    const sooner = await insertRide(driver.user.id, {
      departureTime: new Date(Date.now() + 2 * HOUR),
    });
    const past = await insertRide(driver.user.id, {
      departureTime: new Date(Date.now() - 2 * HOUR),
    });
    await insertBooking(past, rider.user.id, { status: 'ACCEPTED' });
    await insertBooking(later, rider.user.id);
    await insertBooking(sooner, rider.user.id, { status: 'CANCELLED' });
    await insertBooking(sooner, other.user.id);

    const res = await mine(rider.token).expect(200);

    expect(res.body.bookings.map((b) => [b.rideId, b.status])).toEqual([
      [sooner, 'CANCELLED'],
      [later, 'PENDING'],
      [past, 'ACCEPTED'],
    ]);
    const [first] = res.body.bookings;
    expect(first.ride).toMatchObject({
      id: sooner,
      status: 'OPEN',
      seatsAvailable: 3,
      driver: { id: driver.user.id, name: 'dev name' },
    });
    expect(first.rider).toBeUndefined();
    expect(first.pickup.address).toBe(PICKUP.address);
  });

  it('returns an empty list when the rider has no bookings', async () => {
    const rider = await createUser('rider', 'RIDER');
    const res = await mine(rider.token).expect(200);
    expect(res.body).toEqual({ bookings: [] });
  });
});
