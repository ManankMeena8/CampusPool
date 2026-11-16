const { Worker, UnrecoverableError } = require('bullmq');
const { QUEUE_NAME } = require('./queue');
const { errorCode, PermanentSendError } = require('../services/notification.service');

// A row in one of these is still to be sent. PENDING counts: the relay may have added the job
// and died before marking the row ENQUEUED.
const UNFINISHED = ['PENDING', 'ENQUEUED'];

/**
 * The BullMQ worker that sends notification jobs. A job's id is its outbox row's id.
 *
 *   row missing or already finished  nothing (a duplicate or recovered job)
 *   deliver() says SENT / SKIPPED    recorded on the row, with processedAt
 *   PermanentSendError               SKIPPED with the error code, never retried
 *   any other error                  retried by BullMQ with backoff; when the last attempt fails
 *                                    the row is FAILED with the error code
 *
 * Every write is conditional on the row still being unfinished, so a job that runs twice (a
 * stalled job, a recovery) cannot overwrite an outcome. Errors that reach BullMQ, and so Redis
 * and the logs, carry only a code.
 *
 * `connection` must be a blocking connection from lib/redis; `deliver` is
 * notification.service's.
 */
function createNotificationWorker({ connection, db, deliver, concurrency = 5, prefix }) {
  const finish = (id, status, lastError = null) =>
    db.outbox.updateMany({
      where: { id, status: { in: UNFINISHED } },
      data: { status, lastError, processedAt: new Date() },
    });

  async function handle(job) {
    const id = job.id;
    const row = await db.outbox.findUnique({ where: { id } });
    if (!row || !UNFINISHED.includes(row.status)) return;
    await db.outbox.updateMany({
      where: { id, status: { in: UNFINISHED } },
      data: { attempts: { increment: 1 } },
    });

    let outcome;
    try {
      outcome = await deliver(row);
    } catch (err) {
      const code = errorCode(err);
      if (err instanceof PermanentSendError) {
        await finish(id, 'SKIPPED', code);
        throw new UnrecoverableError(code);
      }
      // attemptsMade counts the attempts before this one.
      if (job.attemptsMade + 1 >= (job.opts.attempts ?? 1)) {
        await finish(id, 'FAILED', code);
      } else {
        await db.outbox.updateMany({
          where: { id, status: { in: UNFINISHED } },
          data: { lastError: code },
        });
      }
      throw new Error(code);
    }
    await finish(id, outcome.status, outcome.reason ?? null);
  }

  const worker = new Worker(QUEUE_NAME, handle, {
    connection,
    concurrency,
    ...(prefix && { prefix }),
  });
  worker.on('failed', (job, err) => {
    if (process.env.NODE_ENV === 'test') return;
    const attempts = job?.opts?.attempts ?? 1;
    const final = err instanceof UnrecoverableError || (job?.attemptsMade ?? attempts) >= attempts;
    console.error(
      `[notifications] job ${job?.id} failed (${err.message})${final ? '; giving up' : '; will retry'}`,
    );
  });
  // Connection errors are logged once per outage by lib/redis; without a listener they would
  // be thrown as uncaught.
  worker.on('error', () => {});
  return worker;
}

module.exports = { createNotificationWorker };
