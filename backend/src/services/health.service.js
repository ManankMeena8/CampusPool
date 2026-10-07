const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');

async function checkDatabase() {
  try {
    await prisma.$queryRaw`SELECT 1`;
    await prisma.$queryRaw`SELECT postgis_version()`;
  } catch {
    throw new AppError('DB_UNAVAILABLE', 'Database or PostGIS check failed', 503);
  }
}

module.exports = { checkDatabase };
