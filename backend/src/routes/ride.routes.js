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

module.exports = router;
