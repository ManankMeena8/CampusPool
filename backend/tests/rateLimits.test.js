const request = require('supertest');
const { app, prisma, resetDb, emailFor, createVerifiedUser, PASSWORD } = require('./helpers/auth');
const { LIMITS, resetRateLimits } = require('../src/middleware/rateLimits');

beforeEach(async () => {
  process.env.RATE_LIMIT_IN_TESTS = '1';
  await resetDb();
  await resetRateLimits();
});
afterAll(async () => {
  delete process.env.RATE_LIMIT_IN_TESTS;
  await prisma.$disconnect();
});

const login = (body) => request(app).post('/auth/login').send(body);
const wrong = (email) => login({ email, password: 'Wrong-pass-1' });

async function times(n, send, expectedStatus) {
  for (let i = 0; i < n; i++) await send().expect(expectedStatus);
}

function expectRateLimited(res) {
  expect(res.status).toBe(429);
  expect(res.body).toEqual({ error: { code: 'RATE_LIMITED', message: expect.any(String) } });
  expect(Number(res.headers['retry-after'])).toBeGreaterThan(0);
}

describe('login limiter (IP + email)', () => {
  it('returns 429 after too many failed attempts, even with the right password', async () => {
    const email = emailFor('ana');
    await createVerifiedUser(email);
    await times(LIMITS.login, () => wrong(email), 401);

    expectRateLimited(await wrong(email));
    expectRateLimited(await login({ email, password: PASSWORD }));
  });

  it('counts the email in any case and with spaces as the same email', async () => {
    const email = emailFor('ana');
    await times(LIMITS.login, () => wrong(email), 401);
    expectRateLimited(await wrong(`  ${email.toUpperCase()} `));
  });

  it('still lets the same IP try another email', async () => {
    await times(LIMITS.login, () => wrong(emailFor('ana')), 401);
    await wrong(emailFor('ben')).expect(401);
  });

  it('does not count successful logins', async () => {
    const email = emailFor('ana');
    await createVerifiedUser(email);
    await times(LIMITS.login + 5, () => login({ email, password: PASSWORD }), 200);
    await wrong(email).expect(401);
  });

  it('counts requests that fail validation', async () => {
    const email = emailFor('ana');
    await times(LIMITS.login, () => login({ email }), 400);
    expectRateLimited(await wrong(email));
  });
});

describe('auth limiter (IP)', () => {
  const signup = () => request(app).post('/auth/signup').send({});

  it('returns 429 once the IP has made too many /auth requests', async () => {
    await times(LIMITS.auth, signup, 400);
    expectRateLimited(await signup());
    expectRateLimited(await request(app).post('/auth/logout').send({ refreshToken: 'x' }));
    expectRateLimited(await wrong(emailFor('ana')));
  });

  it('does not apply to /auth/refresh', async () => {
    await times(LIMITS.auth, signup, 400);
    await request(app).post('/auth/refresh').send({ refreshToken: 'unknown' }).expect(401);
  });

  it('does not apply outside /auth', async () => {
    await times(LIMITS.auth, signup, 400);
    await request(app).get('/users/me').expect(401);
  });
});

describe('refresh limiter (IP)', () => {
  it('allows far more requests than the auth limiter, then returns 429', async () => {
    const refresh = () => request(app).post('/auth/refresh').send({});
    await times(LIMITS.refresh, refresh, 400);
    expectRateLimited(await refresh());
    // Separate counts: the other auth routes are unaffected.
    await request(app).post('/auth/signup').send({}).expect(400);
  });
});

describe('in tests', () => {
  it('is off unless RATE_LIMIT_IN_TESTS=1', async () => {
    delete process.env.RATE_LIMIT_IN_TESTS;
    await times(LIMITS.login + 5, () => wrong(emailFor('ana')), 401);
  });
});

describe('in production', () => {
  let prodApp;
  let prodPrisma;
  const saved = process.env.NODE_ENV;
  const savedCors = process.env.CORS_ORIGIN;

  beforeAll(() => {
    process.env.NODE_ENV = 'production';
    process.env.CORS_ORIGIN = 'https://campuspool.example';
    // Required in production; never read here (nothing in these tests sends a notification).
    process.env.FIREBASE_SERVICE_ACCOUNT_PATH = '/nonexistent/firebase-service-account.json';
    jest.isolateModules(() => {
      prodApp = require('../src/app');
      prodPrisma = require('../src/lib/prisma');
    });
  });
  afterAll(async () => {
    process.env.NODE_ENV = saved;
    process.env.FIREBASE_SERVICE_ACCOUNT_PATH = '';
    if (savedCors === undefined) delete process.env.CORS_ORIGIN;
    else process.env.CORS_ORIGIN = savedCors;
    await prodPrisma.$disconnect();
  });

  // Invalid bodies: refused by validation after the limiter, without touching the database.
  const from = (ip) =>
    request(prodApp).post('/auth/login').set('X-Forwarded-For', ip).send({ email: 'a@b.c' });

  it('trusts one proxy and limits by the client IP it forwards', async () => {
    expect(prodApp.get('trust proxy')).toBe(1);
    await times(LIMITS.login, () => from('203.0.113.7'), 400);
    expectRateLimited(await from('203.0.113.7'));
    await from('203.0.113.8').expect(400);
  });

  it('does not trust the proxy outside production', () => {
    expect(app.get('trust proxy')).toBe(false);
  });
});
