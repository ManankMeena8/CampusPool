const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const { redisHealth } = require('../jobs');

async function checkDatabase() {
  try {
    await prisma.$queryRaw`SELECT 1`;
    await prisma.$queryRaw`SELECT postgis_version()`;
  } catch {
    throw new AppError('DB_UNAVAILABLE', 'Database or PostGIS check failed', 503);
  }
}

/** 'ok', 'down', or 'disabled' when this process runs no jobs. Never throws. */
function checkRedis() {
  return redisHealth();
}

module.exports = { checkDatabase, checkRedis };
