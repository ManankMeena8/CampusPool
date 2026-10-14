const AppError = require('./AppError');

/**
 * Every allowed booking status change, in one place. `from` is both the pre-check and the
 * `status IN (...)` guard of the conditional UPDATE that performs the change, so the two cannot
 * drift apart. REJECTED and CANCELLED are final.
 */
const BOOKING_ACTIONS = Object.freeze({
  accept: { from: ['PENDING'], to: 'ACCEPTED', actor: 'driver', done: 'accepted' },
  reject: { from: ['PENDING'], to: 'REJECTED', actor: 'driver', done: 'rejected' },
  cancel: { from: ['PENDING', 'ACCEPTED'], to: 'CANCELLED', actor: 'rider', done: 'cancelled' },
  // The driver cancelled the whole ride.
  rideCancelled: {
    from: ['PENDING', 'ACCEPTED'],
    to: 'CANCELLED',
    actor: 'system',
    done: 'cancelled',
  },
  // The driver started the ride: requests nobody accepted can no longer be.
  rideStarted: { from: ['PENDING'], to: 'REJECTED', actor: 'system', done: 'rejected' },
});

/** Throws 409 INVALID_TRANSITION unless `action` may be applied to a booking in `status`. */
function assertTransition(action, status) {
  const { from, done } = BOOKING_ACTIONS[action];
  if (!from.includes(status)) {
    throw new AppError(
      'INVALID_TRANSITION',
      `A ${status} booking cannot be ${done}; only ${from.join(' or ')} bookings can`,
      409,
    );
  }
}

module.exports = { BOOKING_ACTIONS, assertTransition };
