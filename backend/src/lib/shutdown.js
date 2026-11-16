// Render sends SIGTERM on every deploy and restart, and kills the process 30 s later.
const FORCE_EXIT_MS = 10000;

/**
 * Returns shutdown(signal), which stops things in dependency order and exits 0:
 *
 *   1. the outbox relay: nothing new reaches the queue
 *   2. the HTTP server and its sockets (io.close waits for requests in flight) and, at the same
 *      time, the notification worker (worker.close waits for the jobs it is sending)
 *   3. the queue, then every Redis connection
 *   4. Prisma, last: requests and jobs in flight still needed it
 *
 * `relay`, `worker`, `queue` and `redis` are absent when the process runs no jobs. A step that
 * fails is logged (its error code only) and the rest still run, but the exit code is 1. If it
 * all takes longer than `forceAfterMs` (a request or a send that never ends), it exits 1; a job
 * cut off this way is retried after the restart. A second signal is ignored.
 */
function createShutdown({
  io,
  prisma,
  relay,
  worker,
  queue,
  redis,
  exit = (code) => process.exit(code),
  forceAfterMs = FORCE_EXIT_MS,
}) {
  let started = false;
  return async function shutdown(signal) {
    if (started) return;
    started = true;
    console.log(`${signal} received, shutting down`);
    const force = setTimeout(() => {
      console.error(`Shutdown did not finish within ${forceAfterMs} ms; exiting`);
      exit(1);
    }, forceAfterMs);
    force.unref();

    let code = 0;
    const step = async (what, fn) => {
      try {
        await fn();
      } catch (err) {
        console.error(`${what} failed (${err.code ?? err.name})`);
        code = 1;
      }
    };
    const closeServer = () =>
      new Promise((resolve, reject) => {
        io.close((err) => (err ? reject(err) : resolve()));
      });

    if (relay) await step('Stopping the outbox relay', () => relay.stop());
    await Promise.all([
      step('Closing the HTTP server', closeServer),
      worker && step('Closing the notification worker', () => worker.close()),
    ]);
    if (queue) await step('Closing the notification queue', () => queue.close());
    if (redis) await step('Closing Redis', () => redis.closeAll());
    await step('Disconnecting Prisma', () => prisma.$disconnect());

    clearTimeout(force);
    exit(code);
  };
}

module.exports = { createShutdown, FORCE_EXIT_MS };
