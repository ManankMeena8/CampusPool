const http = require('http');
const app = require('./app');
const { env } = require('./config/env');
const prisma = require('./lib/prisma');
const { createShutdown } = require('./lib/shutdown');
const { attachRealtime } = require('./realtime');
const notifications = require('./services/notification.service');

const server = http.createServer(app);
const io = attachRealtime(server);

// Render forwards traffic to PORT on the container's IPv4 interface.
server.listen(env.PORT, '0.0.0.0', () => {
  console.log(`CampusPool API listening on port ${env.PORT} (${env.NODE_ENV})`);
  if (notifications.enabled()) console.log('[notifications] push notifications are enabled');
  if (env.DEBUG_CLIENT_IP) {
    console.warn(
      'DEBUG_CLIENT_IP=1: GET /debug/client-ip is on. Turn it off right after checking.',
    );
  }
});

const shutdown = createShutdown({ io, prisma });
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
