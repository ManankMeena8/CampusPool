const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const requireAuth = require('../middleware/requireAuth');
const controller = require('../controllers/booking.controller');

// No role checks: whether the user drives the ride or made the booking is checked per booking.
const router = Router();
router.get('/mine', requireAuth, validate({}), asyncHandler(controller.listMyBookings));

module.exports = router;
