const { randomUUID } = require('crypto');
const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { bearer, createUser } = require('./helpers/rides');

// Endpoints that take no query (and, for the POSTs, no body): extra input is a 400, not ignored.
beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

const id = randomUUID();

describe('endpoints without input refuse unexpected fields', () => {
  it.each([
    ['GET', '/health'],
    ['GET', '/users/me'],
    ['GET', '/rides/mine'],
    ['GET', '/bookings/mine'],
    ['GET', `/rides/${id}`],
    ['GET', `/rides/${id}/bookings`],
  ])('%s %s with a query', async (method, path) => {
    const { token } = await createUser('ana');
    const res = await request(app)
      [method.toLowerCase()](path)
      .query({ status: 'OPEN' })
      .set(bearer(token))
      .expect(400);
    expect(res.body.error).toEqual({
      code: 'VALIDATION_ERROR',
      message: expect.stringMatching(/^query: /),
    });
  });

  it.each([
    `/rides/${id}/cancel`,
    `/rides/${id}/start`,
    `/rides/${id}/complete`,
    `/bookings/${id}/accept`,
    `/bookings/${id}/reject`,
    `/bookings/${id}/cancel`,
  ])('POST %s with a body', async (path) => {
    const { token } = await createUser('ana');
    const res = await request(app).post(path).set(bearer(token)).send({ seats: 2 }).expect(400);
    expect(res.body.error).toEqual({
      code: 'VALIDATION_ERROR',
      message: expect.stringMatching(/^body: /),
    });
  });

  it('POST with a body route still refuses a query', async () => {
    await request(app)
      .post('/auth/login?debug=1')
      .send({ email: 'a@b.c', password: 'x' })
      .expect(400);
  });
});
