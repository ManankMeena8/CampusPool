const { Router } = require('express');
const asyncHandler = require('../lib/asyncHandler');
const validate = require('../middleware/validate');
const { getHealth } = require('../controllers/health.controller');

const router = Router();
router.get('/', validate({}), asyncHandler(getHealth));

module.exports = router;
