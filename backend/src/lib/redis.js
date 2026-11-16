const Redis = require('ioredis');

/*
 * Every Redis connection the API opens is made here, so they share their settings and can all be
 * closed on shutdown. The URL carries the password: it is never logged, and neither are error
 * messages (they can quote the host), only error codes.
 */

const open = new Set();
const closing = new WeakSet();
// How long close() waits for a connection to end before leaving it to the process exit.
const CLOSE_TIMEOUT_MS = 2000;

function log(message) {
  if (process.env.NODE_ENV !== 'test') console.log(`[redis] ${message}`);
}

/**
 * Opens a connection to `url`.
 *
 * `blocking: true` is for BullMQ workers, which wait on blocking commands: BullMQ requires
 * maxRetriesPerRequest null there, and commands queue while Redis is away.
 *
 * Otherwise the connection is for producers (the queue the relay adds to, the health check):
 * commands fail at once while Redis is away instead of queueing, so the relay's transaction is
 * never left waiting on Redis.
 */
function connect(url, { blocking = false, name = blocking ? 'worker' : 'queue' } = {}) {
  const client = new Redis(url, {
    connectionName: `campuspool-${name}`,
    maxRetriesPerRequest: blocking ? null : 1,
    enableOfflineQueue: blocking,
    // Reconnect for ever, at most every 2 s.
    retryStrategy: (times) => Math.min(times * 200, 2000),
  });

  // One line per outage, not one per reconnection attempt.
  let down = false;
  client.on('error', (err) => {
    // A socket error while we are closing the connection ourselves is not an outage.
    if (down || closing.has(client)) return;
    down = true;
    console.error(`[redis] ${name} connection lost (${err.code ?? err.name})`);
  });
  client.on('ready', () => {
    if (down) log(`${name} connection restored`);
    down = false;
  });
  client.on('end', () => open.delete(client));

  open.add(client);
  return client;
}

/** 'ok' when `client` answers a PING within `timeoutMs`, else 'down'. Never throws. */
async function ping(client, timeoutMs = 1000) {
  let timer;
  try {
    const timeout = new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('timeout')), timeoutMs);
    });
    return (await Promise.race([client.ping(), timeout])) === 'PONG' ? 'ok' : 'down';
  } catch {
    return 'down';
  } finally {
    clearTimeout(timer);
  }
}

/** Closes one connection: QUIT when it is up (pending replies arrive first), else just drop it. */
async function close(client) {
  if (client.status === 'end') return;
  closing.add(client);
  open.delete(client);
  // Between reconnection attempts there is no socket: disconnect() only cancels the next
  // attempt, and ioredis emits no 'end' to wait for.
  if (client.status === 'reconnecting') {
    client.disconnect();
    return;
  }
  let timer;
  const ended = new Promise((resolve) => {
    client.once('end', resolve);
    timer = setTimeout(resolve, CLOSE_TIMEOUT_MS);
  });
  try {
    if (client.status === 'ready') await client.quit();
    else client.disconnect();
  } catch {
    client.disconnect();
  }
  // Until 'end', ioredis still holds the socket and a timer.
  await ended;
  clearTimeout(timer);
}

/** Closes every connection opened through connect(). */
async function closeAll() {
  await Promise.all([...open].map(close));
}

module.exports = { connect, ping, close, closeAll };
