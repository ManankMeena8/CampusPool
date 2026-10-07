const request = require('supertest');
const app = require('../src/app');
const prisma = require('../src/lib/prisma');

afterEach(() => jest.restoreAllMocks());
afterAll(() => prisma.$disconnect());

describe('GET /health', () => {
  it('returns 200 when the database and PostGIS respond', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', db: 'ok' });
  });

  it('returns 503 in the standard error format when the database check fails', async () => {
    jest.spyOn(prisma, '$queryRaw').mockRejectedValue(new Error('connection refused'));
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({
      error: { code: 'DB_UNAVAILABLE', message: expect.any(String) },
    });
  });
});
