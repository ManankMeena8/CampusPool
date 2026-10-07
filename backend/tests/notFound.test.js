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
