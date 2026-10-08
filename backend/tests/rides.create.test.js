jest.mock('../src/services/routing.service');

const request = require('supertest');
const routing = require('../src/services/routing.service');
const { app, prisma, resetDb } = require('./helpers/auth');
const {
  MINUTE,
  HOUR,
  DAY,
  START,
  END,
  fakeRoute,
  createUser,
  rideBody,
  postRide,
} = require('./helpers/rides');

beforeEach(async () => {
  await resetDb();
  routing.getDrivingRoute.mockReset().mockResolvedValue(fakeRoute());
});
afterEach(() => jest.restoreAllMocks());
afterAll(() => prisma.$disconnect());

/** Reads the stored geometry with ST_X/ST_Y, independently of the API's ST_AsGeoJSON path. */
async function storedGeo(id) {
  const [row] = await prisma.$queryRaw`
    SELECT ST_Y("startPoint"::geometry) AS "startLat", ST_X("startPoint"::geometry) AS "startLng",
           ST_Y("endPoint"::geometry) AS "endLat", ST_X("endPoint"::geometry) AS "endLng",
           ST_Y(ST_StartPoint("routeLine"::geometry)) AS "routeStartLat",
           ST_X(ST_StartPoint("routeLine"::geometry)) AS "routeStartLng",
           ST_NPoints("routeLine"::geometry) AS "routePoints",
           ST_SRID("startPoint"::geometry) AS "srid"
    FROM "Ride" WHERE "id" = ${id}`;
  return row;
}

describe('POST /rides', () => {
  it('requires authentication', async () => {
    await request(app).post('/rides').send(rideBody()).expect(401);
  });

  it('returns 403 for a RIDER and creates nothing', async () => {
    const { token } = await createUser('rita', 'RIDER');
    const res = await postRide(token).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(routing.getDrivingRoute).not.toHaveBeenCalled();
    expect(await prisma.ride.count()).toBe(0);
  });

  it('creates a ride for a DRIVER and stores lat/lng in the right order', async () => {
    const { token, user } = await createUser('dev');
    const body = rideBody();

    const res = await postRide(token, body).expect(201);

    expect(res.body.warnings).toEqual([]);
    expect(res.body.ride).toMatchObject({
      status: 'OPEN',
      start: START,
      end: END,
      distanceMeters: 6844,
      durationSeconds: 812,
      departureTime: body.departureTime,
      seatsTotal: 3,
      seatsAvailable: 3,
      pricePerSeat: 50,
      notes: 'Leaving from gate 2',
      driver: { id: user.id, name: 'dev name', ratingAvg: 0, ratingCount: 0 },
    });
    expect(res.body.ride.route).toEqual([
      { lat: START.lat, lng: START.lng },
      { lat: 12.9756, lng: 77.6006 },
      { lat: END.lat, lng: END.lng },
    ]);
    expect(res.body.ride.driver).not.toHaveProperty('email');
    expect(routing.getDrivingRoute).toHaveBeenCalledWith(START, END);

    const geo = await storedGeo(res.body.ride.id);
    expect(geo).toEqual({
      startLat: START.lat,
      startLng: START.lng,
      endLat: END.lat,
      endLng: END.lng,
      routeStartLat: START.lat,
      routeStartLng: START.lng,
      routePoints: 3,
      srid: 4326,
    });
    const stored = await prisma.ride.findUniqueOrThrow({ where: { id: res.body.ride.id } });
    expect(stored.departureTime.toISOString()).toBe(body.departureTime);
    expect(stored.driverId).toBe(user.id);
  });

  it('accepts BOTH, defaults pricePerSeat to 0 and stores missing notes as null', async () => {
    const { token } = await createUser('bo', 'BOTH');
    const body = rideBody();
    delete body.pricePerSeat;
    delete body.notes;
    const res = await postRide(token, body).expect(201);
    expect(res.body.ride).toMatchObject({ pricePerSeat: 0, notes: null });
  });

  it('accepts whole-number coordinates and a departure time with an offset', async () => {
    const { token } = await createUser('dev');
    const departure = new Date(Date.now() + DAY);
    const ist = new Date(departure.getTime() + 5.5 * HOUR).toISOString().replace('Z', '+05:30');
    const res = await postRide(
      token,
      rideBody({ start: { lat: 13, lng: 77, address: 'A' }, departureTime: ist }),
    ).expect(201);
    expect(res.body.ride.start).toEqual({ lat: 13, lng: 77, address: 'A' });
    expect(res.body.ride.departureTime).toBe(departure.toISOString());
  });

  it('still creates the ride without a route when routing fails', async () => {
    routing.getDrivingRoute.mockResolvedValue(null);
    const { token } = await createUser('dev');

    const res = await postRide(token).expect(201);

    expect(res.body.ride).toMatchObject({
      route: null,
      distanceMeters: null,
      durationSeconds: null,
    });
    expect(res.body.ride.start).toEqual(START);
    expect(res.body.warnings).toEqual([]);
    const geo = await storedGeo(res.body.ride.id);
    expect(geo).toMatchObject({ startLat: START.lat, routePoints: null });
  });

  it('warns when a pin was snapped more than 300 m to reach a road', async () => {
    routing.getDrivingRoute.mockResolvedValue(
      fakeRoute({ startSnapMeters: 300, endSnapMeters: 301 }),
    );
    const { token } = await createUser('dev');
    const res = await postRide(token).expect(201);
    expect(res.body.warnings).toEqual(['end point is far from a road']);

    routing.getDrivingRoute.mockResolvedValue(fakeRoute({ startSnapMeters: 900 }));
    const later = rideBody({ departureTime: new Date(Date.now() + 2 * DAY).toISOString() });
    const res2 = await postRide(token, later).expect(201);
    expect(res2.body.warnings).toEqual(['start point is far from a road']);
  });

  describe('validation', () => {
    const at = (lat, lng) => ({ lat, lng, address: 'Somewhere' });
    // About 199 m and 201 m north of START.
    const near = { ...START, lat: START.lat + 0.00179 };
    const justFarEnough = { ...START, lat: START.lat + 0.00181 };

    it.each([
      ['lat above 90', { start: at(90.0001, 77) }],
      ['lat below -90', { start: at(-91, 77) }],
      ['lng above 180', { end: at(12, 180.5) }],
      ['lng below -180', { end: at(12, -181) }],
      ['lat as a string', { start: { ...START, lat: '12.97' } }],
      ['missing address', { start: { lat: 12.9, lng: 77.5 } }],
      ['blank address', { end: { ...END, address: '   ' } }],
      ['same start and end', { end: START }],
      ['start and end 199 m apart', { end: near }],
      ['past departure time', { departureTime: new Date(Date.now() - HOUR).toISOString() }],
      [
        'departure in 10 minutes',
        { departureTime: new Date(Date.now() + 10 * MINUTE).toISOString() },
      ],
      ['departure in 8 days', { departureTime: new Date(Date.now() + 8 * DAY).toISOString() }],
      ['departure without a time zone', { departureTime: '2030-01-01T10:00:00' }],
      ['departure not a date', { departureTime: 'tomorrow' }],
      ['0 seats', { seats: 0 }],
      ['7 seats', { seats: 7 }],
      ['fractional seats', { seats: 2.5 }],
      ['missing seats', { seats: undefined }],
      ['negative price', { pricePerSeat: -1 }],
      ['price above 1000', { pricePerSeat: 1001 }],
      ['fractional price', { pricePerSeat: 10.5 }],
      ['notes over 500 chars', { notes: 'x'.repeat(501) }],
      ['unknown field', { status: 'FULL' }],
    ])('returns 400 for %s', async (_label, overrides) => {
      const { token } = await createUser('dev');
      const res = await postRide(token, rideBody(overrides)).expect(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(routing.getDrivingRoute).not.toHaveBeenCalled();
      expect(await prisma.ride.count()).toBe(0);
    });

    it('accepts start and end just over 200 m apart', async () => {
      const { token } = await createUser('dev');
      await postRide(token, rideBody({ end: justFarEnough })).expect(201);
    });
  });

  describe('departure time window (clock pinned with Date.now)', () => {
    let now;
    beforeEach(() => {
      // Pin to the real current time so JWTs stay valid; only the window edges matter.
      now = Date.now();
      jest.spyOn(Date, 'now').mockReturnValue(now);
    });

    const departingIn = (ms) => rideBody({ departureTime: new Date(now + ms).toISOString() });

    it('accepts exactly 15 minutes ahead and rejects 1 ms less', async () => {
      const { token } = await createUser('dev');
      const res = await postRide(token, departingIn(15 * MINUTE - 1)).expect(400);
      expect(res.body.error.message).toMatch(/departureTime: must be at least 15 minutes/);
      await postRide(token, departingIn(15 * MINUTE)).expect(201);
    });

    it('accepts exactly 7 days ahead and rejects 1 ms more', async () => {
      const { token } = await createUser('dev');
      const res = await postRide(token, departingIn(7 * DAY + 1)).expect(400);
      expect(res.body.error.message).toMatch(/departureTime: must be at most 7 days/);
      await postRide(token, departingIn(7 * DAY)).expect(201);
    });
  });

  describe('overlapping rides', () => {
    const base = () => Date.now() + 2 * DAY;
    const departingAt = (ms) => rideBody({ departureTime: new Date(ms).toISOString() });

    it('rejects a second active ride less than 1 hour before or after, without routing', async () => {
      const { token } = await createUser('dev');
      const t = base();
      await postRide(token, departingAt(t)).expect(201);
      routing.getDrivingRoute.mockClear();

      for (const offset of [30 * MINUTE, -59 * MINUTE, 0]) {
        const res = await postRide(token, departingAt(t + offset)).expect(409);
        expect(res.body.error.code).toBe('RIDE_OVERLAP');
      }
      expect(routing.getDrivingRoute).not.toHaveBeenCalled();
      expect(await prisma.ride.count()).toBe(1);
    });

    it('allows rides exactly 1 hour apart', async () => {
      const { token } = await createUser('dev');
      const t = base();
      await postRide(token, departingAt(t)).expect(201);
      await postRide(token, departingAt(t + HOUR)).expect(201);
      await postRide(token, departingAt(t - HOUR)).expect(201);
    });

    it('ignores cancelled and completed rides and other drivers', async () => {
      const { token } = await createUser('dev');
      const other = await createUser('olga');
      const t = base();

      const first = await postRide(token, departingAt(t)).expect(201);
      await prisma.ride.update({
        where: { id: first.body.ride.id },
        data: { status: 'CANCELLED' },
      });
      const second = await postRide(token, departingAt(t + 10 * MINUTE)).expect(201);
      await prisma.ride.update({
        where: { id: second.body.ride.id },
        data: { status: 'COMPLETED' },
      });
      await postRide(token, departingAt(t)).expect(201);
      await postRide(other.token, departingAt(t)).expect(201);
    });

    it('blocks FULL and IN_PROGRESS rides too', async () => {
      const { token } = await createUser('dev');
      const t = base();
      const first = await postRide(token, departingAt(t)).expect(201);
      for (const status of ['FULL', 'IN_PROGRESS']) {
        await prisma.ride.update({ where: { id: first.body.ride.id }, data: { status } });
        await postRide(token, departingAt(t + 20 * MINUTE)).expect(409);
      }
    });

    it('lets only one of two simultaneous overlapping posts through', async () => {
      const { token } = await createUser('dev');
      const t = base();
      const results = await Promise.all([
        postRide(token, departingAt(t)),
        postRide(token, departingAt(t + 10 * MINUTE)),
      ]);
      expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
      expect(await prisma.ride.count()).toBe(1);
    });
  });
});
