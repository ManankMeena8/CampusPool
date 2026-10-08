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

module.exports = router;
