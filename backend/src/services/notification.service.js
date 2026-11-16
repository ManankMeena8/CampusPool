const fs = require('fs');
const { env } = require('../config/env');
const prisma = require('../lib/prisma');
const T = require('../lib/notificationTypes');

/*
 * Push notifications through Firebase Cloud Messaging. deliver() sends one outbox row to its
 * one recipient; the notification worker (src/jobs/notificationWorker.js) calls it and records
 * the outcome. Texts are built here, at send time. Without credentials (always in tests, unless
 * a test passes its own client) nothing is looked up or sent.
 */

// The token is gone for good: the app was uninstalled, or the token was never valid.
const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);
// Retrying cannot help. invalid-argument is also what a malformed message gets, so it does not
// clear the token: a bug on our side must not wipe good tokens.
const PERMANENT_CODES = new Set([...INVALID_TOKEN_CODES, 'messaging/invalid-argument']);

/** FCM refused the message for good: do not retry. `code` is safe to store and log. */
class PermanentSendError extends Error {
  constructor(code) {
    super(code);
    this.name = 'PermanentSendError';
    this.code = code;
  }
}

/** The send failed in a way that may pass (unavailable, timeout, internal, quota): retry. */
class TemporarySendError extends Error {
  constructor(code) {
    super(code);
    this.name = 'TemporarySendError';
    this.code = code;
  }
}

/** A short code for an error, never its message (which could quote a token or a URL). */
function errorCode(err) {
  const code = err?.code ?? err?.errorInfo?.code ?? err?.name ?? 'unknown';
  return String(code).slice(0, 100);
}

function log(message, config = env) {
  if (config.NODE_ENV !== 'test') console.log(`[notifications] ${message}`);
}

/**
 * Initializes firebase-admin from the service account file. Returns null (and logs why) when it
 * is not configured or cannot be loaded. Never logs the file's contents or error messages that
 * could quote them: only the path and an error code.
 */
function loadMessaging(config = env) {
  if (config.NODE_ENV === 'test') return null;
  const file = config.FIREBASE_SERVICE_ACCOUNT_PATH;
  if (!file) {
    log('FIREBASE_SERVICE_ACCOUNT_PATH is not set; push notifications are disabled', config);
    return null;
  }
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    const reason = err instanceof SyntaxError ? 'it is not valid JSON' : err.code;
    console.error(
      `[notifications] cannot read ${file} (${reason}); push notifications are disabled`,
    );
    return null;
  }
  try {
    const { initializeApp, cert } = require('firebase-admin/app');
    const { getMessaging } = require('firebase-admin/messaging');
    return getMessaging(initializeApp({ credential: cert(serviceAccount) }, 'campuspool'));
  } catch (err) {
    console.error(
      `[notifications] ${file} was rejected (${err.code ?? err.name}); push notifications are disabled`,
    );
    return null;
  }
}

const seatCount = (n) => `${n} seat${n === 1 ? '' : 's'}`;

/*
 * One entry per event:
 *   about    which record the message describes, loaded when sending
 *   current  whether the event is still true for that record; if not, nothing is sent (a retry
 *            or a late job must not announce something that has since been undone)
 *   text     { title, body } from the record and the row's payload
 */
const EVENTS = {
  /** To the driver: a rider asked for seats. */
  [T.bookingRequested]: {
    about: 'booking',
    current: (b) => b.status === 'PENDING',
    text: (b) => ({
      title: 'New ride request',
      body: `${b.rider.name} asked for ${seatCount(b.seats)} on your ride to ${b.ride.endAddress}.`,
    }),
  },
  /** To the rider: the driver accepted their request. */
  [T.bookingAccepted]: {
    about: 'booking',
    current: (b) => b.status === 'ACCEPTED',
    text: (b) => ({
      title: 'Request accepted',
      body: `${b.ride.driver.name} accepted your request for the ride to ${b.ride.endAddress}.`,
    }),
  },
  /** To the rider: the driver rejected their request. */
  [T.bookingRejected]: {
    about: 'booking',
    current: (b) => b.status === 'REJECTED',
    text: (b) => ({
      title: 'Request declined',
      body: `Your request for the ride to ${b.ride.endAddress} was declined.`,
    }),
  },
  /** To the driver: a rider cancelled a PENDING or ACCEPTED booking. */
  [T.bookingCancelled]: {
    about: 'booking',
    current: (b) => b.status === 'CANCELLED',
    text: (b, { wasAccepted }) => ({
      title: 'Booking cancelled',
      body:
        `${b.rider.name} cancelled their booking on your ride to ${b.ride.endAddress}.` +
        (wasAccepted ? ` ${seatCount(b.seats)} free again.` : ''),
    }),
  },
  /** To the riders whose PENDING requests were rejected when the ride started. */
  [T.bookingAutoRejected]: {
    about: 'ride',
    current: (r) => ['IN_PROGRESS', 'COMPLETED'].includes(r.status),
    text: (r) => ({
      title: 'Request not accepted',
      body: `The ride to ${r.endAddress} has started without accepting your request.`,
    }),
  },
  /** To the riders whose PENDING or ACCEPTED bookings the driver's cancel ended. */
  [T.rideCancelled]: {
    about: 'ride',
    current: (r) => r.status === 'CANCELLED',
    text: (r) => ({
      title: 'Ride cancelled',
      body: `${r.driver.name} cancelled the ride to ${r.endAddress}.`,
    }),
  },
  /** To the riders with an ACCEPTED booking. */
  [T.rideStarted]: {
    about: 'ride',
    current: (r) => r.status === 'IN_PROGRESS',
    text: (r) => ({
      title: 'Ride started',
      body: `${r.driver.name} has started the ride to ${r.endAddress}. Follow it live in the app.`,
    }),
  },
};

const RIDE_FIELDS = {
  id: true,
  status: true,
  endAddress: true,
  driver: { select: { name: true } },
};

const skipped = (reason) => ({ status: 'SKIPPED', reason });

/** The notification functions, over `getMessaging` (null when disabled) and the database. */
function createNotifications({ getMessaging, db }) {
  let messaging;
  const client = () => {
    if (messaging === undefined) messaging = getMessaging();
    return messaging;
  };

  /** The record the event is about and the message's ids, or null when it no longer exists. */
  async function load(about, payload) {
    if (about === 'ride') {
      if (!payload.rideId) return null;
      const ride = await db.ride.findUnique({ where: { id: payload.rideId }, select: RIDE_FIELDS });
      return ride && { record: ride, ids: { rideId: ride.id } };
    }
    if (!payload.bookingId) return null;
    const booking = await db.booking.findUnique({
      where: { id: payload.bookingId },
      select: {
        id: true,
        status: true,
        seats: true,
        rider: { select: { name: true } },
        ride: { select: RIDE_FIELDS },
      },
    });
    return booking && { record: booking, ids: { rideId: booking.ride.id, bookingId: booking.id } };
  }

  /**
   * Sends the outbox `row` to its recipient. Resolves to { status: 'SENT' }, or to
   * { status: 'SKIPPED', reason } when there is nothing to send: sending is not configured, the
   * record is gone, the event is no longer true, or the recipient has no token (looked up now,
   * not when the row was written). Throws PermanentSendError when FCM refuses for good (an
   * invalid token is cleared first, unless the user registered a new one meanwhile) and
   * TemporarySendError for anything worth retrying.
   */
  async function deliver(row) {
    const fcm = client();
    if (!fcm) return skipped('not-configured');
    const event = EVENTS[row.type];
    if (!event) return skipped('unknown-type');

    const payload = row.payload ?? {};
    const found = await load(event.about, payload);
    if (!found) return skipped('gone');
    if (!event.current(found.record)) return skipped('stale');

    const user = await db.user.findUnique({
      where: { id: row.recipientUserId },
      select: { id: true, fcmToken: true },
    });
    if (!user?.fcmToken) return skipped('no-token');

    try {
      await fcm.send({
        token: user.fcmToken,
        notification: event.text(found.record, payload),
        // The app shows foreground messages itself and uses outboxId as the tag too, so a
        // duplicate delivery replaces the first notification instead of stacking.
        data: { type: row.type, ...found.ids, outboxId: row.id },
        android: { priority: 'high', notification: { tag: row.id } },
      });
    } catch (err) {
      const code = errorCode(err);
      if (INVALID_TOKEN_CODES.has(code)) {
        await db.user.updateMany({
          where: { id: user.id, fcmToken: user.fcmToken },
          data: { fcmToken: null },
        });
        log(`cleared an invalid token of user ${user.id}`);
      }
      if (PERMANENT_CODES.has(code)) throw new PermanentSendError(code);
      throw new TemporarySendError(code);
    }
    return { status: 'SENT' };
  }

  return {
    /** Loads the credentials now (server start), so a bad path is logged at boot. */
    enabled() {
      return Boolean(client());
    },
    deliver,
  };
}

module.exports = {
  ...createNotifications({ getMessaging: loadMessaging, db: prisma }),
  createNotifications,
  loadMessaging,
  errorCode,
  PermanentSendError,
  TemporarySendError,
};
