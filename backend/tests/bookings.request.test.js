const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, createUser, insertRide } = require('./helpers/rides');
const {
  PICKUP,
  DROP,
  bookingBody,
  requestBooking,
  insertBooking,
  rideSeats,
} = require('./helpers/bookings');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

async function rideAndRider(rideOverrides = {}) {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, rideOverrides);
  return { driver, rider, rideId };
}

describe('POST /rides/:id/bookings', () => {
  it('requires authentication', async () => {
    await request(app).post(`/rides/${randomUUID()}/bookings`).send(bookingBody()).expect(401);
  });

  it('creates a PENDING booking and does not take a seat yet', async () => {
    const { rider, rideId } = await rideAndRider();

    const res = await requestBooking(rider.token, rideId, bookingBody({ seats: 2 })).expect(201);

    expect(res.body.booking).toEqual({
      id: expect.any(String),
      rideId,
      status: 'PENDING',
      seats: 2,
      pickup: {
        lat: expect.closeTo(PICKUP.lat, 6),
        lng: expect.closeTo(PICKUP.lng, 6),
        address: PICKUP.address,
      },
      drop: {
        lat: expect.closeTo(DROP.lat, 6),
        lng: expect.closeTo(DROP.lng, 6),
        address: DROP.address,
      },
      createdAt: expect.any(String),
      updatedAt: expect.any(String),
    });
    expect(await rideSeats(rideId)).toMatchObject({ seatsAvailable: 3, status: 'OPEN' });
  });

  it('stores points as (lng, lat)', async () => {
    const { rider, rideId } = await rideAndRider();
    const { body } = await requestBooking(rider.token, rideId).expect(201);
    const [row] = await prisma.$queryRaw`
      SELECT ST_X("pickupPoint"::geometry) AS x, ST_Y("pickupPoint"::geometry) AS y
      FROM "Booking" WHERE "id" = ${body.booking.id}`;
    expect(row.x).toBeCloseTo(PICKUP.lng, 6);
    expect(row.y).toBeCloseTo(PICKUP.lat, 6);
  });

  it('defaults to one seat', async () => {
    const { rider, rideId } = await rideAndRider();
    const { pickup, drop } = bookingBody();
    const res = await requestBooking(rider.token, rideId, { pickup, drop }).expect(201);
    expect(res.body.booking.seats).toBe(1);
  });

  it('lets a DRIVER book a seat on someone else’s ride', async () => {
    const { rideId } = await rideAndRider();
    const other = await createUser('other-driver', 'DRIVER');
    await requestBooking(other.token, rideId).expect(201);
  });

  it('rejects a second active request by the same rider', async () => {
    const { rider, rideId } = await rideAndRider();
    await requestBooking(rider.token, rideId).expect(201);

    const res = await requestBooking(rider.token, rideId).expect(409);

    expect(res.body.error.code).toBe('BOOKING_EXISTS');
    expect(await prisma.booking.count()).toBe(1);
  });

  it('rejects concurrent duplicate requests: exactly one gets in', async () => {
    const { rider, rideId } = await rideAndRider();

    const results = await Promise.all(
      Array.from({ length: 4 }, () => requestBooking(rider.token, rideId)),
    );

    expect(results.map((r) => r.status).sort()).toEqual([201, 409, 409, 409]);
    expect(await prisma.booking.count()).toBe(1);
  });

  it('rejects a request while an ACCEPTED booking exists', async () => {
    const { rider, rideId } = await rideAndRider();
    await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
    const res = await requestBooking(rider.token, rideId).expect(409);
    expect(res.body.error.code).toBe('BOOKING_EXISTS');
  });

  it('allows a new request after the previous one was cancelled or rejected', async () => {
    const { rider, rideId } = await rideAndRider();
    await insertBooking(rideId, rider.user.id, { status: 'CANCELLED' });
    await insertBooking(rideId, rider.user.id, { status: 'REJECTED' });
    await requestBooking(rider.token, rideId).expect(201);
  });

  it('rejects booking your own ride', async () => {
    const { driver, rideId } = await rideAndRider();
    const res = await requestBooking(driver.token, rideId).expect(403);
    expect(res.body.error.code).toBe('CANNOT_BOOK_OWN_RIDE');
  });

  it.each(['FULL', 'CANCELLED', 'IN_PROGRESS', 'COMPLETED'])(
    'rejects booking a %s ride',
    async (status) => {
      const { rider, rideId } = await rideAndRider({
        status,
        seatsAvailable: status === 'FULL' ? 0 : 3,
      });
      const res = await requestBooking(rider.token, rideId).expect(409);
      expect(res.body.error.code).toBe('RIDE_NOT_BOOKABLE');
      expect(await prisma.booking.count()).toBe(0);
    },
  );

  it('rejects booking an OPEN ride that has already departed', async () => {
    const { rider, rideId } = await rideAndRider({
      departureTime: new Date(Date.now() - 5 * MINUTE),
    });
    const res = await requestBooking(rider.token, rideId).expect(409);
    expect(res.body.error).toEqual({
      code: 'RIDE_NOT_BOOKABLE',
      message: 'This ride has already departed',
    });
  });

  it('rejects more seats than are available', async () => {
    const { rider, rideId } = await rideAndRider({ seatsTotal: 3, seatsAvailable: 1 });
    const res = await requestBooking(rider.token, rideId, bookingBody({ seats: 2 })).expect(409);
    expect(res.body.error.code).toBe('NOT_ENOUGH_SEATS');
  });

  it('returns 404 for an unknown ride', async () => {
    const rider = await createUser('rider', 'RIDER');
    const res = await requestBooking(rider.token, randomUUID()).expect(404);
    expect(res.body.error.code).toBe('RIDE_NOT_FOUND');
  });

  it.each([
    ['a non-uuid ride id', 'not-a-uuid', {}],
    ['zero seats', null, { seats: 0 }],
    ['seven seats', null, { seats: 7 }],
    ['fractional seats', null, { seats: 1.5 }],
    ['a missing pickup', null, { pickup: undefined }],
    ['a pickup latitude out of range', null, { pickup: { ...PICKUP, lat: 91 } }],
    ['an empty drop address', null, { drop: { ...DROP, address: '  ' } }],
    ['an unknown field', null, { status: 'ACCEPTED' }],
  ])('rejects %s with 400', async (_label, badId, overrides) => {
    const { rider, rideId } = await rideAndRider();
    const res = await requestBooking(rider.token, badId ?? rideId, bookingBody(overrides)).expect(
      400,
    );
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });
});
