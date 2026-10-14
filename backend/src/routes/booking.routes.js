const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const requireAuth = require('../middleware/requireAuth');
const controller = require('../controllers/booking.controller');
const v = require('../validators/booking.validators');

// No role checks: whether the user drives the ride or made the booking is checked per booking.
const router = Router();
router.get('/mine', requireAuth, validate({}), asyncHandler(controller.listMyBookings));
for (const action of ['accept', 'reject', 'cancel']) {
  router.post(
    `/:id/${action}`,
    requireAuth,
    validate({ params: v.bookingIdParams }),
    asyncHandler(controller[`${action}Booking`]),
  );
}

module.exports = router;
