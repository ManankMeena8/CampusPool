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

module.exports = router;
