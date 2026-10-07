const jwt = require('jsonwebtoken');
const request = require('supertest');
const { app, prisma, resetDb, emailFor, createVerifiedUser } = require('./helpers/auth');

const email = emailFor('ivy');
const bearer = (token) => ({ Authorization: `Bearer ${token}` });

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

describe('GET /users/me', () => {
  it('returns 401 without a token', async () => {
    const res = await request(app).get('/users/me').expect(401);
    expect(res.body).toEqual({ error: { code: 'UNAUTHORIZED', message: expect.any(String) } });
  });

  it('returns 401 for an expired token', async () => {
    const { user } = await createVerifiedUser(email);
    const expired = jwt.sign(
      { sub: user.id, role: user.role, exp: Math.floor(Date.now() / 1000) - 60 },
      process.env.JWT_ACCESS_SECRET,
    );

    const res = await request(app).get('/users/me').set(bearer(expired)).expect(401);
    expect(res.body.error.code).toBe('TOKEN_EXPIRED');
  });

  it('returns 401 for a token signed with the wrong secret', async () => {
    const { user } = await createVerifiedUser(email);
    const forged = jwt.sign(
      { sub: user.id, role: 'BOTH' },
      'some-other-secret-some-other-secret-0000',
    );

    const res = await request(app).get('/users/me').set(bearer(forged)).expect(401);
    expect(res.body.error.code).toBe('INVALID_TOKEN');
  });

  it('returns 401 for garbage and for a non-Bearer header', async () => {
    await request(app).get('/users/me').set(bearer('garbage')).expect(401);
    await request(app).get('/users/me').set({ Authorization: 'Basic abc' }).expect(401);
  });

  it('returns 401 when the user no longer exists', async () => {
    const { accessToken, user } = await createVerifiedUser(email);
    await prisma.user.delete({ where: { id: user.id } });
    await request(app).get('/users/me').set(bearer(accessToken)).expect(401);
  });

  it('returns the profile without sensitive fields for a valid token', async () => {
    const { accessToken } = await createVerifiedUser(email);

    const res = await request(app).get('/users/me').set(bearer(accessToken)).expect(200);
    expect(res.body.user).toMatchObject({
      email,
      name: 'Test User',
      role: 'RIDER',
      isVerified: true,
      ratingAvg: 0,
      ratingCount: 0,
    });
    for (const field of ['passwordHash', 'fcmToken', 'tokenHash', 'codeHash']) {
      expect(res.body.user).not.toHaveProperty(field);
    }
  });
});

describe('PATCH /users/me', () => {
  const patch = (token, body) => request(app).patch('/users/me').set(bearer(token)).send(body);

  it('requires authentication', async () => {
    await request(app).patch('/users/me').send({ name: 'X' }).expect(401);
  });

  it('updates name, phone and role', async () => {
    const { accessToken } = await createVerifiedUser(email);

    const res = await patch(accessToken, {
      name: ' New Name ',
      phone: '+919876543210',
      role: 'BOTH',
    }).expect(200);
    expect(res.body.user).toMatchObject({ name: 'New Name', phone: '+919876543210', role: 'BOTH' });
    expect(res.body.user).not.toHaveProperty('passwordHash');

    const stored = await prisma.user.findUniqueOrThrow({ where: { email } });
    expect(stored).toMatchObject({ name: 'New Name', phone: '+919876543210', role: 'BOTH' });
  });

  it('allows clearing the phone number', async () => {
    const { accessToken } = await createVerifiedUser(email);
    await patch(accessToken, { phone: '9876543210' }).expect(200);
    const res = await patch(accessToken, { phone: null }).expect(200);
    expect(res.body.user.phone).toBeNull();
  });

  it.each([
    ['invalid role', { role: 'ADMIN' }],
    ['bad phone', { phone: 'call me' }],
    ['empty name', { name: '   ' }],
    ['empty body', {}],
    ['protected field', { isVerified: false }],
    ['protected field alongside a valid one', { name: 'Ok', ratingAvg: 5 }],
  ])('returns 400 for %s', async (_label, body) => {
    const { accessToken } = await createVerifiedUser(email);
    const res = await patch(accessToken, body).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');

    const stored = await prisma.user.findUniqueOrThrow({ where: { email } });
    expect(stored).toMatchObject({ name: 'Test User', isVerified: true, ratingAvg: 0 });
  });
});
