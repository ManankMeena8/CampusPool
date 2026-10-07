const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const { getHealth } = require('../controllers/health.controller');

const router = Router();
router.get('/', asyncHandler(getHealth));

module.exports = router;
