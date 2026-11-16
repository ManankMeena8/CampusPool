const { env } = require('../config/env');
const prisma = require('../lib/prisma');
const redis = require('../lib/redis');
const notifications = require('../services/notification.service');
const outbox = require('../services/outbox.service');
const { createNotificationQueue } = require('./queue');
const { createRelay } = require('./relay');
const { createNotificationWorker } = require('./notificationWorker');

/*
 * The background jobs, run inside the web process (Render's free plan has no background
 * workers): the outbox relay and the notification worker. See outbox.service.js for the flow.
 */

let producer = null;

/**
 * Starts the relay and the worker and returns them for shutdown, or null when ENABLE_JOBS is
 * off: outbox rows are still written and wait as PENDING for a process that runs jobs.
 */
function startJobs(config = env) {
  if (!config.ENABLE_JOBS) {
    console.log('[jobs] ENABLE_JOBS=0: notifications stay in the outbox, nothing is sent');
    return null;
  }
  producer = redis.connect(config.REDIS_URL);
  const queue = createNotificationQueue(producer);
  const worker = createNotificationWorker({
    connection: redis.connect(config.REDIS_URL, { blocking: true }),
    db: prisma,
    deliver: notifications.deliver,
  });
  const relay = createRelay({ db: prisma, queue });
  outbox.onNudge(relay.nudge);
  relay.start();
  return { relay, worker, queue, redis };
}

/** For /health: 'ok' or 'down', or 'disabled' when this process runs no jobs. */
function redisHealth() {
  return producer ? redis.ping(producer) : Promise.resolve('disabled');
}

module.exports = { startJobs, redisHealth };
