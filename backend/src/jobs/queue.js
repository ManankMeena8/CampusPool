const { Queue } = require('bullmq');

const QUEUE_NAME = 'notifications';

// 8 attempts, waiting about 5, 10, 20 ... 320 s between them (each shortened by up to half, so
// retries of one outage do not all land together): a send is given up after some 10 minutes.
const DEFAULT_JOB_OPTIONS = Object.freeze({
  attempts: 8,
  backoff: { type: 'exponential', delay: 5000, jitter: 0.5 },
  // Finished jobs are kept for a while, capped, so Redis stays small (the free Key Value plan
  // has 25 MB). While a job is kept, adding its id again is a no-op: that is what makes a
  // repeated enqueue harmless. The failed set, with the FAILED outbox rows, is the dead letter.
  removeOnComplete: { age: 60 * 60, count: 1000 },
  removeOnFail: { age: 7 * 24 * 60 * 60, count: 1000 },
});

/**
 * The BullMQ queue of notification jobs, one per outbox row (jobId = the row's id), on a
 * producer connection from lib/redis. `jobOptions` overrides the retry settings (tests).
 */
function createNotificationQueue(connection, { jobOptions = {}, prefix } = {}) {
  const queue = new Queue(QUEUE_NAME, {
    connection,
    ...(prefix && { prefix }),
    defaultJobOptions: { ...DEFAULT_JOB_OPTIONS, ...jobOptions },
  });
  // Connection errors are logged once per outage by lib/redis; without a listener they would
  // be thrown as uncaught.
  queue.on('error', () => {});
  return queue;
}

module.exports = { createNotificationQueue, QUEUE_NAME, DEFAULT_JOB_OPTIONS };
