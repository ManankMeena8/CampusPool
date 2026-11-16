const { randomUUID } = require('crypto');
const request = require('supertest');
const redis = require('../src/lib/redis');
const outbox = require('../src/services/outbox.service');
const { createNotifications } = require('../src/services/notification.service');
const { createNotificationQueue } = require('../src/jobs/queue');
const { createRelay } = require('../src/jobs/relay');
const { createNotificationWorker } = require('../src/jobs/notificationWorker');
const { createShutdown } = require('../src/lib/shutdown');
const { app, prisma, resetDb } = require('./helpers/auth');
const { bearer, createUser, insertRide } = require('./helpers/rides');
const { requestBooking, act, insertBooking } = require('./helpers/bookings');
const {
  insertOutbox,
  connectRedis,
  waitFor,
  fcmError,
  fakeMessaging,
  withToken,
  tokenOf,
} = require('./helpers/outbox');

/*
 * The outbox relay and the notification worker against the real Redis from Docker, with a fake
 * FCM client. Nothing here starts with the app (ENABLE_JOBS=0 in tests): each test builds the
 * pieces it needs and afterEach closes them.
 */

// Retries a few milliseconds apart instead of seconds.
const FAST_RETRIES = { attempts: 4, backoff: { type: 'fixed', delay: 15 } };

let admin; // FLUSHDB and direct checks
let producer;
let queue;
let toClose;
let errSpy;

beforeAll(() => {
  admin = connectRedis({ name: 'test-admin' });
});

beforeEach(async () => {
  await resetDb();
  await waitFor(() => admin.status === 'ready', 'the test Redis (npm run db:test:up)');
  await admin.flushdb();
  toClose = [];
  producer = connectRedis();
  queue = createNotificationQueue(producer, { jobOptions: FAST_RETRIES });
  errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  jest.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  outbox.onNudge(null);
  for (const thing of toClose.reverse()) await thing.stop?.();
  for (const thing of toClose) await thing.close?.();
  await queue.close();
  await redis.close(producer);
  jest.restoreAllMocks();
});

afterAll(async () => {
  await redis.closeAll();
  await prisma.$disconnect();
});

function startWorker(messaging, options = {}) {
  const { deliver } = createNotifications({ getMessaging: () => messaging, db: prisma });
  const worker = createNotificationWorker({
    connection: connectRedis({ blocking: true }),
    db: prisma,
    deliver,
    ...options,
  });
  toClose.push(worker);
  return worker;
}

function makeRelay(options = {}) {
  const relay = createRelay({ db: prisma, queue, intervalMs: 25, ...options });
  toClose.push(relay);
  return relay;
}

const row = (id) => prisma.outbox.findUniqueOrThrow({ where: { id } });
const finished = (id) => async () => {
  const r = await row(id);
  return ['SENT', 'SKIPPED', 'FAILED'].includes(r.status) && r;
};
/** Long enough for a job that should not exist to have run. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 300));

/** A started ride whose rider has a token, and a ride.started outbox row for them. */
async function startedRide() {
  const driver = await createUser('dev');
  const rider = await createUser('rider', 'RIDER');
  const rideId = await insertRide(driver.user.id, { status: 'IN_PROGRESS' });
  await withToken(rider, 'rider-token');
  const pending = await insertOutbox('ride.started', rider.user.id, { rideId });
  return { driver, rider, rideId, id: pending.id };
}

describe('happy path', () => {
  it('row -> job -> FCM called once -> SENT', async () => {
    const { id, rideId } = await startedRide();
    const messaging = fakeMessaging();
    startWorker(messaging);
    const before = Date.now();

    expect(await makeRelay().tick()).toBe(1);
    const enqueued = await row(id);
    expect(['ENQUEUED', 'SENT']).toContain(enqueued.status);
    expect(enqueued.enqueuedAt.getTime()).toBeGreaterThanOrEqual(before - 1000);

    const sent = await waitFor(finished(id), 'the row to be finished');
    expect(sent).toMatchObject({ status: 'SENT', attempts: 1, lastError: null });
    expect(sent.processedAt.getTime()).toBeGreaterThanOrEqual(before - 1000);
    expect(messaging.send).toHaveBeenCalledTimes(1);
    expect(messaging.send.mock.calls[0][0]).toMatchObject({
      token: 'rider-token',
      data: { type: 'ride.started', rideId, outboxId: id },
      android: { notification: { tag: id } },
    });
    // The job's id is the outbox id: that is what makes a second enqueue a no-op.
    expect(await queue.getJob(id)).toBeDefined();
  });

  it('a request is sent through the started relay and the nudge, end to end', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const rideId = await insertRide(driver.user.id);
    await withToken(driver, 'driver-token');
    const messaging = fakeMessaging();
    startWorker(messaging);
    // An interval far longer than the test: only the nudge after the commit can run the relay.
    const relay = makeRelay({ intervalMs: 60000 });
    relay.start();
    outbox.onNudge(relay.nudge);

    const res = await requestBooking(rider.token, rideId).expect(201);

    const pending = await prisma.outbox.findFirstOrThrow();
    await waitFor(finished(pending.id), 'the request notification');
    expect(messaging.send).toHaveBeenCalledTimes(1);
    expect(messaging.send.mock.calls[0][0]).toMatchObject({
      token: 'driver-token',
      notification: { title: 'New ride request' },
      data: { type: 'booking.requested', rideId, bookingId: res.body.booking.id },
    });
  });

  it('sends each recipient their own message, five at a time', async () => {
    const driver = await createUser('dev');
    const rideId = await insertRide(driver.user.id, { status: 'IN_PROGRESS' });
    const ids = [];
    for (let i = 0; i < 12; i += 1) {
      const rider = await createUser(`rider${i}`, 'RIDER');
      await withToken(rider, `token-${i}`);
      ids.push((await insertOutbox('ride.started', rider.user.id, { rideId })).id);
    }
    let active = 0;
    let peak = 0;
    const messaging = fakeMessaging(async () => {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 40));
      active -= 1;
    });
    startWorker(messaging);

    expect(await makeRelay().tick()).toBe(12);
    await waitFor(
      async () => (await prisma.outbox.count({ where: { status: 'SENT' } })) === 12,
      'all 12 rows to be SENT',
    );
    const tokens = messaging.send.mock.calls.map(([m]) => m.token).sort();
    expect(tokens).toEqual(ids.map((_id, i) => `token-${i}`).sort());
    expect(peak).toBeGreaterThan(1);
    expect(peak).toBeLessThanOrEqual(5);
  });
});

describe('failures', () => {
  it('a temporary failure twice, then success: SENT with 3 attempts', async () => {
    const { id, rider } = await startedRide();
    const messaging = fakeMessaging((_message, call) => {
      if (call <= 2) throw fcmError('messaging/server-unavailable');
    });
    startWorker(messaging);

    await makeRelay().tick();

    const sent = await waitFor(finished(id), 'the row to be finished');
    expect(sent).toMatchObject({ status: 'SENT', attempts: 3 });
    expect(messaging.send).toHaveBeenCalledTimes(3);
    expect(await tokenOf(rider)).toBe('rider-token');
  });

  it('records the last error code, never the message, while retrying', async () => {
    const { id } = await startedRide();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const messaging = fakeMessaging(async (_message, call) => {
      if (call === 1) throw fcmError('messaging/internal-error');
      await gate;
    });
    startWorker(messaging);
    await makeRelay().tick();

    // The second attempt is in flight: the first one's error is on the row.
    await waitFor(() => messaging.send.mock.calls.length === 2, 'the second attempt');
    expect(await row(id)).toMatchObject({
      status: 'ENQUEUED',
      attempts: 2,
      lastError: 'messaging/internal-error',
    });
    const job = await queue.getJob(id);
    expect(job.failedReason ?? '').not.toContain('SECRET');
    release();
    expect(await waitFor(finished(id), 'the row to be finished')).toMatchObject({
      status: 'SENT',
      lastError: null,
    });
  });

  it('a permanent failure: no retry, token cleared, SKIPPED', async () => {
    const { id, rider } = await startedRide();
    const messaging = fakeMessaging(() => {
      throw fcmError('messaging/registration-token-not-registered');
    });
    startWorker(messaging);

    await makeRelay().tick();

    const skipped = await waitFor(finished(id), 'the row to be finished');
    expect(skipped).toMatchObject({
      status: 'SKIPPED',
      attempts: 1,
      lastError: 'messaging/registration-token-not-registered',
    });
    expect(skipped.processedAt).not.toBeNull();
    expect(await tokenOf(rider)).toBeNull();
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
    // In BullMQ's failed set, not waiting for a retry.
    expect(await (await queue.getJob(id)).getState()).toBe('failed');
  });

  it('invalid-argument: no retry, SKIPPED, token kept', async () => {
    const { id, rider } = await startedRide();
    const messaging = fakeMessaging(() => {
      throw fcmError('messaging/invalid-argument');
    });
    startWorker(messaging);

    await makeRelay().tick();

    expect(await waitFor(finished(id), 'the row to be finished')).toMatchObject({
      status: 'SKIPPED',
      lastError: 'messaging/invalid-argument',
    });
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
    expect(await tokenOf(rider)).toBe('rider-token');
  });

  it('every attempt fails: FAILED with the error code, the job in the failed set', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging(() => {
      throw fcmError('messaging/server-unavailable');
    });
    startWorker(messaging);

    await makeRelay().tick();

    const failed = await waitFor(finished(id), 'the row to be finished');
    expect(failed).toMatchObject({
      status: 'FAILED',
      attempts: FAST_RETRIES.attempts,
      lastError: 'messaging/server-unavailable',
    });
    expect(failed.processedAt).not.toBeNull();
    await waitFor(
      async () => (await (await queue.getJob(id)).getState()) === 'failed',
      'the job to reach the failed set',
    );
    expect(messaging.send).toHaveBeenCalledTimes(FAST_RETRIES.attempts);
    const job = await queue.getJob(id);
    expect(`${job.failedReason} ${JSON.stringify(job.stacktrace)}`).not.toContain('SECRET');
    // A relay that runs again leaves a finished row alone.
    expect(await makeRelay({ recoverAfterMs: 0 }).tick()).toBe(0);
  });

  it('a database error reaches BullMQ as its code only, and is retried', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging();
    // The worker's own queries fail the way Prisma fails: a message quoting the call and host.
    const dbError = Object.assign(
      new Error("Can't reach database server at `SECRET-HOST.neon.tech:5432`"),
      { name: 'PrismaClientKnownRequestError', code: 'P1001' },
    );
    const brokenDb = {
      outbox: { findUnique: jest.fn().mockRejectedValue(dbError), updateMany: jest.fn() },
    };
    startWorker(messaging, { db: brokenDb });

    await makeRelay().tick();

    await waitFor(
      async () => (await (await queue.getJob(id)).getState()) === 'failed',
      'the job to run out of attempts',
    );
    expect(brokenDb.outbox.findUnique).toHaveBeenCalledTimes(FAST_RETRIES.attempts);
    const job = await queue.getJob(id);
    expect(job.failedReason).toBe('P1001');
    expect(JSON.stringify(job.stacktrace)).not.toContain('SECRET');
    expect(messaging.send).not.toHaveBeenCalled();
    // The outcome could not be written: the row is left for recovery and outbox:status.
    expect((await row(id)).status).toBe('ENQUEUED');
  });
});

describe('nothing is sent twice', () => {
  it('relay "crash": the job was added but the row never marked', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging();
    // What a relay that died between addBulk and its commit leaves behind.
    await queue.add('send', {}, { jobId: id });
    expect((await row(id)).status).toBe('PENDING');

    // The relay runs again: BullMQ ignores the id it already has.
    expect(await makeRelay().tick()).toBe(1);
    expect(await queue.getJobCountByTypes('waiting', 'active', 'delayed')).toBe(1);

    startWorker(messaging);
    expect((await waitFor(finished(id), 'the row to be finished')).status).toBe('SENT');
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
  });

  it('relay "crash", and the worker gets there first: the PENDING row is sent, then left alone', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging();
    await queue.add('send', {}, { jobId: id });
    startWorker(messaging);

    expect((await waitFor(finished(id), 'the row to be finished')).status).toBe('SENT');

    // Nothing left for the relay to do, even when asked to recover at once.
    expect(await makeRelay({ recoverAfterMs: 0 }).tick()).toBe(0);
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
    expect((await row(id)).status).toBe('SENT');
  });

  it('two relays at once: each row is enqueued once', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const rideId = await insertRide(driver.user.id, { status: 'IN_PROGRESS' });
    await prisma.outbox.createMany({
      data: Array.from({ length: 250 }, () => ({
        type: 'ride.started',
        recipientUserId: rider.user.id,
        payload: { rideId },
      })),
    });
    const added = [];
    const addBulk = queue.addBulk.bind(queue);
    jest.spyOn(queue, 'addBulk').mockImplementation(async (jobs) => {
      added.push(...jobs.map((j) => j.opts.jobId));
      // Hold the batch's row locks long enough for the other relay to run into them.
      await new Promise((resolve) => setTimeout(resolve, 30));
      return addBulk(jobs);
    });
    const [a, b] = [makeRelay(), makeRelay()];

    const drain = async (relay) => {
      const counts = [];
      for (;;) {
        const n = await relay.tick();
        if (n === 0) return counts;
        counts.push(n);
      }
    };
    const [fromA, fromB] = await Promise.all([drain(a), drain(b)]);

    // Both took part, and between them every row was handed over exactly once.
    expect(fromA.length).toBeGreaterThan(0);
    expect(fromB.length).toBeGreaterThan(0);
    expect(added).toHaveLength(250);
    expect(new Set(added).size).toBe(250);
    expect(await prisma.outbox.count({ where: { status: 'ENQUEUED' } })).toBe(250);
    expect(await queue.getJobCountByTypes('waiting')).toBe(250);
  });

  it('Redis flushed while rows are ENQUEUED: recovery re-enqueues, sent once', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging();
    const relay = makeRelay();
    await relay.tick();
    expect((await row(id)).status).toBe('ENQUEUED');

    await admin.flushdb(); // a Redis restart without persistence: the job is gone
    expect(await queue.getJob(id)).toBeUndefined();

    // Not yet 5 minutes old: left alone.
    expect(await relay.tick()).toBe(0);
    await prisma.outbox.update({
      where: { id },
      data: { enqueuedAt: new Date(Date.now() - 6 * 60 * 1000) },
    });
    expect(await relay.tick()).toBe(1);
    // Marked again, so the next ticks do not keep re-adding it.
    expect(await relay.tick()).toBe(0);

    startWorker(messaging);
    expect((await waitFor(finished(id), 'the row to be finished')).status).toBe('SENT');
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
  });

  it('recovery while the job still exists adds nothing', async () => {
    const { id } = await startedRide();
    const messaging = fakeMessaging();
    const relay = makeRelay({ recoverAfterMs: 0 });
    await relay.tick();
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(await relay.tick()).toBe(1); // "recovered", but the id is already there
    expect(await queue.getJobCountByTypes('waiting')).toBe(1);

    startWorker(messaging);
    await waitFor(finished(id), 'the row to be finished');
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
  });

  it('a job for a row that is already finished, or gone, does nothing', async () => {
    const { id, rider, rideId } = await startedRide();
    await prisma.outbox.update({ where: { id }, data: { status: 'SENT' } });
    const failedRow = await insertOutbox(
      'ride.started',
      rider.user.id,
      { rideId },
      { status: 'FAILED' },
    );
    const messaging = fakeMessaging();
    startWorker(messaging);

    const jobs = await Promise.all(
      [id, failedRow.id, randomUUID()].map((jobId) => queue.add('send', {}, { jobId })),
    );
    await waitFor(
      async () => (await queue.getJobCountByTypes('completed')) === jobs.length,
      'the jobs to complete',
    );
    expect(messaging.send).not.toHaveBeenCalled();
    expect((await row(id)).attempts).toBe(0);
    expect((await row(failedRow.id)).status).toBe('FAILED');
  });
});

describe('the event is checked again before sending', () => {
  it('booking cancelled before the send: SKIPPED, nothing sent', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const rideId = await insertRide(driver.user.id);
    await withToken(rider, 'rider-token');
    await withToken(driver, 'driver-token');
    const bookingId = await insertBooking(rideId, rider.user.id);
    await act(driver.token, bookingId, 'accept').expect(200);
    // Before any relay ran, the rider cancels.
    await act(rider.token, bookingId, 'cancel').expect(200);
    const messaging = fakeMessaging();
    startWorker(messaging);

    expect(await makeRelay().tick()).toBe(2);

    const accepted = await prisma.outbox.findFirstOrThrow({ where: { type: 'booking.accepted' } });
    const cancelled = await prisma.outbox.findFirstOrThrow({
      where: { type: 'booking.cancelled' },
    });
    expect(await waitFor(finished(accepted.id), 'the accepted row')).toMatchObject({
      status: 'SKIPPED',
      lastError: 'stale',
    });
    expect((await waitFor(finished(cancelled.id), 'the cancelled row')).status).toBe('SENT');
    // Only the driver hears about the cancel; the rider is never told "accepted".
    expect(messaging.send.mock.calls.map(([m]) => [m.token, m.data.type])).toEqual([
      ['driver-token', 'booking.cancelled'],
    ]);
  });

  it('a recipient without a token: SKIPPED', async () => {
    const { id, rider } = await startedRide();
    await prisma.user.update({ where: { id: rider.user.id }, data: { fcmToken: null } });
    const messaging = fakeMessaging();
    startWorker(messaging);

    await makeRelay().tick();

    expect(await waitFor(finished(id), 'the row to be finished')).toMatchObject({
      status: 'SKIPPED',
      lastError: 'no-token',
      attempts: 1,
    });
    expect(messaging.send).not.toHaveBeenCalled();
  });
});

describe('when Redis is down', () => {
  it('the request still succeeds; rows stay PENDING and are sent once Redis is back', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const rideId = await insertRide(driver.user.id);
    await withToken(driver, 'driver-token');
    // A queue whose Redis refuses connections (nothing listens on port 1).
    const deadConnection = redis.connect('redis://127.0.0.1:1');
    const deadQueue = createNotificationQueue(deadConnection);
    const downRelay = createRelay({
      db: prisma,
      queue: deadQueue,
      intervalMs: 20,
      addTimeoutMs: 300,
    });
    outbox.onNudge(downRelay.nudge);
    downRelay.start();

    try {
      const started = Date.now();
      await requestBooking(rider.token, rideId).expect(201);
      // The request did not wait for Redis.
      expect(Date.now() - started).toBeLessThan(2000);

      // The relay fails in the background and says so, once and without the URL...
      const relayLogs = () => errSpy.mock.calls.filter(([m]) => /\[relay\]/.test(m));
      await waitFor(() => relayLogs().length > 0, 'the relay log');
      // ...while the API keeps working, over many more failed ticks.
      await request(app).get('/rides/mine').set(bearer(driver.token)).expect(200);
      await settle();
      expect(relayLogs()).toHaveLength(1);
      expect(relayLogs()[0][0]).toMatch(/could not enqueue notifications \(\w+\)/);
      expect(errSpy.mock.calls.flat().join(' ')).not.toContain('127.0.0.1');
      const pending = await prisma.outbox.findFirstOrThrow();
      expect(pending).toMatchObject({ status: 'PENDING', enqueuedAt: null, attempts: 0 });
    } finally {
      outbox.onNudge(null);
      await downRelay.stop();
      await deadQueue.close().catch(() => {});
      await redis.close(deadConnection);
    }

    // Redis is back: a relay on the real queue picks the row up.
    const messaging = fakeMessaging();
    startWorker(messaging);
    expect(await makeRelay().tick()).toBe(1);
    const pending = await prisma.outbox.findFirstOrThrow();
    expect((await waitFor(finished(pending.id), 'the row to be finished')).status).toBe('SENT');
    await settle();
    expect(messaging.send).toHaveBeenCalledTimes(1);
  });
});

describe('shutdown', () => {
  it('lets the send in flight finish, then closes the worker, the queue and Redis', async () => {
    const { id } = await startedRide();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const messaging = fakeMessaging(() => gate);
    const worker = startWorker(messaging);
    const relay = makeRelay();
    relay.start();
    await waitFor(() => messaging.send.mock.calls.length === 1, 'the send to start');

    const exit = jest.fn();
    const done = new Promise((resolve) => exit.mockImplementation(resolve));
    const io = { close: (callback) => callback() };
    createShutdown({ io, prisma: { $disconnect: async () => {} }, relay, worker, queue, exit })(
      'SIGTERM',
    );
    await settle();
    // Still waiting for the job.
    expect(exit).not.toHaveBeenCalled();
    release();

    expect(await done).toBe(0);
    expect(await row(id)).toMatchObject({ status: 'SENT', attempts: 1 });
    expect(worker.isRunning()).toBe(false);
  });
});

describe('startJobs', () => {
  it('does nothing when ENABLE_JOBS is off', () => {
    const { startJobs, redisHealth } = require('../src/jobs');
    expect(startJobs({ ENABLE_JOBS: false })).toBeNull();
    return expect(redisHealth()).resolves.toBe('disabled');
  });

  it('starts a relay and a worker that send, registers the nudge, and reports Redis', async () => {
    const { id } = await startedRide();
    const notifications = require('../src/services/notification.service');
    const messaging = fakeMessaging();
    const real = createNotifications({ getMessaging: () => messaging, db: prisma });
    jest.spyOn(notifications, 'deliver').mockImplementation(real.deliver);
    const { startJobs, redisHealth } = require('../src/jobs');

    const jobs = startJobs({ ENABLE_JOBS: true, REDIS_URL: process.env.REDIS_URL });
    toClose.push(jobs.relay, jobs.worker, jobs.queue);

    expect((await waitFor(finished(id), 'the row to be finished')).status).toBe('SENT');
    expect(await redisHealth()).toBe('ok');
    // The nudge reaches this relay: a new row goes out without waiting for a tick.
    await jobs.relay.stop();
    const second = await insertOutbox('ride.started', (await row(id)).recipientUserId, {
      rideId: (await row(id)).payload.rideId,
    });
    outbox.nudge();
    expect((await waitFor(finished(second.id), 'the nudged row')).status).toBe('SENT');
  });
});

describe('the relay', () => {
  it('takes at most one batch per tick, oldest first, and drains a burst when started', async () => {
    const driver = await createUser('dev');
    const rider = await createUser('rider', 'RIDER');
    const rideId = await insertRide(driver.user.id, { status: 'IN_PROGRESS' });
    const t0 = Date.now() - 60000;
    await prisma.outbox.createMany({
      data: Array.from({ length: 25 }, (_v, i) => ({
        type: 'ride.started',
        recipientUserId: rider.user.id,
        payload: { rideId },
        createdAt: new Date(t0 + i * 1000),
      })),
    });
    const relay = makeRelay({ batchSize: 10, intervalMs: 60000 });

    expect(await relay.tick()).toBe(10);
    const oldest = await prisma.outbox.findMany({ orderBy: { createdAt: 'asc' }, take: 10 });
    expect(oldest.every((r) => r.status === 'ENQUEUED')).toBe(true);
    expect(await prisma.outbox.count({ where: { status: 'PENDING' } })).toBe(15);

    // One run keeps going while batches come back full: no waiting for the next interval.
    relay.start();
    await waitFor(
      async () => (await prisma.outbox.count({ where: { status: 'PENDING' } })) === 0,
      'the burst to drain',
    );
    await relay.stop();
  });

  it('stop() waits for the tick in flight and stops the timer', async () => {
    await startedRide();
    const addBulk = queue.addBulk.bind(queue);
    let adding = false;
    jest.spyOn(queue, 'addBulk').mockImplementation(async (jobs) => {
      adding = true;
      await new Promise((resolve) => setTimeout(resolve, 100));
      const result = await addBulk(jobs);
      adding = false;
      return result;
    });
    const relay = makeRelay({ intervalMs: 10 });
    relay.start();
    await waitFor(() => adding, 'the tick to reach Redis');

    await relay.stop();

    expect(adding).toBe(false);
    expect(await prisma.outbox.count({ where: { status: 'ENQUEUED' } })).toBe(1);
    const calls = queue.addBulk.mock.calls.length;
    await insertOutbox('ride.started', (await prisma.user.findFirstOrThrow()).id, {});
    await settle();
    expect(queue.addBulk.mock.calls.length).toBe(calls);
  });
});
