const http = require('http');
const jwt = require('jsonwebtoken');
const { io: ioClient } = require('socket.io-client');
const { app } = require('./auth');
const { attachRealtime } = require('../../src/realtime');

/**
 * Starts the app with Socket.io on a random local port. `connect(token)` resolves to a connected
 * client, or rejects with the server's connect_error. Call `disconnectAll` after each test and
 * `close` after the file.
 */
async function startRealtimeServer() {
  const server = http.createServer(app);
  const io = attachRealtime(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  const clients = [];

  function connect(token) {
    const socket = ioClient(url, {
      auth: token === undefined ? {} : { token },
      transports: ['websocket'],
      reconnection: false,
      forceNew: true,
    });
    clients.push(socket);
    return new Promise((resolve, reject) => {
      socket.once('connect', () => resolve(socket));
      socket.once('connect_error', reject);
    });
  }

  function disconnectAll() {
    for (const socket of clients.splice(0)) socket.disconnect();
  }

  function close() {
    disconnectAll();
    return new Promise((resolve) => io.close(() => resolve()));
  }

  return { io, connect, disconnectAll, close };
}

/** Resolves to the next `event` payload, or rejects after `ms`. */
function nextEvent(socket, event, ms = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.off(event, onEvent);
      reject(new Error(`No ${event} within ${ms} ms`));
    }, ms);
    function onEvent(payload) {
      clearTimeout(timer);
      resolve(payload);
    }
    socket.once(event, onEvent);
  });
}

/** Collects every `event` payload the socket receives from now on. */
function record(socket, event) {
  const received = [];
  socket.on(event, (payload) => received.push(payload));
  return received;
}

/** Emits and resolves to the server's acknowledgement. */
const ask = (socket, event, payload) => socket.timeout(2000).emitWithAck(event, payload);

/** Gives in-flight broadcasts time to arrive, before asserting that none did. */
const settle = (ms = 200) => new Promise((resolve) => setTimeout(resolve, ms));

/** Polls `check` until it is true, or throws after `ms`. */
async function waitFor(check, ms = 2000) {
  const deadline = Date.now() + ms;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error('Condition not met in time');
    await settle(20);
  }
}

/**
 * An access token for `user` expiring at `exp` (seconds since the epoch; default: a minute ago).
 * Socket tests cannot fake the clock past a token's 15 minutes instead: engine.io-client checks
 * Date.now() against its ping deadline and would drop the connection.
 */
const tokenExpiringAt = (user, exp = Math.floor(Date.now() / 1000) - 60) =>
  jwt.sign({ sub: user.id, role: user.role, exp }, process.env.JWT_ACCESS_SECRET, {
    algorithm: 'HS256',
  });

module.exports = { startRealtimeServer, nextEvent, record, ask, settle, waitFor, tokenExpiringAt };
