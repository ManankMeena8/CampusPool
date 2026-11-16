const healthService = require('../services/health.service');

/**
 * 200 as long as the database answers. Redis is reported but never decides the status: Render
 * restarts the service when /health fails, and a Redis blip only delays notifications (they
 * wait in the outbox).
 */
async function getHealth(_req, res) {
  const [, redis] = await Promise.all([healthService.checkDatabase(), healthService.checkRedis()]);
  res.json({ status: 'ok', db: 'ok', redis });
}

module.exports = { getHealth };
