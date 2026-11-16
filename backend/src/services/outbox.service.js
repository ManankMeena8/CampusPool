const NOTIFICATION_TYPES = require('../lib/notificationTypes');

/*
 * The transactional outbox for push notifications. A service that changes a ride or a booking
 * calls enqueue() INSIDE its transaction, so the notification exists if and only if the change
 * committed, then nudge() after the commit. The relay (src/jobs/relay.js) hands the rows to
 * BullMQ and the worker sends them; nothing here talks to Redis or Firebase.
 */

const TYPES = new Set(Object.values(NOTIFICATION_TYPES));

/**
 * Inserts one PENDING row per recipient through `tx`, the caller's transaction. One row each,
 * so a retry never sends again to the people who already got it.
 */
async function enqueue(tx, type, recipientUserIds, payload) {
  if (!TYPES.has(type)) throw new Error(`Unknown notification type: ${type}`);
  const recipients = [...new Set(recipientUserIds)];
  if (recipients.length === 0) return;
  await tx.outbox.createMany({
    data: recipients.map((recipientUserId) => ({ type, recipientUserId, payload })),
  });
}

let wake = null;

/** The relay registers itself here when jobs are on (null to unregister). */
function onNudge(fn) {
  wake = fn;
}

/**
 * Asks the relay to run now instead of at its next tick. Call it after the commit: never fails
 * the request, and does nothing when no relay runs in this process (the rows wait as PENDING).
 */
function nudge() {
  try {
    wake?.();
  } catch {
    // The relay's next tick picks the rows up.
  }
}

module.exports = { enqueue, nudge, onNudge, NOTIFICATION_TYPES };
