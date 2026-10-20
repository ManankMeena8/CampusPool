const request = require('supertest');
const { app, prisma, resetDb } = require('./helpers/auth');
const { bearer, createUser } = require('./helpers/rides');

const TOKEN = 'fcm-token-'.padEnd(160, 'x');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

const put = (accessToken, body) =>
  request(app).put('/users/me/fcm-token').set(bearer(accessToken)).send(body);

const storedToken = async (id) =>
  (await prisma.user.findUniqueOrThrow({ where: { id }, select: { fcmToken: true } })).fcmToken;

describe('PUT /users/me/fcm-token', () => {
  it('requires authentication', async () => {
    await request(app).put('/users/me/fcm-token').send({ token: TOKEN }).expect(401);
  });

  it('stores the token and returns 204', async () => {
    const { token, user } = await createUser('ana', 'RIDER');
    const res = await put(token, { token: TOKEN }).expect(204);
    expect(res.body).toEqual({});
    expect(await storedToken(user.id)).toBe(TOKEN);
  });

  it('replaces an earlier token and accepts the same token again', async () => {
    const { token, user } = await createUser('ana', 'RIDER');
    await put(token, { token: 'old-token' }).expect(204);
    await put(token, { token: TOKEN }).expect(204);
    await put(token, { token: TOKEN }).expect(204);
    expect(await storedToken(user.id)).toBe(TOKEN);
  });

  it('takes the token off another user who registered the same device', async () => {
    const first = await createUser('ana', 'RIDER');
    const second = await createUser('ben', 'RIDER');
    await put(first.token, { token: TOKEN }).expect(204);
    await put(second.token, { token: TOKEN }).expect(204);

    expect(await storedToken(first.user.id)).toBeNull();
    expect(await storedToken(second.user.id)).toBe(TOKEN);
  });

  it('never exposes the token in the profile', async () => {
    const { token } = await createUser('ana', 'RIDER');
    await put(token, { token: TOKEN }).expect(204);
    const res = await request(app).get('/users/me').set(bearer(token)).expect(200);
    expect(JSON.stringify(res.body)).not.toContain(TOKEN);
    expect(res.body.user).not.toHaveProperty('fcmToken');
  });

  it.each([
    ['a missing token', {}],
    ['an empty token', { token: '   ' }],
    ['a non-string token', { token: 123 }],
    ['an oversized token', { token: 'x'.repeat(4097) }],
  ])('returns 400 for %s and keeps the stored token', async (_label, body) => {
    const { token, user } = await createUser('ana', 'RIDER');
    await put(token, { token: TOKEN }).expect(204);
    const res = await put(token, body).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(await storedToken(user.id)).toBe(TOKEN);
  });
});
