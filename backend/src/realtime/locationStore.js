/**
 * The latest driver location per ride. Every method is async so a shared store (Redis) can
 * replace this one without changing callers; this one lives in one process's memory, so it only
 * works while the API runs as a single instance.
 *
 * A location is { lat, lng, heading, speed, recordedAt } (recordedAt: ISO string).
 */
function createMemoryLocationStore() {
  const locations = new Map();
  return {
    async get(rideId) {
      return locations.get(rideId) ?? null;
    },
    async set(rideId, location) {
      locations.set(rideId, location);
    },
    async delete(rideId) {
      locations.delete(rideId);
    },
  };
}

module.exports = { createMemoryLocationStore };
