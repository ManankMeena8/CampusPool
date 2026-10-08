jest.mock('../src/services/routing.service');

const { randomUUID } = require('crypto');
const request = require('supertest');
const routing = require('../src/services/routing.service');
const { app, prisma, resetDb } = require('./helpers/auth');
const {
  HOUR,
  DAY,
  START,
  END,
  bearer,
  fakeRoute,
  createUser,
  rideBody,
  postRide,
} = require('./helpers/rides');

beforeEach(async () => {
  await resetDb();
  routing.getDrivingRoute.mockReset().mockResolvedValue(fakeRoute());
});
afterAll(() => prisma.$disconnect());

/** Posts a ride departing `ms` from now (must be within the allowed window); resolves to its id. */
async function rideIn(token, ms) {
  const res = await postRide(
    token,
    rideBody({ departureTime: new Date(Date.now() + ms).toISOString() }),
  ).expect(201);
  return res.body.ride.id;
}

/** POST /rides cannot create past rides, so move one into the past directly. */
function moveToPast(id, msAgo) {
  return prisma.ride.update({
    where: { id },
    data: { departureTime: new Date(Date.now() - msAgo) },
  });
}

describe('GET /rides/mine', () => {
  const getMine = (token) => request(app).get('/rides/mine').set(bearer(token));

  it('requires authentication', async () => {
    await request(app).get('/rides/mine').expect(401);
  });

  it('returns an empty list for a user with no rides', async () => {
    const { token } = await createUser('rita', 'RIDER');
    const res = await getMine(token).expect(200);
    expect(res.body).toEqual({ rides: [] });
  });

  it("lists only the caller's rides: upcoming soonest first, then past most recent first", async () => {
    const { token } = await createUser('dev');
    const other = await createUser('olga');

    const in3Days = await rideIn(token, 3 * DAY);
    const in1Day = await rideIn(token, DAY);
    const in2Days = await rideIn(token, 2 * DAY);
    const pastRecent = await rideIn(token, 4 * DAY);
    const pastOld = await rideIn(token, 5 * DAY);
    await moveToPast(pastRecent, HOUR);
    await moveToPast(pastOld, 3 * DAY);
    await prisma.ride.update({ where: { id: in2Days }, data: { status: 'CANCELLED' } });
    await rideIn(other.token, DAY);

    const res = await getMine(token).expect(200);

    expect(res.body.rides.map((r) => r.id)).toEqual([
      in1Day,
      in2Days,
      in3Days,
      pastRecent,
      pastOld,
    ]);
    expect(res.body.rides[1].status).toBe('CANCELLED');
    // A past ride that was never started or cancelled is still OPEN; the app shows it as expired.
    expect(res.body.rides[3].status).toBe('OPEN');
  });

  it('returns points as {lat, lng} and leaves out the route line', async () => {
    const { token } = await createUser('dev');
    await rideIn(token, DAY);

    const [ride] = (await getMine(token).expect(200)).body.rides;
    expect(ride.start).toEqual(START);
    expect(ride.end).toEqual(END);
    expect(ride).not.toHaveProperty('route');
    expect(ride).toMatchObject({ distanceMeters: 6844, seatsTotal: 3, seatsAvailable: 3 });
  });
});

describe('GET /rides/:id', () => {
  const getRide = (token, id) => request(app).get(`/rides/${id}`).set(bearer(token));

  it('requires authentication', async () => {
    await request(app).get(`/rides/${randomUUID()}`).expect(401);
  });

  it('returns details with driver name and rating, points and route as {lat, lng}', async () => {
    const driver = await createUser('dev');
    await prisma.user.update({
      where: { id: driver.user.id },
      data: { ratingAvg: 4.5, ratingCount: 2, phone: '+919876543210' },
    });
    const id = await rideIn(driver.token, DAY);
    const rider = await createUser('rita', 'RIDER');

    const res = await getRide(rider.token, id).expect(200);

    expect(res.body.ride).toMatchObject({
      id,
      status: 'OPEN',
      start: START,
      end: END,
      distanceMeters: 6844,
      durationSeconds: 812,
      driver: { id: driver.user.id, name: 'dev name', ratingAvg: 4.5, ratingCount: 2 },
    });
    expect(res.body.ride.route).toEqual([
      { lat: START.lat, lng: START.lng },
      { lat: 12.9756, lng: 77.6006 },
      { lat: END.lat, lng: END.lng },
    ]);
    expect(Object.keys(res.body.ride.driver).sort()).toEqual([
      'id',
      'name',
      'ratingAvg',
      'ratingCount',
    ]);
  });

  it('returns route null when the ride has no route', async () => {
    routing.getDrivingRoute.mockResolvedValue(null);
    const { token } = await createUser('dev');
    const id = await rideIn(token, DAY);

    const res = await getRide(token, id).expect(200);
    expect(res.body.ride).toMatchObject({ route: null, distanceMeters: null, start: START });
  });

  it('shows a cancelled ride to other users', async () => {
    const driver = await createUser('dev');
    const id = await rideIn(driver.token, DAY);
    await prisma.ride.update({ where: { id }, data: { status: 'CANCELLED' } });
    const rider = await createUser('rita', 'RIDER');

    const res = await getRide(rider.token, id).expect(200);
    expect(res.body.ride.status).toBe('CANCELLED');
  });

  it('returns 404 for an id that does not exist', async () => {
    const { token } = await createUser('dev');
    const res = await getRide(token, randomUUID()).expect(404);
    expect(res.body).toEqual({ error: { code: 'RIDE_NOT_FOUND', message: 'Ride not found' } });
  });

  it.each(['not-a-uuid', '123', `${randomUUID()}x`])(
    'returns 400 for invalid id %s',
    async (id) => {
      const { token } = await createUser('dev');
      const res = await getRide(token, id).expect(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
    },
  );
});
