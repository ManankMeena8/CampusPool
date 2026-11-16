const redis = require('../src/lib/redis');
const { assertTestRedis } = require('./setup');
const { waitFor } = require('./helpers/outbox');

const URL_WITH_SECRET = 'redis://default:hunter2secret@127.0.0.1:1/0';

let errSpy;
beforeEach(() => {
  errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(async () => {
  await redis.closeAll();
  jest.restoreAllMocks();
});

describe('lib/redis', () => {
  it('a producer connection fails fast; a worker connection never gives up on a command', () => {
    const producer = redis.connect(process.env.REDIS_URL);
    const worker = redis.connect(process.env.REDIS_URL, { blocking: true });
    expect(producer.options).toMatchObject({ enableOfflineQueue: false, maxRetriesPerRequest: 1 });
    // BullMQ refuses a worker connection whose maxRetriesPerRequest is not null.
    expect(worker.options).toMatchObject({ enableOfflineQueue: true, maxRetriesPerRequest: null });
  });

  it('ping answers ok on a live connection', async () => {
    const client = redis.connect(process.env.REDIS_URL);
    await waitFor(() => client.status === 'ready', 'the test Redis (npm run db:test:up)');
    expect(await redis.ping(client)).toBe('ok');
  });

  it('ping answers down, quickly, when Redis is unreachable or slow', async () => {
    const dead = redis.connect(URL_WITH_SECRET);
    const started = Date.now();
    expect(await redis.ping(dead, 200)).toBe('down');
    expect(await redis.ping({ ping: () => new Promise(() => {}) }, 50)).toBe('down');
    expect(Date.now() - started).toBeLessThan(1500);
  });

  it('logs an outage once, with the error code and never the URL', async () => {
    const dead = redis.connect(URL_WITH_SECRET, { name: 'queue' });
    // Several reconnection attempts fail (the first retries are 200 and 400 ms apart).
    let attempts = 0;
    dead.on('error', () => {
      attempts += 1;
    });
    await waitFor(() => attempts >= 2, 'two failed connection attempts');

    expect(errSpy).toHaveBeenCalledTimes(1);
    expect(errSpy.mock.calls[0][0]).toMatch(/^\[redis\] queue connection lost \(\w+\)$/);
    const logged = JSON.stringify(errSpy.mock.calls);
    expect(logged).not.toContain('hunter2secret');
    expect(logged).not.toContain('127.0.0.1');
  });

  it('closeAll ends every connection, connected or not', async () => {
    const live = redis.connect(process.env.REDIS_URL);
    const dead = redis.connect(URL_WITH_SECRET);
    await waitFor(() => live.status === 'ready', 'the test Redis');

    await redis.closeAll();

    expect(live.status).toBe('end');
    await expect(live.ping()).rejects.toThrow();
    // No further reconnection attempts.
    let attempts = 0;
    dead.on('error', () => {
      attempts += 1;
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    expect(attempts).toBe(0);
  });
});

describe('the test guard', () => {
  const saved = { ...process.env };
  afterEach(() => {
    process.env.REDIS_URL = saved.REDIS_URL;
    if (saved.ALLOW_REMOTE_TEST_DB === undefined) delete process.env.ALLOW_REMOTE_TEST_DB;
    else process.env.ALLOW_REMOTE_TEST_DB = saved.ALLOW_REMOTE_TEST_DB;
  });

  const guardWith = (url, allowRemote) => {
    if (url === undefined) delete process.env.REDIS_URL;
    else process.env.REDIS_URL = url;
    if (allowRemote) process.env.ALLOW_REMOTE_TEST_DB = '1';
    else delete process.env.ALLOW_REMOTE_TEST_DB;
    return () => assertTestRedis(undefined);
  };

  it('accepts the local test Redis', () => {
    expect(guardWith('redis://localhost:6380/0')).not.toThrow();
    expect(guardWith('redis://127.0.0.1:6380')).not.toThrow();
  });

  it.each([
    ['is not set', undefined, /REDIS_URL is not set/],
    ['is not a URL', 'localhost', /not a valid URL|not a redis/],
    ['is not a Redis URL', 'https://localhost:6380', /not a redis:\/\/ URL/],
    ['is remote', 'rediss://default:hunter2secret@red-abc.example.com:6379', /REDIS_URL is remote/],
  ])('refuses to run when REDIS_URL %s', (_label, url, pattern) => {
    expect(guardWith(url)).toThrow(pattern);
    let message = '';
    try {
      guardWith(url)();
    } catch (err) {
      message = err.message;
    }
    expect(message).not.toContain('hunter2secret');
  });

  it('refuses the Redis database that npm run dev uses, whatever the credentials', () => {
    const dev = 'redis://localhost:6380/1';
    guardWith('redis://:pw@LOCALHOST:6380/1');
    expect(() => assertTestRedis(dev)).toThrow(/is the dev REDIS_URL/);
    // Another database of the same server is fine: tests use db 0, dev db 1.
    guardWith('redis://localhost:6380/0');
    expect(() => assertTestRedis(dev)).not.toThrow();
    expect(() => assertTestRedis('redis://localhost:6380')).toThrow(/is the dev REDIS_URL/);
  });

  it('accepts a remote Redis only with ALLOW_REMOTE_TEST_DB=1', () => {
    expect(guardWith('rediss://red-abc.example.com:6379', true)).not.toThrow();
  });
});
