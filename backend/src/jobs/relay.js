const { errorCode } = require('../services/notification.service');

const DEFAULTS = Object.freeze({
  intervalMs: 1000,
  batchSize: 100,
  // An ENQUEUED row this old that is still not finished is handed to the queue again: its job
  // may be gone (a Redis restart loses every job; the free Key Value plan keeps nothing).
  recoverAfterMs: 5 * 60 * 1000,
  // Redis gets this long per batch before the transaction gives up and releases its rows.
  addTimeoutMs: 3000,
});

function withTimeout(promise, ms, code) {
  let timer;
  const timeout = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(Object.assign(new Error(code), { code })), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * The outbox relay: moves rows from the Outbox table to the BullMQ `queue`.
 *
 * tick() claims up to `batchSize` rows (PENDING, or ENQUEUED for longer than `recoverAfterMs`)
 * with FOR UPDATE SKIP LOCKED, adds one job per row with jobId = the row's id, and marks them
 * ENQUEUED, all in one transaction. SKIP LOCKED lets two relays run at once without taking the
 * same row. If the process dies, or Redis fails, after the jobs were added but before the
 * commit, the rows stay as they were and the next tick adds them again: BullMQ ignores an id it
 * already has, and the worker ignores a row that is already finished, so nothing is sent twice.
 *
 * start() ticks every `intervalMs`; nudge() runs a tick now (after a commit that wrote rows).
 * Ticks never overlap in one relay, and a failed tick is logged once per outage.
 */
function createRelay({ db, queue, ...options }) {
  const { intervalMs, batchSize, recoverAfterMs, addTimeoutMs } = { ...DEFAULTS, ...options };
  let timer = null;
  let running = null;
  let again = false;
  let failing = false;

  /** Hands one batch to the queue; resolves to the number of rows. Rejects if Redis is away. */
  function tick() {
    return db.$transaction(
      async (tx) => {
        const rows = await tx.$queryRaw`
          SELECT "id" FROM "Outbox"
          WHERE "status" = 'PENDING'
             OR ("status" = 'ENQUEUED'
                 AND "enqueuedAt" < (now() AT TIME ZONE 'UTC')
                                    - make_interval(secs => ${recoverAfterMs / 1000}::float8))
          ORDER BY "createdAt"
          LIMIT ${batchSize}::int
          FOR UPDATE SKIP LOCKED`;
        if (rows.length === 0) return 0;
        const ids = rows.map((r) => r.id);
        await withTimeout(
          queue.addBulk(ids.map((id) => ({ name: 'send', data: {}, opts: { jobId: id } }))),
          addTimeoutMs,
          'REDIS_TIMEOUT',
        );
        await tx.outbox.updateMany({
          where: { id: { in: ids } },
          data: { status: 'ENQUEUED', enqueuedAt: new Date() },
        });
        return ids.length;
      },
      { timeout: addTimeoutMs + 5000 },
    );
  }

  /** Ticks until a batch comes back short, so a burst does not wait for the interval. */
  async function drain() {
    do {
      again = false;
      try {
        let claimed;
        do {
          claimed = await tick();
        } while (claimed === batchSize);
        if (failing) console.log('[relay] handing notifications to the queue again');
        failing = false;
      } catch (err) {
        if (!failing) {
          console.error(
            `[relay] could not enqueue notifications (${errorCode(err)}); they stay in the outbox and are retried`,
          );
        }
        failing = true;
        return;
      }
    } while (again);
  }

  function run() {
    if (running) {
      again = true;
      return running;
    }
    running = drain().finally(() => {
      running = null;
    });
    return running;
  }

  return {
    tick,
    /** Runs now; if a run is in flight, another follows it. Never throws or rejects. */
    nudge() {
      run();
    },
    start() {
      if (timer) return;
      timer = setInterval(run, intervalMs);
      timer.unref();
      run();
    },
    /** Stops ticking and waits for the run in flight. */
    async stop() {
      clearInterval(timer);
      timer = null;
      again = false;
      await running;
    },
  };
}

module.exports = { createRelay, DEFAULTS };
