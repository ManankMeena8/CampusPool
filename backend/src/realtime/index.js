const { Server } = require('socket.io');
const corsOrigin = require('../config/corsOrigin');
const { authenticateSocket, msUntilTokenExpires } = require('./auth');
const { registerRideHandlers } = require('./ride.handlers');
const hub = require('./hub');

/** Attaches Socket.io to `httpServer`. Logs user and socket ids only, never the handshake. */
function attachRealtime(httpServer) {
  const io = new Server(httpServer, { cors: { origin: corsOrigin } });
  io.use(authenticateSocket);
  io.on('connection', (socket) => {
    const { userId } = socket.data;
    socket.join(hub.userRoom(userId));
    hub.log(`connected: user ${userId}, socket ${socket.id}`);
    registerRideHandlers(socket);
    // A socket outlives its token, and a rider's sends nothing after joining: disconnect it when
    // the token expires, so the client reconnects with a fresh one. Events in between are refused
    // by the handlers' own expiry check.
    const expiry = setTimeout(() => socket.disconnect(), msUntilTokenExpires(socket));
    socket.on('disconnect', (reason) => {
      clearTimeout(expiry);
      hub.log(`disconnected: user ${userId}, socket ${socket.id} (${reason})`);
      hub.socketDisconnected(userId);
    });
  });
  hub.setServer(io);
  return io;
}

module.exports = { attachRealtime };
