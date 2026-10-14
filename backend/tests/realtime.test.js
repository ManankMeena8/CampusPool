const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { MINUTE, bearer, createUser, insertRide } = require('./helpers/rides');
const { insertBooking, act } = require('./helpers/bookings');
const {
  startRealtimeServer,
  nextEvent,
  record,
  ask,
  settle,
  waitFor,
  tokenExpiringAt,
} = require('./helpers/sockets');
const hub = require('../src/realtime/hub');

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

// Asymmetric, so a lat/lng swap cannot go unnoticed.
const FIX = { lat: 12.9716, lng: 77.5946, heading: 87.5, speed: 8.2 };

/** An IN_PROGRESS ride with one ACCEPTED rider (one of its two seats taken). */
async function rideUnderWay(status = 'IN_PROGRESS') {
  const driver = await createUser('driver');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, {
    status,
    departureTime: new Date(Date.now() - 5 * MINUTE),
    seatsTotal: 2,
    seatsAvailable: 1,
  });
  const bookingId = await insertBooking(rideId, rider.user.id, { status: 'ACCEPTED' });
  return { driver, rider, rideId, bookingId };
}

/** Connects and joins the ride's room; resolves to the socket. */
async function joined(token, rideId) {
  const socket = await rt.connect(token);
  const ack = await ask(socket, 'ride:join', { rideId });
  expect(ack).toMatchObject({ ok: true });
  return socket;
}

const roomMembers = async (rideId) =>
  (await rt.io.in(hub.rideRoom(rideId)).fetchSockets()).map((s) => s.data.userId);

describe('connection', () => {
  it('is refused without a token', async () => {
    await expect(rt.connect()).rejects.toMatchObject({ data: { code: 'UNAUTHORIZED' } });
  });

  it('is refused with an invalid token', async () => {
    await expect(rt.connect('not-a-jwt')).rejects.toMatchObject({
      data: { code: 'INVALID_TOKEN' },
    });
  });

  it('is refused with an expired token', async () => {
    const { user } = await createUser('late');
    await expect(rt.connect(tokenExpiringAt(user))).rejects.toMatchObject({
      data: { code: 'TOKEN_EXPIRED' },
    });
  });

  it('is refused with a valid token for a user who no longer exists', async () => {
    const { token, user } = await createUser('gone');
    await prisma.user.delete({ where: { id: user.id } });
    await expect(rt.connect(token)).rejects.toMatchObject({ data: { code: 'INVALID_TOKEN' } });
  });

  it('answers TOKEN_EXPIRED and disconnects once the token expires mid-connection', async () => {
    const { driver, rideId } = await rideUnderWay();
    const exp = Math.floor(Date.now() / 1000) + 2;
    const socket = await rt.connect(tokenExpiringAt(driver.user, exp));
    expect(await ask(socket, 'ride:join', { rideId })).toMatchObject({ ok: true });
    await settle(exp * 1000 - Date.now() + 50);
    const disconnected = nextEvent(socket, 'disconnect');

    const ack = await ask(socket, 'ride:join', { rideId });

    expect(ack).toEqual({ error: { code: 'TOKEN_EXPIRED', message: expect.any(String) } });
    expect(await disconnected).toBe('io server disconnect');
  });
});

describe('ride:join', () => {
  it('lets the driver join and returns the ride status and no location yet', async () => {
    const { driver, rideId } = await rideUnderWay();
    const socket = await rt.connect(driver.token);

    const ack = await ask(socket, 'ride:join', { rideId });

    expect(ack).toEqual({
      ok: true,
      ride: { id: rideId, status: 'IN_PROGRESS' },
      lastLocation: null,
    });
  });

  it('lets a rider with an ACCEPTED booking join', async () => {
    const { rider, rideId } = await rideUnderWay();
    await joined(rider.token, rideId);
    expect(await roomMembers(rideId)).toEqual([rider.user.id]);
  });

  it.each(['PENDING', 'REJECTED', 'CANCELLED'])(
    'refuses a rider whose booking is %s',
    async (status) => {
      const { rideId } = await rideUnderWay();
      const other = await createUser('other-rider', 'RIDER');
      await insertBooking(rideId, other.user.id, { status });
      const socket = await rt.connect(other.token);

      const ack = await ask(socket, 'ride:join', { rideId });

      expect(ack).toEqual({ error: { code: 'FORBIDDEN', message: expect.any(String) } });
      expect(await roomMembers(rideId)).toEqual([]);
    },
  );

  it('refuses a user with no booking on the ride', async () => {
    const { rideId } = await rideUnderWay();
    const stranger = await createUser('stranger', 'RIDER');
    const socket = await rt.connect(stranger.token);
    expect(await ask(socket, 'ride:join', { rideId })).toMatchObject({
      error: { code: 'FORBIDDEN' },
    });
  });

  it('answers RIDE_NOT_FOUND for an unknown ride', async () => {
    const { driver } = await rideUnderWay();
    const socket = await rt.connect(driver.token);
    expect(await ask(socket, 'ride:join', { rideId: randomUUID() })).toMatchObject({
      error: { code: 'RIDE_NOT_FOUND' },
    });
  });

  it.each([[undefined], [{}], [{ rideId: 'nope' }], [{ rideId: randomUUID(), extra: 1 }]])(
    'answers VALIDATION_ERROR for payload %j',
    async (payload) => {
      const { driver } = await rideUnderWay();
      const socket = await rt.connect(driver.token);
      expect(await ask(socket, 'ride:join', payload)).toMatchObject({
        error: { code: 'VALIDATION_ERROR' },
      });
    },
  );

  it('removes a rider from the room when they cancel their accepted booking', async () => {
    const { rider, rideId, bookingId } = await rideUnderWay('OPEN');
    const socket = await joined(rider.token, rideId);

    await act(rider.token, bookingId, 'cancel').expect(200);

    expect(await roomMembers(rideId)).toEqual([]);
    expect(await ask(socket, 'ride:join', { rideId })).toMatchObject({
      error: { code: 'FORBIDDEN' },
    });
  });
});

describe('location:update', () => {
  it('broadcasts driver:location to an accepted rider, not back to the driver', async () => {
    const { driver, rider, rideId } = await rideUnderWay();
    const riderSocket = await joined(rider.token, rideId);
    const driverSocket = await joined(driver.token, rideId);
    const echoed = record(driverSocket, 'driver:location');
    const received = nextEvent(riderSocket, 'driver:location');

    expect(await ask(driverSocket, 'location:update', { rideId, ...FIX })).toEqual({ ok: true });

    expect(await received).toEqual({ rideId, ...FIX, recordedAt: expect.any(String) });
    await settle();
    expect(echoed).toEqual([]);
  });

  it('accepts a fix without heading and speed', async () => {
    const { driver, rider, rideId } = await rideUnderWay();
    const riderSocket = await joined(rider.token, rideId);
    const driverSocket = await rt.connect(driver.token);
    const received = nextEvent(riderSocket, 'driver:location');

    await ask(driverSocket, 'location:update', { rideId, lat: FIX.lat, lng: FIX.lng });

    expect(await received).toMatchObject({ heading: null, speed: null });
  });

  it('refuses an update from a rider and broadcasts nothing', async () => {
    const { rider, rideId } = await rideUnderWay();
    const riderSocket = await joined(rider.token, rideId);
    const received = record(riderSocket, 'driver:location');

    const ack = await ask(riderSocket, 'location:update', { rideId, ...FIX });

    expect(ack).toEqual({ error: { code: 'FORBIDDEN', message: expect.any(String) } });
    await settle();
    expect(received).toEqual([]);
    expect(await hub.locations.get(rideId)).toBeNull();
  });

  it('refuses an update from another driver', async () => {
    const { rideId } = await rideUnderWay();
    const other = await createUser('other-driver');
    const socket = await rt.connect(other.token);
    expect(await ask(socket, 'location:update', { rideId, ...FIX })).toMatchObject({
      error: { code: 'FORBIDDEN' },
    });
  });

  it.each(['OPEN', 'FULL', 'COMPLETED', 'CANCELLED'])(
    'refuses an update for a %s ride',
    async (status) => {
      const { driver, rideId } = await rideUnderWay(status);
      const socket = await rt.connect(driver.token);
      expect(await ask(socket, 'location:update', { rideId, ...FIX })).toMatchObject({
        error: { code: 'RIDE_NOT_IN_PROGRESS' },
      });
      expect(await hub.locations.get(rideId)).toBeNull();
    },
  );

  it.each([
    ['lat above 90', { lat: 90.1 }],
    ['lat below -90', { lat: -90.1 }],
    ['lng above 180', { lng: 180.1 }],
    ['lng below -180', { lng: -180.1 }],
    ['lat as a string', { lat: '12.97' }],
    ['lng missing', { lng: undefined }],
    ['heading of 360', { heading: 360 }],
    ['negative speed', { speed: -1 }],
    ['an unknown field', { altitude: 900 }],
    ['a bad rideId', { rideId: 'nope' }],
  ])('answers VALIDATION_ERROR for %s', async (_label, change) => {
    const { driver, rideId } = await rideUnderWay();
    const socket = await rt.connect(driver.token);
    const ack = await ask(socket, 'location:update', { rideId, ...FIX, ...change });
    expect(ack).toMatchObject({ error: { code: 'VALIDATION_ERROR' } });
    // An invalid update does not use up the driver's throttle slot.
    expect(hub.locationThrottle.has(driver.user.id)).toBe(false);
  });

  it('drops updates sent faster than once every 2 seconds', async () => {
    const { driver, rider, rideId } = await rideUnderWay();
    const riderSocket = await joined(rider.token, rideId);
    const received = record(riderSocket, 'driver:location');
    const driverSocket = await rt.connect(driver.token);
    const realNow = Date.now();
    const clock = jest.spyOn(Date, 'now').mockReturnValue(realNow);

    expect(await ask(driverSocket, 'location:update', { rideId, ...FIX })).toEqual({ ok: true });
    clock.mockReturnValue(realNow + 1999);
    const second = { rideId, ...FIX, lat: FIX.lat + 0.001 };
    expect(await ask(driverSocket, 'location:update', second)).toEqual({
      error: { code: 'THROTTLED', message: expect.any(String) },
    });
    await settle();
    expect(received).toHaveLength(1);
    expect((await hub.locations.get(rideId)).lat).toBe(FIX.lat);

    clock.mockReturnValue(realNow + 2000);
    expect(await ask(driverSocket, 'location:update', second)).toEqual({ ok: true });
    await waitFor(() => received.length === 2);
    expect(received[1].lat).toBe(second.lat);
  });

  it('returns the last known location to a rider who rejoins after disconnecting', async () => {
    const { driver, rider, rideId } = await rideUnderWay();
    const first = await joined(rider.token, rideId);
    const driverSocket = await rt.connect(driver.token);
    const received = nextEvent(first, 'driver:location');
    await ask(driverSocket, 'location:update', { rideId, ...FIX });
    const sent = await received;
    first.disconnect();

    const again = await rt.connect(rider.token);
    const ack = await ask(again, 'ride:join', { rideId });

    expect(ack).toEqual({
      ok: true,
      ride: { id: rideId, status: 'IN_PROGRESS' },
      lastLocation: { ...FIX, recordedAt: sent.recordedAt },
    });
  });

  it("removes the driver's throttle entry when they disconnect", async () => {
    const { driver, rideId } = await rideUnderWay();
    const socket = await rt.connect(driver.token);
    await ask(socket, 'location:update', { rideId, ...FIX });
    expect(hub.locationThrottle.has(driver.user.id)).toBe(true);

    socket.disconnect();

    await waitFor(() => !hub.locationThrottle.has(driver.user.id));
  });

  it('keeps the throttle entry while another socket of the same driver is connected', async () => {
    const { driver, rideId } = await rideUnderWay();
    const phone = await rt.connect(driver.token);
    const other = await rt.connect(driver.token);
    await ask(phone, 'location:update', { rideId, ...FIX });

    other.disconnect();
    await waitFor(async () => !(await roomMembersOfUser(driver.user.id)).includes(other.id));

    expect(hub.locationThrottle.has(driver.user.id)).toBe(true);
  });
});

const roomMembersOfUser = async (userId) =>
  (await rt.io.in(hub.userRoom(userId)).fetchSockets()).map((s) => s.id);

describe('when the ride ends', () => {
  it('clears the location and throttle entry and empties the room on complete', async () => {
    const { driver, rider, rideId } = await rideUnderWay();
    const riderSocket = await joined(rider.token, rideId);
    const driverSocket = await rt.connect(driver.token);
    await ask(driverSocket, 'location:update', { rideId, ...FIX });
    const status = nextEvent(riderSocket, 'ride:status');

    await request(app).post(`/rides/${rideId}/complete`).set(bearer(driver.token)).expect(200);

    expect(await status).toEqual({ rideId, status: 'COMPLETED' });
    expect(await hub.locations.get(rideId)).toBeNull();
    expect(hub.locationThrottle.has(driver.user.id)).toBe(false);
    expect(await roomMembers(rideId)).toEqual([]);
    expect(await ask(driverSocket, 'ride:join', { rideId })).toEqual({
      ok: true,
      ride: { id: rideId, status: 'COMPLETED' },
      lastLocation: null,
    });
  });

  it('clears any stored location and throttle entry on cancel', async () => {
    const { driver, rider, rideId } = await rideUnderWay('OPEN');
    const riderSocket = await joined(rider.token, rideId);
    // Only IN_PROGRESS rides get locations, and those cannot be cancelled: seed them directly.
    await hub.locations.set(rideId, { ...FIX, recordedAt: new Date().toISOString() });
    hub.locationThrottle.tryAcquire(driver.user.id);
    const status = nextEvent(riderSocket, 'ride:status');

    await request(app).post(`/rides/${rideId}/cancel`).set(bearer(driver.token)).expect(200);

    expect(await status).toEqual({ rideId, status: 'CANCELLED' });
    expect(await hub.locations.get(rideId)).toBeNull();
    expect(hub.locationThrottle.has(driver.user.id)).toBe(false);
    expect(await roomMembers(rideId)).toEqual([]);
  });
});
