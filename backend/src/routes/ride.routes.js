const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');
const controller = require('../controllers/ride.controller');
const v = require('../validators/ride.validators');

const router = Router();
router.post(
  '/',
  requireAuth,
  requireRole('DRIVER', 'BOTH'),
  validate({ body: v.createRideBody }),
  asyncHandler(controller.createRide),
);
// /mine must stay above /:id.
router.get('/mine', requireAuth, validate({}), asyncHandler(controller.listMyRides));
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

module.exports = router;
