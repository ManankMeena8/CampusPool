const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');
const controller = require('../controllers/ride.controller');
const bookingController = require('../controllers/booking.controller');
const v = require('../validators/ride.validators');
const bv = require('../validators/booking.validators');

const router = Router();
router.post(
  '/',
  requireAuth,
  requireRole('DRIVER', 'BOTH'),
  validate({ body: v.createRideBody }),
  asyncHandler(controller.createRide),
);
// /mine and /search must stay above /:id.
router.get('/mine', requireAuth, validate({}), asyncHandler(controller.listMyRides));
// No role check: anyone can look for a ride, including drivers.
router.get(
  '/search',
  requireAuth,
  validate({ query: v.searchRidesQuery }),
  asyncHandler(controller.searchRides),
);
router.get(
  '/:id',
  requireAuth,
  validate({ params: v.rideIdParams }),
  asyncHandler(controller.getRide),
);
// No role check: a driver who later switched to RIDER can still cancel their own rides.
router.post(
  '/:id/cancel',
  requireAuth,
  validate({ params: v.rideIdParams }),
  asyncHandler(controller.cancelRide),
);
// Driver only, checked in the service; no role check, as for cancel.
router.post(
  '/:id/start',
  requireAuth,
  validate({ params: v.rideIdParams }),
  asyncHandler(controller.startRide),
);
router.post(
  '/:id/complete',
  requireAuth,
  validate({ params: v.rideIdParams }),
  asyncHandler(controller.completeRide),
);
// No role check: anyone but the ride's driver can request a seat, including drivers.
router.post(
  '/:id/bookings',
  requireAuth,
  validate({ params: v.rideIdParams, body: bv.createBookingBody }),
  asyncHandler(bookingController.requestBooking),
);
router.get(
  '/:id/bookings',
  requireAuth,
  validate({ params: v.rideIdParams }),
  asyncHandler(bookingController.listRideBookings),
);

module.exports = router;
