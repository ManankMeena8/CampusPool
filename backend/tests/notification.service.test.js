const fs = require('fs');
const os = require('os');
const path = require('path');
const { prisma, resetDb } = require('./helpers/auth');
const { createUser, insertRide } = require('./helpers/rides');
const { insertBooking } = require('./helpers/bookings');
const { createNotifications, loadMessaging } = require('../src/services/notification.service');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

const ok = () => ({ success: true });
const failed = (code) => ({ success: false, error: Object.assign(new Error(code), { code }) });

/** A fake FCM client: sendEach answers with `results(messages)` (all succeed by default). */
function fakeMessaging(results = (messages) => messages.map(ok)) {
  return { sendEach: jest.fn(async (messages) => ({ responses: await results(messages) })) };
}

const withToken = (user, fcmToken) =>
  prisma.user.update({ where: { id: user.user.id }, data: { fcmToken } });

const tokenOf = async (user) =>
  (await prisma.user.findUniqueOrThrow({ where: { id: user.user.id } })).fcmToken;

async function setup() {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id);
  const bookingId = await insertBooking(rideId, rider.user.id, { seats: 2 });
  return { driver, rider, rideId, bookingId };
}

describe('when not configured', () => {
  it('sends nothing and never touches the database', async () => {
    const db = { user: { findMany: jest.fn() }, ride: { findUnique: jest.fn() } };
    const notifications = createNotifications({ getMessaging: () => null, db });

    expect(notifications.enabled()).toBe(false);
    await notifications.rideStarted({ rideId: 'r', riderIds: ['a', 'b'] });
    expect(db.user.findMany).not.toHaveBeenCalled();
    expect(db.ride.findUnique).not.toHaveBeenCalled();
  });

  it('is never configured in tests, whatever the env says', () => {
    expect(
      loadMessaging({ NODE_ENV: 'test', FIREBASE_SERVICE_ACCOUNT_PATH: __filename }),
    ).toBeNull();
  });
});

describe('loadMessaging', () => {
  let errSpy;
  let logSpy;
  let dir;
  beforeEach(() => {
    errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'campuspool-fcm-'));
  });
  afterEach(() => {
    errSpy.mockRestore();
    logSpy.mockRestore();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const load = (file) =>
    loadMessaging({ NODE_ENV: 'development', FIREBASE_SERVICE_ACCOUNT_PATH: file });
  const logged = () => [...errSpy.mock.calls, ...logSpy.mock.calls].flat().join('\n');

  it('logs and disables sending when no path is set', () => {
    expect(load(undefined)).toBeNull();
    expect(logged()).toMatch(/FIREBASE_SERVICE_ACCOUNT_PATH is not set/);
  });

  it('logs the path and error code when the file is missing', () => {
    const file = path.join(dir, 'missing.json');
    expect(load(file)).toBeNull();
    expect(logged()).toContain(file);
    expect(logged()).toContain('ENOENT');
  });

  it.each([
    ['invalid JSON', '{"private_key": "SECRET-KEY-MATERIAL"'],
    ['a rejected service account', '{"private_key": "SECRET-KEY-MATERIAL"}'],
  ])('never logs the contents of %s', (_label, contents) => {
    const file = path.join(dir, 'account.json');
    fs.writeFileSync(file, contents);
    expect(load(file)).toBeNull();
    expect(logged()).toContain(file);
    expect(logged()).not.toContain('SECRET');
  });
});

describe('sending', () => {
  it('sends to recipients with a token and skips those without one', async () => {
    const { driver, rider, rideId } = await setup();
    const other = await createUser('other', 'RIDER');
    await withToken(rider, 'rider-token');
    const messaging = fakeMessaging();
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.rideStarted({ rideId, riderIds: [rider.user.id, other.user.id] });

    expect(messaging.sendEach).toHaveBeenCalledTimes(1);
    const [messages] = messaging.sendEach.mock.calls[0];
    expect(messages).toEqual([
      {
        token: 'rider-token',
        notification: {
          title: 'Ride started',
          body: expect.stringContaining(driver.user.name),
        },
        data: { type: 'ride.started', rideId },
        android: { priority: 'high' },
      },
    ]);
  });

  it('describes the booking, with string-only data', async () => {
    const { driver, rider, rideId, bookingId } = await setup();
    await withToken(driver, 'driver-token');
    const messaging = fakeMessaging();
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.bookingCancelled({
      bookingId,
      driverId: driver.user.id,
      wasAccepted: true,
    });

    const [[message]] = messaging.sendEach.mock.calls[0];
    expect(message.notification.body).toContain(rider.user.name);
    expect(message.notification.body).toContain('2 seats free again');
    expect(message.data).toEqual({ type: 'booking.cancelled', rideId, bookingId });
  });

  it('sends nothing when no recipient has a token', async () => {
    const { rider, rideId } = await setup();
    const messaging = fakeMessaging();
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.rideCancelled({ rideId, riderIds: [rider.user.id] });
    await notifications.rideCancelled({ rideId, riderIds: [] });
    expect(messaging.sendEach).not.toHaveBeenCalled();
  });

  it.each(['messaging/registration-token-not-registered', 'messaging/invalid-registration-token'])(
    'clears a token FCM reports as %s and keeps the others',
    async (code) => {
      const { rider, rideId } = await setup();
      const second = await createUser('second', 'RIDER');
      await withToken(rider, 'dead-token');
      await withToken(second, 'live-token');
      const messaging = fakeMessaging((messages) =>
        messages.map((m) => (m.token === 'dead-token' ? failed(code) : ok())),
      );
      const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

      await notifications.rideStarted({ rideId, riderIds: [rider.user.id, second.user.id] });

      expect(await tokenOf(rider)).toBeNull();
      expect(await tokenOf(second)).toBe('live-token');
    },
  );

  it('keeps the token on other errors, and logs them', async () => {
    const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const { rider, rideId } = await setup();
    await withToken(rider, 'rider-token');
    const messaging = fakeMessaging((messages) =>
      messages.map(() => failed('messaging/internal-error')),
    );
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.rideStarted({ rideId, riderIds: [rider.user.id] });

    expect(await tokenOf(rider)).toBe('rider-token');
    expect(errSpy.mock.calls.flat().join(' ')).toContain('messaging/internal-error');
    errSpy.mockRestore();
  });

  it('keeps a token the user registered while the invalid one was being sent to', async () => {
    const { rider, rideId } = await setup();
    await withToken(rider, 'dead-token');
    const messaging = fakeMessaging(async (messages) => {
      await withToken(rider, 'new-token');
      return messages.map(() => failed('messaging/registration-token-not-registered'));
    });
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.rideStarted({ rideId, riderIds: [rider.user.id] });
    expect(await tokenOf(rider)).toBe('new-token');
  });

  it('sends nothing for a ride or booking that no longer exists', async () => {
    const { driver, rider, rideId, bookingId } = await setup();
    await withToken(driver, 'driver-token');
    await withToken(rider, 'rider-token');
    await prisma.ride.delete({ where: { id: rideId } }); // cascades to the booking
    const messaging = fakeMessaging();
    const notifications = createNotifications({ getMessaging: () => messaging, db: prisma });

    await notifications.bookingRequested({ bookingId, driverId: driver.user.id });
    await notifications.rideCancelled({ rideId, riderIds: [rider.user.id] });
    expect(messaging.sendEach).not.toHaveBeenCalled();
  });

  it('loads the credentials only once', async () => {
    const getMessaging = jest.fn(() => null);
    const notifications = createNotifications({ getMessaging, db: prisma });
    notifications.enabled();
    await notifications.rideStarted({ rideId: 'r', riderIds: ['a'] });
    expect(getMessaging).toHaveBeenCalledTimes(1);
  });
});
