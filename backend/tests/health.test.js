const request = require('supertest');
const app = require('../src/app');
const prisma = require('../src/lib/prisma');
const healthService = require('../src/services/health.service');

afterEach(() => jest.restoreAllMocks());
afterAll(() => prisma.$disconnect());

describe('GET /health', () => {
  it('returns 200 when the database and PostGIS respond', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    // No jobs run with the app in tests, so there is no Redis connection to check.
    expect(res.body).toEqual({ status: 'ok', db: 'ok', redis: 'disabled' });
  });

  it.each(['ok', 'down'])('reports redis "%s" and stays 200 either way', async (state) => {
    jest.spyOn(healthService, 'checkRedis').mockResolvedValue(state);
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', db: 'ok', redis: state });
  });

  it('is still 503 when the database is down, whatever Redis says', async () => {
    jest.spyOn(healthService, 'checkRedis').mockResolvedValue('ok');
    jest.spyOn(prisma, '$queryRaw').mockRejectedValue(new Error('connection refused'));
    expect((await request(app).get('/health')).status).toBe(503);
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
