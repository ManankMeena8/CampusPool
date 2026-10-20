const { describeForLog } = require('../middleware/errorHandler');

/**
 * Starts `fn` without waiting for it, for side effects of a change that has already committed
 * (push notifications). Whatever it throws or rejects with is logged, never raised, so the
 * request that made the change still succeeds.
 */
function runInBackground(what, fn) {
  const fail = (err) => console.error(`[background] ${what} failed:`, describeForLog(err));
  try {
    Promise.resolve(fn()).catch(fail);
  } catch (err) {
    fail(err);
  }
}

module.exports = runInBackground;
