const request = require('supertest');
const app = require('../src/app');
const prisma = require('../src/lib/prisma');

afterAll(() => prisma.$disconnect());

describe('unknown routes and bad input', () => {
  it('returns 404 in the standard error format', async () => {
    const res = await request(app).get('/does-not-exist');
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: { code: 'NOT_FOUND', message: expect.any(String) } });
  });

  it('returns 400 for malformed JSON bodies', async () => {
    const res = await request(app)
      .post('/health')
      .set('Content-Type', 'application/json')
      .send('{bad');
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('INVALID_JSON');
  });
});

describe('client errors raised by Express', () => {
  it('returns a 4xx in the standard format for an unsupported body encoding, not a 500', async () => {
    const res = await request(app)
      .post('/auth/login')
      .set('Content-Type', 'application/json')
      .set('Content-Encoding', 'foo')
      .send('{}');
    expect(res.status).toBe(415);
    expect(res.body).toEqual({ error: { code: 'BAD_REQUEST', message: expect.any(String) } });
  });
});

describe('describeForLog', () => {
  const { describeForLog } = require('../src/middleware/errorHandler');

  it('omits Prisma error details, which can embed password or code hashes', () => {
    const err = new Error('Invalid prisma.user.create() invocation: passwordHash: "$2b$12$secret"');
    err.name = 'PrismaClientKnownRequestError';
    err.code = 'P2002';

    const logged = describeForLog(err);
    expect(logged).toContain('P2002');
    expect(logged).not.toMatch(/secret|passwordHash/);
  });

  it('passes other errors through unchanged', () => {
    const err = new Error('boom');
    expect(describeForLog(err)).toBe(err);
  });
});
