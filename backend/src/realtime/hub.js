const { env } = require('../config/env');
const { describeForLog } = require('../middleware/errorHandler');
const { createMemoryLocationStore } = require('./locationStore');
const { createThrottle } = require('./throttle');

/*
 * Shared realtime state: the Socket.io server (once attached), the location store and the
 * location throttle. Services call the notify functions below only after their transaction has
 * committed. Without an attached server (Supertest-only tests) the emits do nothing, and the
 * cleanup still runs.
 */

let io = null;
const locations = createMemoryLocationStore();
const locationThrottle = createThrottle();

const rideRoom = (rideId) => `ride:${rideId}`;
const userRoom = (userId) => `user:${userId}`;

function log(message) {
  if (env.NODE_ENV !== 'test') console.log(`[realtime] ${message}`);
}

function setServer(server) {
  io = server;
}

/** The change is already committed: a failure here is logged, never turned into an error. */
async function afterCommit(what, fn) {
  try {
    await fn();
  } catch (err) {
    console.error(`[realtime] ${what} failed:`, describeForLog(err));
  }
}

const ENDED_STATUSES = ['COMPLETED', 'CANCELLED'];

/**
 * Tells the ride's room its new status. When the ride has ended, also drops its stored location
 * and the driver's throttle entry, and empties the room.
 */
function rideStatusChanged({ id, driverId, status }) {
  return afterCommit('rideStatusChanged', async () => {
    io?.to(rideRoom(id)).emit('ride:status', { rideId: id, status });
    if (!ENDED_STATUSES.includes(status)) return;
    await locations.delete(id);
    locationThrottle.forget(driverId);
    io?.in(rideRoom(id)).socketsLeave(rideRoom(id));
  });
}

/** A rider's ACCEPTED booking ended: their sockets stop following the ride. */
function riderRemoved(rideId, riderId) {
  return afterCommit('riderRemoved', async () => {
    io?.in(userRoom(riderId)).socketsLeave(rideRoom(rideId));
  });
}

/** Called after a socket has disconnected (and so left its rooms). */
function socketDisconnected(userId) {
  // Keep the entry while another socket of the same user is still connected.
  if (!io?.sockets.adapter.rooms.has(userRoom(userId))) locationThrottle.forget(userId);
}

module.exports = {
  locations,
  locationThrottle,
  rideRoom,
  userRoom,
  log,
  setServer,
  rideStatusChanged,
  riderRemoved,
  socketDisconnected,
};
