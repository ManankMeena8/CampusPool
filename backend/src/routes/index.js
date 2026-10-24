const { Router } = require('express');
const { env } = require('../config/env');
const healthRoutes = require('./health.routes');
const authRoutes = require('./auth.routes');
const userRoutes = require('./user.routes');
const rideRoutes = require('./ride.routes');
const bookingRoutes = require('./booking.routes');

const router = Router();
router.use('/health', healthRoutes);
router.use('/auth', authRoutes);
router.use('/users', userRoutes);
router.use('/rides', rideRoutes);
router.use('/bookings', bookingRoutes);
// Temporary check of TRUST_PROXY_HOPS after a deploy; 404 unless DEBUG_CLIENT_IP=1.
if (env.DEBUG_CLIENT_IP) router.use('/debug', require('./debug.routes'));

module.exports = router;
