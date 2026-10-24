// Render sends SIGTERM on every deploy and restart, and kills the process 30 s later.
const FORCE_EXIT_MS = 10000;

/**
 * Returns shutdown(signal): disconnects every socket and closes the HTTP server (io.close waits
 * for requests in flight), then Prisma, and exits 0. If that takes longer than `forceAfterMs`
 * (a request that never ends) or a step fails, it exits 1. A second signal is ignored.
 */
function createShutdown({
  io,
  prisma,
  exit = (code) => process.exit(code),
  forceAfterMs = FORCE_EXIT_MS,
}) {
  let started = false;
  return function shutdown(signal) {
    if (started) return;
    started = true;
    console.log(`${signal} received, shutting down`);
    const force = setTimeout(() => {
      console.error(`Shutdown did not finish within ${forceAfterMs} ms; exiting`);
      exit(1);
    }, forceAfterMs);
    force.unref();

    io.close(async (closeErr) => {
      let code = 0;
      if (closeErr) {
        console.error(`Closing the HTTP server failed (${closeErr.code ?? closeErr.name})`);
        code = 1;
      }
      try {
        await prisma.$disconnect();
      } catch (err) {
        console.error(`Disconnecting Prisma failed (${err.code ?? err.name})`);
        code = 1;
      }
      clearTimeout(force);
      exit(code);
    });
  };
}

module.exports = { createShutdown, FORCE_EXIT_MS };
