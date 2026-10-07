const request = require('supertest');
const { app, prisma, resetDb, emailFor, lastOtpCode, signup } = require('./helpers/auth');

const email = emailFor('erin');
const verify = (code, to = email) =>
  request(app).post('/auth/verify-otp').send({ email: to, code });
const wrongCode = (real) => (real === '000000' ? '111111' : '000000');

beforeEach(async () => {
  await resetDb();
  await signup({ email }).expect(201);
});
afterAll(() => prisma.$disconnect());

describe('POST /auth/verify-otp', () => {
  it('verifies the user and returns tokens without sensitive fields', async () => {
    const res = await verify(lastOtpCode(email)).expect(200);

    expect(res.body).toMatchObject({
      accessToken: expect.any(String),
      refreshToken: expect.any(String),
      expiresIn: 900,
      user: { email, isVerified: true, role: 'RIDER' },
    });
    expect(JSON.stringify(res.body)).not.toMatch(/passwordHash|tokenHash|codeHash|fcmToken/);

    const user = await prisma.user.findUnique({ where: { email } });
    expect(user.isVerified).toBe(true);

    // Only a hash of the refresh token is stored.
    const tokens = await prisma.refreshToken.findMany({ where: { userId: user.id } });
    expect(tokens).toHaveLength(1);
    expect(tokens[0].tokenHash).not.toBe(res.body.refreshToken);
  });

  it('rejects a wrong code and counts the attempt', async () => {
    const res = await verify(wrongCode(lastOtpCode(email))).expect(400);
    expect(res.body.error.code).toBe('INVALID_CODE');
    const otp = await prisma.emailOtp.findFirstOrThrow({ where: { email } });
    expect(otp).toMatchObject({ attempts: 1, consumedAt: null });
  });

  it('rejects an expired code', async () => {
    const code = lastOtpCode(email);
    await prisma.emailOtp.updateMany({
      where: { email },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });

    const res = await verify(code).expect(400);
    expect(res.body.error.code).toBe('CODE_EXPIRED');
    expect((await prisma.user.findUnique({ where: { email } })).isVerified).toBe(false);
  });

  it('blocks the 6th attempt, even with the correct code', async () => {
    const code = lastOtpCode(email);
    for (let i = 0; i < 5; i++) {
      await verify(wrongCode(code)).expect(400);
    }

    const res = await verify(code).expect(429);
    expect(res.body.error.code).toBe('TOO_MANY_ATTEMPTS');
    expect((await prisma.user.findUnique({ where: { email } })).isVerified).toBe(false);
  });

  it('rejects a code that was already used', async () => {
    const code = lastOtpCode(email);
    await verify(code).expect(200);

    const res = await verify(code).expect(400);
    expect(res.body.error.code).toBe('INVALID_CODE');
    expect(await prisma.refreshToken.count()).toBe(1);
  });

  it('rejects a code for an email that never signed up', async () => {
    const res = await verify('123456', emailFor('nobody')).expect(400);
    expect(res.body.error.code).toBe('INVALID_CODE');
  });

  it.each([
    ['not 6 digits', { email, code: '12345' }],
    ['non-numeric', { email, code: 'abcdef' }],
    ['missing code', { email }],
    ['missing email', { code: '123456' }],
  ])('returns 400 for a malformed body (%s)', async (_label, body) => {
    const res = await request(app).post('/auth/verify-otp').send(body).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });
});

describe('POST /auth/resend-otp', () => {
  const resend = (to = email) => request(app).post('/auth/resend-otp').send({ email: to });

  it('is limited to one per 60 seconds per email', async () => {
    const res = await resend().expect(429);
    expect(res.body.error.code).toBe('RATE_LIMITED');
  });

  it('sends a new code after the cooldown and invalidates the old one', async () => {
    const oldCode = lastOtpCode(email);
    await prisma.emailOtp.updateMany({
      where: { email },
      data: { createdAt: new Date(Date.now() - 61 * 1000) },
    });

    await resend().expect(200);
    const newCode = lastOtpCode(email);

    if (newCode !== oldCode) {
      await verify(oldCode).expect(400);
    }
    await verify(newCode).expect(200);
  });

  it('answers the same for an unknown email and sends nothing', async () => {
    const before = require('nodemailer').sendMail.mock.calls.length;
    await resend(emailFor('nobody')).expect(200);
    expect(require('nodemailer').sendMail.mock.calls.length).toBe(before);
  });

  it('returns 400 for an invalid email', async () => {
    await request(app).post('/auth/resend-otp').send({ email: 'nope' }).expect(400);
  });
});
