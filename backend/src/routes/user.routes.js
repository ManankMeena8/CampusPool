const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const requireAuth = require('../middleware/requireAuth');
const controller = require('../controllers/user.controller');
const v = require('../validators/user.validators');

const router = Router();
router.get('/me', requireAuth, validate({}), asyncHandler(controller.getMe));
router.patch(
  '/me',
  requireAuth,
  validate({ body: v.updateMeBody }),
  asyncHandler(controller.updateMe),
);
router.put(
  '/me/fcm-token',
  requireAuth,
  validate({ body: v.fcmTokenBody }),
  asyncHandler(controller.setFcmToken),
);

module.exports = router;
