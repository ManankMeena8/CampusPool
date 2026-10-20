const fs = require('fs');
const { env } = require('../config/env');
const prisma = require('../lib/prisma');

/*
 * Push notifications through Firebase Cloud Messaging, one function per event. Callers run them
 * with runInBackground once their transaction has committed, and pass the recipients' user ids;
 * texts are built here. Without credentials (always in tests) nothing is looked up or sent.
 */

// The token is gone for good: the app was uninstalled, or the token was never valid.
const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

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

/** The notification functions, over `getMessaging` (null when disabled) and the database. */
function createNotifications({ getMessaging, db }) {
  let messaging;
  const client = () => {
    if (messaging === undefined) messaging = getMessaging();
    return messaging;
  };

  /**
   * Sends to every recipient with a token. `build` runs only when sending is enabled, so a
   * disabled service never touches the database; it returns the message, or null to send none.
   * Tokens FCM reports as invalid are cleared, unless the user registered a new one meanwhile.
   */
  async function send(type, userIds, build) {
    if (userIds.length === 0) return;
    const fcm = client();
    if (!fcm) {
      log(`not configured; skipped ${type} for ${userIds.length} user(s)`);
      return;
    }
    const content = await build();
    if (!content) return;
    const users = await db.user.findMany({
      where: { id: { in: userIds }, fcmToken: { not: null } },
      select: { id: true, fcmToken: true },
    });
    if (users.length === 0) return;

    const data = { type, ...content.data };
    const { responses } = await fcm.sendEach(
      users.map((u) => ({
        token: u.fcmToken,
        notification: { title: content.title, body: content.body },
        data,
        android: { priority: 'high' },
      })),
    );
    await Promise.all(
      responses.map(async ({ success, error }, i) => {
        if (success) return;
        const { id, fcmToken } = users[i];
        if (INVALID_TOKEN_CODES.has(error?.code)) {
          await db.user.updateMany({ where: { id, fcmToken }, data: { fcmToken: null } });
          log(`cleared an invalid token of user ${id}`);
        } else {
          console.error(`[notifications] ${type} to user ${id} failed: ${error?.code ?? error}`);
        }
      }),
    );
  }

  const findRide = (id) =>
    db.ride.findUnique({
      where: { id },
      select: { id: true, endAddress: true, driver: { select: { name: true } } },
    });

  const findBooking = (id) =>
    db.booking.findUnique({
      where: { id },
      select: {
        id: true,
        seats: true,
        rider: { select: { name: true } },
        ride: { select: { id: true, endAddress: true, driver: { select: { name: true } } } },
      },
    });

  const seatCount = (n) => `${n} seat${n === 1 ? '' : 's'}`;

  /** A message about one booking; `text(booking)` gives { title, body }. */
  const aboutBooking = (bookingId, text) => async () => {
    const booking = await findBooking(bookingId);
    if (!booking) return null;
    return { ...text(booking), data: { rideId: booking.ride.id, bookingId: booking.id } };
  };

  /** A message about a ride; `text(ride)` gives { title, body }. */
  const aboutRide = (rideId, text) => async () => {
    const ride = await findRide(rideId);
    if (!ride) return null;
    return { ...text(ride), data: { rideId: ride.id } };
  };

  return {
    /** Loads the credentials now (server start), so a bad path is logged at boot. */
    enabled() {
      return Boolean(client());
    },

    /** To the driver: a rider asked for seats. */
    bookingRequested({ bookingId, driverId }) {
      return send(
        'booking.requested',
        [driverId],
        aboutBooking(bookingId, (b) => ({
          title: 'New ride request',
          body: `${b.rider.name} asked for ${seatCount(b.seats)} on your ride to ${b.ride.endAddress}.`,
        })),
      );
    },

    /** To the rider: the driver accepted their request. */
    bookingAccepted({ bookingId, riderId }) {
      return send(
        'booking.accepted',
        [riderId],
        aboutBooking(bookingId, (b) => ({
          title: 'Request accepted',
          body: `${b.ride.driver.name} accepted your request for the ride to ${b.ride.endAddress}.`,
        })),
      );
    },

    /** To the rider: the driver rejected their request. */
    bookingRejected({ bookingId, riderId }) {
      return send(
        'booking.rejected',
        [riderId],
        aboutBooking(bookingId, (b) => ({
          title: 'Request declined',
          body: `Your request for the ride to ${b.ride.endAddress} was declined.`,
        })),
      );
    },

    /** To the driver: a rider cancelled a PENDING or ACCEPTED booking. */
    bookingCancelled({ bookingId, driverId, wasAccepted }) {
      return send(
        'booking.cancelled',
        [driverId],
        aboutBooking(bookingId, (b) => ({
          title: 'Booking cancelled',
          body:
            `${b.rider.name} cancelled their booking on your ride to ${b.ride.endAddress}.` +
            (wasAccepted ? ` ${seatCount(b.seats)} free again.` : ''),
        })),
      );
    },

    /** To the riders whose PENDING requests were rejected when the ride started. */
    bookingAutoRejected({ rideId, riderIds }) {
      return send(
        'booking.autoRejected',
        riderIds,
        aboutRide(rideId, (r) => ({
          title: 'Request not accepted',
          body: `The ride to ${r.endAddress} has started without accepting your request.`,
        })),
      );
    },

    /** To the riders whose PENDING or ACCEPTED bookings the driver's cancel ended. */
    rideCancelled({ rideId, riderIds }) {
      return send(
        'ride.cancelled',
        riderIds,
        aboutRide(rideId, (r) => ({
          title: 'Ride cancelled',
          body: `${r.driver.name} cancelled the ride to ${r.endAddress}.`,
        })),
      );
    },

    /** To the riders with an ACCEPTED booking. */
    rideStarted({ rideId, riderIds }) {
      return send(
        'ride.started',
        riderIds,
        aboutRide(rideId, (r) => ({
          title: 'Ride started',
          body: `${r.driver.name} has started the ride to ${r.endAddress}. Follow it live in the app.`,
        })),
      );
    },
  };
}

module.exports = {
  ...createNotifications({ getMessaging: loadMessaging, db: prisma }),
  createNotifications,
  loadMessaging,
};
