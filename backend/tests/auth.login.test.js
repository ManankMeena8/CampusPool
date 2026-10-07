const request = require('supertest');
const {
  app,
  prisma,
  PASSWORD,
  resetDb,
  emailFor,
  signup,
  createVerifiedUser,
} = require('./helpers/auth');

const email = emailFor('frank');
const login = (body) => request(app).post('/auth/login').send(body);

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

describe('POST /auth/login', () => {
  it('returns tokens and the public user for correct credentials', async () => {
    await createVerifiedUser(email);

    const res = await login({ email, password: PASSWORD }).expect(200);
    expect(res.body).toMatchObject({
      accessToken: expect.any(String),
      refreshToken: expect.any(String),
      expiresIn: 900,
      user: { email, isVerified: true },
    });
    expect(JSON.stringify(res.body)).not.toMatch(/passwordHash|tokenHash/);
  });

  it('accepts the email in any case', async () => {
    await createVerifiedUser(email);
    await login({ email: email.toUpperCase(), password: PASSWORD }).expect(200);
  });

  it('rejects a wrong password with a generic message', async () => {
    await createVerifiedUser(email);
    const res = await login({ email, password: 'WrongPassw0rd' }).expect(401);
    expect(res.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it('gives an identical response for an unknown email and a wrong password', async () => {
    await createVerifiedUser(email);
    const wrong = await login({ email, password: 'WrongPassw0rd' });
    const unknown = await login({ email: emailFor('ghost'), password: PASSWORD });

    expect(unknown.status).toBe(wrong.status);
    expect(unknown.body).toEqual(wrong.body);
  });

  it('rejects an unverified user with a clear code', async () => {
    await signup({ email }).expect(201);
    const res = await login({ email, password: PASSWORD }).expect(403);
    expect(res.body.error.code).toBe('EMAIL_NOT_VERIFIED');
  });

  it('does not reveal that an account is unverified when the password is wrong', async () => {
    await signup({ email }).expect(201);
    const res = await login({ email, password: 'WrongPassw0rd' }).expect(401);
    expect(res.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it.each([
    ['missing password', { email }],
    ['missing email', { password: PASSWORD }],
    ['invalid email', { email: 'nope', password: PASSWORD }],
  ])('returns 400 for %s', async (_label, body) => {
    const res = await login(body).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });
});
