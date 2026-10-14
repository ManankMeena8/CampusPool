const AppError = require('../lib/AppError');
const { toErrorResponse } = require('../middleware/errorHandler');
const tracking = require('../services/tracking.service');
const { joinRidePayload, locationUpdatePayload } = require('../validators/realtime.validators');
const { tokenExpired } = require('./auth');
const { rideRoom } = require('./hub');

/**
 * Registers `event`: checks the token is still valid, validates the payload with `schema`, runs
 * `fn` and acknowledges with { ok: true, ...result } or { error: { code, message } }.
 */
function on(socket, event, schema, fn) {
  socket.on(event, async (payload, ack) => {
    const reply = typeof ack === 'function' ? ack : () => {};
    if (tokenExpired(socket)) {
      reply(toErrorResponse(new AppError('TOKEN_EXPIRED', 'Access token expired', 401)).body);
      // Not disconnect(true): closing the transport at once could drop the ack just queued.
      socket.disconnect();
      return;
    }
    try {
      reply({ ok: true, ...(await fn(schema.parse(payload))) });
    } catch (err) {
      reply(toErrorResponse(err).body);
    }
  });
}

function registerRideHandlers(socket) {
  const { userId } = socket.data;

  on(socket, 'ride:join', joinRidePayload, async ({ rideId }) => {
    await tracking.assertCanFollow(userId, rideId);
    // Check, join, check again: a booking cancelled before the second check is refused here;
    // one cancelled after it removes this socket from the room it has already joined.
    socket.join(rideRoom(rideId));
    let ride;
    try {
      ride = await tracking.assertCanFollow(userId, rideId);
    } catch (err) {
      socket.leave(rideRoom(rideId));
      throw err;
    }
    return {
      ride: { id: ride.id, status: ride.status },
      lastLocation: await tracking.lastLocation(ride),
    };
  });

  on(socket, 'location:update', locationUpdatePayload, async (payload) => {
    const location = await tracking.recordLocation(userId, payload);
    socket.to(rideRoom(payload.rideId)).emit('driver:location', {
      rideId: payload.rideId,
      ...location,
    });
    return {};
  });
}

module.exports = { registerRideHandlers };
