const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const {
  HOUR,
  DAY,
  START,
  END,
  bearer,
  createUser,
  insertRide,
  offsetNorth,
} = require('./helpers/rides');

let rider;
let driver;

beforeEach(async () => {
  await resetDb();
  rider = await createUser('rita', 'RIDER');
  driver = await createUser('dev');
});
afterAll(() => prisma.$disconnect());

const inMs = (ms) => new Date(Date.now() + ms);

/** Pickup at START, drop-off at END, window from 1 to 5 hours from now; overrides win. */
function search(token, overrides = {}) {
  return request(app)
    .get('/rides/search')
    .set(bearer(token))
    .query({
      pickupLat: START.lat,
      pickupLng: START.lng,
      dropLat: END.lat,
      dropLng: END.lng,
      from: inMs(HOUR).toISOString(),
      to: inMs(5 * HOUR).toISOString(),
      ...overrides,
    });
}

/** A ride from `startMeters` north of START to `endMeters` north of END, departing in 3 hours. */
function rideAt(startMeters, endMeters = 0, overrides = {}) {
  return insertRide(driver.user.id, {
    start: offsetNorth(START, startMeters),
    end: offsetNorth(END, endMeters),
    departureTime: inMs(3 * HOUR),
    ...overrides,
  });
}

const ids = (res) => res.body.rides.map((r) => r.id);

describe('GET /rides/search', () => {
  it('requires authentication', async () => {
    await request(app).get('/rides/search').expect(401);
  });

  it('finds a ride 1 km from the pickup and excludes one 3 km away', async () => {
    await prisma.user.update({
      where: { id: driver.user.id },
      data: { ratingAvg: 4.5, ratingCount: 2 },
    });
    const near = await rideAt(1000);
    await rideAt(3000);

    const res = await search(rider.token).expect(200);

    expect(ids(res)).toEqual([near]);
    expect(res.body).toMatchObject({ limit: 20, offset: 0, hasMore: false });
    const [ride] = res.body.rides;
    // ST_AsGeoJSON keeps 9 decimals.
    expect(ride.start.lat).toBeCloseTo(offsetNorth(START, 1000).lat, 9);
    expect(ride).toMatchObject({
      status: 'OPEN',
      start: { lng: START.lng, address: START.address },
      end: END,
      driver: { id: driver.user.id, name: 'dev name', ratingAvg: 4.5, ratingCount: 2 },
    });
    // Distances measured on the spheroid; a lat/lng swap would put them thousands of km off.
    expect(Math.abs(ride.pickupDistanceMeters - 1000)).toBeLessThanOrEqual(10);
    expect(ride.dropDistanceMeters).toBe(0);
    expect(ride).not.toHaveProperty('route');
  });

  it('excludes a ride whose end is 3 km from the drop-off', async () => {
    const near = await rideAt(0, 1000);
    await rideAt(0, 3000);

    const res = await search(rider.token).expect(200);

    expect(ids(res)).toEqual([near]);
    expect(Math.abs(res.body.rides[0].dropDistanceMeters - 1000)).toBeLessThanOrEqual(10);
  });

  it('uses the radius param', async () => {
    const id = await rideAt(2500);

    expect(ids(await search(rider.token).expect(200))).toEqual([]);
    expect(ids(await search(rider.token, { radius: 3000 }).expect(200))).toEqual([id]);
  });

  it('excludes rides departing outside the time window', async () => {
    const inside = await rideAt(0, 0, { departureTime: inMs(3 * HOUR) });
    await rideAt(0, 0, { departureTime: inMs(HOUR - 60 * 1000) });
    await rideAt(0, 0, { departureTime: inMs(5 * HOUR + 60 * 1000) });

    expect(ids(await search(rider.token).expect(200))).toEqual([inside]);
  });

  it('never returns rides that have already departed, even when from is in the past', async () => {
    const upcoming = await rideAt(0, 0, { departureTime: inMs(HOUR) });
    await rideAt(0, 0, { departureTime: inMs(-HOUR) });

    const res = await search(rider.token, { from: inMs(-2 * HOUR).toISOString() }).expect(200);

    expect(ids(res)).toEqual([upcoming]);
  });

  it.each([
    ['UTC', 'Z'],
    ['an offset', '+05:30'],
  ])('finds rides in a window that crosses midnight (%s)', async (_label, zone) => {
    // A calendar day two days ahead, so the whole window is in the future in either zone.
    const day = new Date(Date.now() + 2 * DAY).toISOString().slice(0, 10);
    const next = new Date(Date.parse(day) + DAY).toISOString().slice(0, 10);
    const at = (date, time) => new Date(`${date}T${time}${zone}`);

    const beforeMidnight = await rideAt(0, 0, { departureTime: at(day, '23:30:00') });
    const afterMidnight = await rideAt(0, 0, { departureTime: at(next, '00:30:00') });
    await rideAt(0, 0, { departureTime: at(day, '22:30:00') });
    await rideAt(0, 0, { departureTime: at(next, '01:30:00') });

    const res = await search(rider.token, {
      from: `${day}T23:00:00${zone}`,
      to: `${next}T01:00:00${zone}`,
    }).expect(200);

    expect(ids(res)).toEqual([beforeMidnight, afterMidnight]);
  });

  it('excludes rides that are not OPEN or have too few seats', async () => {
    const twoSeats = await rideAt(0, 0, { seatsAvailable: 2 });
    await rideAt(0, 0, { seatsAvailable: 1 });
    await rideAt(0, 0, { status: 'CANCELLED', seatsAvailable: 2 });
    await rideAt(0, 0, { status: 'FULL', seatsAvailable: 0 });
    await rideAt(0, 0, { status: 'IN_PROGRESS', seatsAvailable: 2 });

    expect(ids(await search(rider.token, { seats: 2 }).expect(200))).toEqual([twoSeats]);
  });

  it("excludes the user's own rides", async () => {
    const other = await createUser('olga');
    const othersRide = await insertRide(other.user.id, { departureTime: inMs(3 * HOUR) });
    await rideAt(0);

    expect(ids(await search(driver.token).expect(200))).toEqual([othersRide]);
  });

  it('sorts by pickup distance, then departure time', async () => {
    const far = await rideAt(1500, 0, { departureTime: inMs(2 * HOUR) });
    const nearLater = await rideAt(500, 0, { departureTime: inMs(4 * HOUR) });
    const nearSooner = await rideAt(500, 0, { departureTime: inMs(3 * HOUR) });
    const nearest = await rideAt(100, 0, { departureTime: inMs(4 * HOUR) });

    const res = await search(rider.token).expect(200);

    expect(ids(res)).toEqual([nearest, nearSooner, nearLater, far]);
    const distances = res.body.rides.map((r) => r.pickupDistanceMeters);
    expect(distances).toEqual([...distances].sort((a, b) => a - b));
  });

  it('paginates with limit and offset and reports hasMore', async () => {
    const sorted = [];
    for (const meters of [100, 200, 300]) sorted.push(await rideAt(meters));

    const page1 = await search(rider.token, { limit: 2 }).expect(200);
    expect(ids(page1)).toEqual(sorted.slice(0, 2));
    expect(page1.body).toMatchObject({ limit: 2, offset: 0, hasMore: true });

    const page2 = await search(rider.token, { limit: 2, offset: 2 }).expect(200);
    expect(ids(page2)).toEqual(sorted.slice(2));
    expect(page2.body).toMatchObject({ limit: 2, offset: 2, hasMore: false });
  });

  it('accepts a window of exactly 24 hours', async () => {
    const id = await rideAt(0, 0, { departureTime: inMs(20 * HOUR) });
    const res = await search(rider.token, {
      from: inMs(HOUR).toISOString(),
      to: inMs(25 * HOUR).toISOString(),
    }).expect(200);
    expect(ids(res)).toEqual([id]);
  });

  describe('invalid params return 400', () => {
    // Validation does not depend on the clock, so a fixed from keeps the window maths exact.
    const FROM = Date.parse('2030-01-01T22:00:00Z');
    const later = (ms) => new Date(FROM + ms).toISOString();

    it.each([
      ['missing pickupLat', { pickupLat: undefined }, 'query.pickupLat'],
      ['empty pickupLat', { pickupLat: '' }, 'query.pickupLat'],
      ['non-numeric pickupLng', { pickupLng: 'abc' }, 'query.pickupLng'],
      ['dropLat out of range', { dropLat: 91 }, 'query.dropLat'],
      ['dropLng out of range', { dropLng: -181 }, 'query.dropLng'],
      ['radius below 500', { radius: 499 }, 'query.radius'],
      ['radius above 5000', { radius: 5001 }, 'query.radius'],
      ['seats 0', { seats: 0 }, 'query.seats'],
      ['seats 7', { seats: 7 }, 'query.seats'],
      ['fractional seats', { seats: 1.5 }, 'query.seats'],
      ['limit above 50', { limit: 51 }, 'query.limit'],
      ['limit 0', { limit: 0 }, 'query.limit'],
      ['negative offset', { offset: -1 }, 'query.offset'],
      ['missing from', { from: undefined }, 'query.from'],
      ['from without a time zone', { from: '2026-10-12T10:00:00' }, 'query.from'],
      ['to before from', { to: later(-30 * 60 * 1000) }, 'query.to'],
      ['to equal to from', { to: later(0) }, 'query.to'],
      ['window over 24 hours', { to: later(DAY + 60 * 1000) }, 'query.to'],
      ['repeated param', { seats: ['1', '2'] }, 'query.seats'],
      ['unknown param', { foo: 'bar' }, 'Unrecognized key'],
    ])('%s', async (_label, overrides, expected) => {
      const res = await search(rider.token, { from: later(0), ...overrides }).expect(400);
      expect(res.body.error.code).toBe('VALIDATION_ERROR');
      expect(res.body.error.message).toContain(expected);
    });
  });
});
