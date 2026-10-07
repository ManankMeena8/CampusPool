const app = require('./app');
const { env } = require('./config/env');
const prisma = require('./lib/prisma');

const server = app.listen(env.PORT, () => {
  console.log(`CampusPool API listening on port ${env.PORT} (${env.NODE_ENV})`);
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  server.close(async () => {
    await prisma.$disconnect();
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
