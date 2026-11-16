const { prisma } = require('./auth');
const redis = require('../../src/lib/redis');

/** Every outbox row as { type, to, payload, status }, in a stable order. */
async function outboxRows() {
  const rows = await prisma.outbox.findMany();
  return rows
    .map((r) => ({ type: r.type, to: r.recipientUserId, payload: r.payload, status: r.status }))
    .sort((a, b) => `${a.type} ${a.to}`.localeCompare(`${b.type} ${b.to}`));
}

/** Inserts an outbox row directly, as a committed transaction would have. */
function insertOutbox(type, recipientUserId, payload, overrides = {}) {
  return prisma.outbox.create({ data: { type, recipientUserId, payload, ...overrides } });
}

/** A connection to the test Redis (db 0 of the Docker container). */
const connectRedis = (options) => redis.connect(process.env.REDIS_URL, options);

/** Polls `check` until it returns something truthy; throws `what` after `timeoutMs`. */
async function waitFor(check, what = 'condition', timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

/** An error as firebase-admin throws it: the message may quote the token, the code is safe. */
const fcmError = (code) =>
  Object.assign(new Error(`FCM refused token SECRET-TOKEN-TEXT (${code})`), { code });

/**
 * A fake FCM client. `send` succeeds unless `behave(message, callNumber)` throws (or rejects).
 */
function fakeMessaging(behave = () => {}) {
  let calls = 0;
  return {
    send: jest.fn(async (message) => {
      calls += 1;
      await behave(message, calls);
      return 'projects/test/messages/1';
    }),
  };
}

const withToken = (user, fcmToken) =>
  prisma.user.update({ where: { id: user.user.id }, data: { fcmToken } });

const tokenOf = async (user) =>
  (await prisma.user.findUniqueOrThrow({ where: { id: user.user.id } })).fcmToken;

module.exports = {
  outboxRows,
  insertOutbox,
  connectRedis,
  waitFor,
  fcmError,
  fakeMessaging,
  withToken,
  tokenOf,
};
