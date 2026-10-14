const { Server } = require('socket.io');
const corsOrigin = require('../config/corsOrigin');
const { authenticateSocket } = require('./auth');
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
    socket.on('disconnect', (reason) => {
      hub.log(`disconnected: user ${userId}, socket ${socket.id} (${reason})`);
      hub.socketDisconnected(userId);
    });
  });
  hub.setServer(io);
  return io;
}

module.exports = { attachRealtime };
