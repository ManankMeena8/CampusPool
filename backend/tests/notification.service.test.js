const fs = require('fs');
const os = require('os');
const path = require('path');
const { prisma, resetDb } = require('./helpers/auth');
const { createUser, insertRide } = require('./helpers/rides');
const { insertBooking } = require('./helpers/bookings');
const { insertOutbox, fcmError, fakeMessaging, withToken, tokenOf } = require('./helpers/outbox');
const {
  createNotifications,
  loadMessaging,
  PermanentSendError,
  TemporarySendError,
} = require('../src/services/notification.service');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

async function setup(rideOverrides = {}) {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, rideOverrides);
  const bookingId = await insertBooking(rideId, rider.user.id, { seats: 2 });
  return { driver, rider, rideId, bookingId };
}

const sender = (messaging) => createNotifications({ getMessaging: () => messaging, db: prisma });
const setRide = (id, status) => prisma.ride.update({ where: { id }, data: { status } });
const setBooking = (id, status) => prisma.booking.update({ where: { id }, data: { status } });

describe('when not configured', () => {
  it('skips the row and never touches the database', async () => {
    const db = {
      user: { findUnique: jest.fn() },
      ride: { findUnique: jest.fn() },
      booking: { findUnique: jest.fn() },
    };
    const notifications = createNotifications({ getMessaging: () => null, db });

    expect(notifications.enabled()).toBe(false);
    expect(
      await notifications.deliver({
        id: 'o',
        type: 'ride.started',
        recipientUserId: 'u',
        payload: { rideId: 'r' },
      }),
    ).toEqual({ status: 'SKIPPED', reason: 'not-configured' });
    for (const model of Object.values(db)) expect(model.findUnique).not.toHaveBeenCalled();
  });

  it('is never configured in tests, whatever the env says', () => {
    expect(
      loadMessaging({ NODE_ENV: 'test', FIREBASE_SERVICE_ACCOUNT_PATH: __filename }),
    ).toBeNull();
  });

  it('loads the credentials only once', async () => {
    const getMessaging = jest.fn(() => null);
    const notifications = createNotifications({ getMessaging, db: prisma });
    notifications.enabled();
    await notifications.deliver({ id: 'o', type: 'ride.started', payload: {} });
    expect(getMessaging).toHaveBeenCalledTimes(1);
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

describe('deliver', () => {
  it('sends a ride message to the recipient, tagged with the outbox id', async () => {
    const { driver, rider, rideId } = await setup();
    await setRide(rideId, 'IN_PROGRESS');
    await withToken(rider, 'rider-token');
    const row = await insertOutbox('ride.started', rider.user.id, { rideId });
    const messaging = fakeMessaging();

    expect(await sender(messaging).deliver(row)).toEqual({ status: 'SENT' });

    expect(messaging.send).toHaveBeenCalledTimes(1);
    expect(messaging.send).toHaveBeenCalledWith({
      token: 'rider-token',
      notification: { title: 'Ride started', body: expect.stringContaining(driver.user.name) },
      data: { type: 'ride.started', rideId, outboxId: row.id },
      android: { priority: 'high', notification: { tag: row.id } },
    });
  });

  it('describes the booking, with string-only data', async () => {
    const { driver, rider, rideId, bookingId } = await setup();
    await setBooking(bookingId, 'CANCELLED');
    await withToken(driver, 'driver-token');
    const row = await insertOutbox('booking.cancelled', driver.user.id, {
      rideId,
      bookingId,
      wasAccepted: true,
    });
    const messaging = fakeMessaging();

    await sender(messaging).deliver(row);

    const [message] = messaging.send.mock.calls[0];
    expect(message.token).toBe('driver-token');
    expect(message.notification.body).toContain(rider.user.name);
    expect(message.notification.body).toContain('2 seats free again');
    expect(message.data).toEqual({
      type: 'booking.cancelled',
      rideId,
      bookingId,
      outboxId: row.id,
    });
    for (const value of Object.values(message.data)) expect(typeof value).toBe('string');
  });

  // [type, about, the statuses in which the event is still true, a status in which it is not]
  const EVENTS = [
    ['booking.requested', 'booking', ['PENDING'], 'ACCEPTED', 'New ride request'],
    ['booking.accepted', 'booking', ['ACCEPTED'], 'CANCELLED', 'Request accepted'],
    ['booking.rejected', 'booking', ['REJECTED'], 'PENDING', 'Request declined'],
    ['booking.cancelled', 'booking', ['CANCELLED'], 'ACCEPTED', 'Booking cancelled'],
    ['booking.autoRejected', 'ride', ['IN_PROGRESS', 'COMPLETED'], 'OPEN', 'Request not accepted'],
    ['ride.cancelled', 'ride', ['CANCELLED'], 'OPEN', 'Ride cancelled'],
    ['ride.started', 'ride', ['IN_PROGRESS'], 'COMPLETED', 'Ride started'],
  ];

  it.each(EVENTS)(
    '%s is sent only while it is still true',
    async (type, about, trueIn, falseIn, title) => {
      const { rider, rideId, bookingId } = await setup();
      await withToken(rider, 'rider-token');
      const set = (status) =>
        about === 'ride' ? setRide(rideId, status) : setBooking(bookingId, status);
      const row = await insertOutbox(type, rider.user.id, { rideId, bookingId });
      const messaging = fakeMessaging();

      await set(falseIn);
      expect(await sender(messaging).deliver(row)).toEqual({ status: 'SKIPPED', reason: 'stale' });
      expect(messaging.send).not.toHaveBeenCalled();

      for (const status of trueIn) {
        messaging.send.mockClear();
        await set(status);
        expect(await sender(messaging).deliver(row)).toEqual({ status: 'SENT' });
        expect(messaging.send.mock.calls[0][0].notification.title).toBe(title);
      }
    },
  );

  it('skips a recipient without a token, looked up when sending', async () => {
    const { rider, rideId } = await setup();
    await setRide(rideId, 'CANCELLED');
    const row = await insertOutbox('ride.cancelled', rider.user.id, { rideId });
    const messaging = fakeMessaging();

    expect(await sender(messaging).deliver(row)).toEqual({ status: 'SKIPPED', reason: 'no-token' });
    expect(messaging.send).not.toHaveBeenCalled();

    // Registered after the row was written: the same row is now sent.
    await withToken(rider, 'late-token');
    expect(await sender(messaging).deliver(row)).toEqual({ status: 'SENT' });
    expect(messaging.send.mock.calls[0][0].token).toBe('late-token');
  });

  it('skips a ride or booking that no longer exists, and an unknown type', async () => {
    const { driver, rider, rideId, bookingId } = await setup();
    await withToken(driver, 'driver-token');
    await withToken(rider, 'rider-token');
    const aboutBooking = await insertOutbox('booking.requested', driver.user.id, {
      rideId,
      bookingId,
    });
    const aboutRide = await insertOutbox('ride.cancelled', rider.user.id, { rideId });
    const unknown = await insertOutbox('ride.exploded', rider.user.id, { rideId });
    await prisma.ride.delete({ where: { id: rideId } }); // cascades to the booking
    const messaging = fakeMessaging();
    const { deliver } = sender(messaging);

    expect(await deliver(aboutBooking)).toEqual({ status: 'SKIPPED', reason: 'gone' });
    expect(await deliver(aboutRide)).toEqual({ status: 'SKIPPED', reason: 'gone' });
    expect(await deliver(unknown)).toEqual({ status: 'SKIPPED', reason: 'unknown-type' });
    expect(messaging.send).not.toHaveBeenCalled();
  });

  describe('when FCM refuses', () => {
    async function rowFor(token = 'rider-token') {
      const { rider, rideId } = await setup();
      await setRide(rideId, 'IN_PROGRESS');
      await withToken(rider, token);
      return { rider, row: await insertOutbox('ride.started', rider.user.id, { rideId }) };
    }

    it.each([
      'messaging/registration-token-not-registered',
      'messaging/invalid-registration-token',
    ])('%s is permanent and clears the token', async (code) => {
      const { rider, row } = await rowFor('dead-token');
      const other = await createUser('other', 'RIDER');
      await withToken(other, 'live-token');
      const messaging = fakeMessaging(() => {
        throw fcmError(code);
      });

      const error = await sender(messaging)
        .deliver(row)
        .catch((e) => e);

      expect(error).toBeInstanceOf(PermanentSendError);
      expect(error.code).toBe(code);
      expect(await tokenOf(rider)).toBeNull();
      expect(await tokenOf(other)).toBe('live-token');
    });

    it('invalid-argument is permanent but keeps the token', async () => {
      const { rider, row } = await rowFor();
      const messaging = fakeMessaging(() => {
        throw fcmError('messaging/invalid-argument');
      });

      await expect(sender(messaging).deliver(row)).rejects.toBeInstanceOf(PermanentSendError);
      expect(await tokenOf(rider)).toBe('rider-token');
    });

    it.each([
      'messaging/server-unavailable',
      'messaging/internal-error',
      'messaging/message-rate-exceeded',
      'app/network-timeout',
      'something/never-seen-before',
    ])('%s is temporary and keeps the token', async (code) => {
      const { rider, row } = await rowFor();
      const messaging = fakeMessaging(() => {
        throw fcmError(code);
      });

      const error = await sender(messaging)
        .deliver(row)
        .catch((e) => e);

      expect(error).toBeInstanceOf(TemporarySendError);
      expect(error.code).toBe(code);
      expect(await tokenOf(rider)).toBe('rider-token');
    });

    it('an error without a code is temporary, named by its class', async () => {
      const { row } = await rowFor();
      const messaging = fakeMessaging(() => {
        throw new TypeError('fetch failed for token SECRET-TOKEN-TEXT');
      });
      const error = await sender(messaging)
        .deliver(row)
        .catch((e) => e);
      expect(error).toBeInstanceOf(TemporarySendError);
      expect(error.code).toBe('TypeError');
    });

    it('never passes on the message FCM gave, only its code', async () => {
      const { row } = await rowFor();
      const messaging = fakeMessaging(() => {
        throw fcmError('messaging/internal-error');
      });
      const error = await sender(messaging)
        .deliver(row)
        .catch((e) => e);
      expect(`${error.message} ${error.stack}`).not.toContain('SECRET');
    });

    it('keeps a token the user registered while the invalid one was being sent to', async () => {
      const { rider, row } = await rowFor('dead-token');
      const messaging = fakeMessaging(async () => {
        await withToken(rider, 'new-token');
        throw fcmError('messaging/registration-token-not-registered');
      });

      await expect(sender(messaging).deliver(row)).rejects.toBeInstanceOf(PermanentSendError);
      expect(await tokenOf(rider)).toBe('new-token');
    });
  });
});
