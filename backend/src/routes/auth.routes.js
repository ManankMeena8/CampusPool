const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const { authLimiter, refreshLimiter, loginLimiter } = require('../middleware/rateLimits');
const controller = require('../controllers/auth.controller');
const v = require('../validators/auth.validators');

// Every route but refresh shares authLimiter; refresh, which every active app calls, has its own.
const router = Router();
router.post(
  '/signup',
  authLimiter,
  validate({ body: v.signupBody }),
  asyncHandler(controller.signup),
);
router.post(
  '/verify-otp',
  authLimiter,
  validate({ body: v.verifyOtpBody }),
  asyncHandler(controller.verifyOtp),
);
router.post(
  '/resend-otp',
  authLimiter,
  validate({ body: v.resendOtpBody }),
  asyncHandler(controller.resendOtp),
);
router.post(
  '/login',
  authLimiter,
  loginLimiter,
  validate({ body: v.loginBody }),
  asyncHandler(controller.login),
);
router.post(
  '/refresh',
  refreshLimiter,
  validate({ body: v.refreshBody }),
  asyncHandler(controller.refresh),
);
router.post(
  '/logout',
  authLimiter,
  validate({ body: v.refreshBody }),
  asyncHandler(controller.logout),
);

module.exports = router;
