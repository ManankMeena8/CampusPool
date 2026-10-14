const LOCATION_INTERVAL_MS = 2000;

/**
 * At most one accepted call per key every `intervalMs`. In-memory and per process, like the
 * location store. Entries are removed with `forget` (on disconnect, and when a ride ends) so the
 * Map does not grow without bound.
 */
function createThrottle(intervalMs = LOCATION_INTERVAL_MS) {
  const lastAccepted = new Map();
  return {
    /** True (and records the time) if `key` may go now; false if it is too soon. */
    tryAcquire(key) {
      // Date.now() so tests can move the clock with jest.spyOn.
      const now = Date.now();
      const last = lastAccepted.get(key);
      if (last !== undefined && now - last < intervalMs) return false;
      lastAccepted.set(key, now);
      return true;
    },
    forget(key) {
      lastAccepted.delete(key);
    },
    has(key) {
      return lastAccepted.has(key);
    },
  };
}

module.exports = { createThrottle, LOCATION_INTERVAL_MS };
