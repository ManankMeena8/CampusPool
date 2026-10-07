const healthService = require('../services/health.service');

async function getHealth(_req, res) {
  await healthService.checkDatabase();
  res.json({ status: 'ok', db: 'ok' });
}

module.exports = { getHealth };
