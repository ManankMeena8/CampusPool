/**
 * The push notification events: the `type` of an outbox row and of the message's data. The
 * mobile app routes taps by these names (lib/features/notifications/data/notification_route.dart).
 */
const NOTIFICATION_TYPES = Object.freeze({
  bookingRequested: 'booking.requested',
  bookingAccepted: 'booking.accepted',
  bookingRejected: 'booking.rejected',
  bookingCancelled: 'booking.cancelled',
  bookingAutoRejected: 'booking.autoRejected',
  rideCancelled: 'ride.cancelled',
  rideStarted: 'ride.started',
});

module.exports = NOTIFICATION_TYPES;
