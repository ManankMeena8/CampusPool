const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const { getClientIp } = require('../controllers/debug.controller');

// Mounted only when DEBUG_CLIENT_IP=1 (routes/index.js). Turn it off right after checking.
const router = Router();
router.get('/client-ip', validate({}), asyncHandler(getClientIp));

module.exports = router;
