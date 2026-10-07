const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const controller = require('../controllers/auth.controller');
const v = require('../validators/auth.validators');

const router = Router();
router.post('/signup', validate({ body: v.signupBody }), asyncHandler(controller.signup));
router.post('/verify-otp', validate({ body: v.verifyOtpBody }), asyncHandler(controller.verifyOtp));
router.post('/resend-otp', validate({ body: v.resendOtpBody }), asyncHandler(controller.resendOtp));
router.post('/login', validate({ body: v.loginBody }), asyncHandler(controller.login));
router.post('/refresh', validate({ body: v.refreshBody }), asyncHandler(controller.refresh));
router.post('/logout', validate({ body: v.refreshBody }), asyncHandler(controller.logout));

module.exports = router;
