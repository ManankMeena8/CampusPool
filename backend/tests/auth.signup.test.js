const bcrypt = require('bcrypt');
const {
  prisma,
  sendMail,
  resetDb,
  emailFor,
  lastOtpCode,
  ageOtps,
  signup,
  createVerifiedUser,
} = require('./helpers/auth');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

describe('POST /auth/signup', () => {
  it('creates an unverified user, stores only hashes, and emails a 6-digit code', async () => {
    const email = emailFor('alice');
    const res = await signup({ name: 'Alice', email }).expect(201);

    expect(res.body).toEqual({ message: expect.any(String), email });
    expect(JSON.stringify(res.body)).not.toMatch(/passwordHash|codeHash/);

    const user = await prisma.user.findUnique({ where: { email } });
    expect(user).toMatchObject({ name: 'Alice', isVerified: false, role: 'RIDER' });
    expect(user.passwordHash).not.toBe('Passw0rdTest');
    expect(await bcrypt.compare('Passw0rdTest', user.passwordHash)).toBe(true);

    expect(sendMail).toHaveBeenCalledTimes(1);
    const code = lastOtpCode(email);
    expect(code).toMatch(/^\d{6}$/);

    const otp = await prisma.emailOtp.findFirstOrThrow({ where: { email } });
    expect(otp.codeHash).not.toContain(code);
    expect(otp.expiresAt.getTime()).toBeGreaterThan(Date.now() + 4 * 60 * 1000);
    expect(otp.expiresAt.getTime()).toBeLessThanOrEqual(Date.now() + 5 * 60 * 1000);
  });

  it('lowercases and trims the email', async () => {
    await signup({ email: `  Bob@${emailFor('x').split('@')[1].toUpperCase()} ` }).expect(201);
    expect(await prisma.user.findUnique({ where: { email: emailFor('bob') } })).not.toBeNull();
  });

  it('rejects an email outside the allowed domain', async () => {
    const res = await signup({ email: 'alice@gmail.com' }).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toMatch(/body\.email/);
    expect(sendMail).not.toHaveBeenCalled();
  });

  it('rejects a lookalike domain that merely ends with the allowed one', async () => {
    const domain = emailFor('x').split('@')[1];
    await signup({ email: `alice@evil${domain}` }).expect(400);
  });

  it.each([
    ['too short', 'Ab1'],
    ['no number', 'abcdefgh'],
    ['no letter', '12345678'],
  ])('rejects a weak password (%s)', async (_label, password) => {
    const res = await signup({ password }).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(res.body.error.message).toMatch(/body\.password/);
  });

  it('returns 409 when the email belongs to a verified user', async () => {
    const email = emailFor('carol');
    await createVerifiedUser(email);
    const res = await signup({ email }).expect(409);
    expect(res.body.error.code).toBe('EMAIL_TAKEN');
  });

  it('lets an unverified user retry: updates name and password, sends a fresh code', async () => {
    const email = emailFor('dave');
    await signup({ email, name: 'Old Name', password: 'OldPassw0rd' }).expect(201);
    const firstHash = (await prisma.emailOtp.findFirstOrThrow({ where: { email } })).codeHash;
    await ageOtps(email);

    await signup({ email, name: 'New Name', password: 'NewPassw0rd' }).expect(201);

    const users = await prisma.user.findMany({ where: { email } });
    expect(users).toHaveLength(1);
    expect(users[0].name).toBe('New Name');
    expect(await bcrypt.compare('NewPassw0rd', users[0].passwordHash)).toBe(true);
    expect(sendMail).toHaveBeenCalledTimes(2);

    // Only the newest code is live.
    const active = await prisma.emailOtp.findMany({ where: { email, consumedAt: null } });
    expect(active).toHaveLength(1);
    expect(active[0].codeHash).not.toBe(firstHash);
    expect(lastOtpCode(email)).toMatch(/^\d{6}$/);
  });

  it.each([
    ['name', { name: undefined }],
    ['email', { email: undefined }],
    ['password', { password: undefined }],
    ['everything', { name: undefined, email: undefined, password: undefined }],
  ])('returns 400 when %s is missing', async (_label, overrides) => {
    const res = await signup(overrides).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(sendMail).not.toHaveBeenCalled();
  });

  it('returns 503 and the standard format when the email cannot be sent', async () => {
    sendMail.mockRejectedValueOnce(new Error('smtp down'));
    const res = await signup().expect(503);
    expect(res.body).toEqual({ error: { code: 'EMAIL_SEND_FAILED', message: expect.any(String) } });
  });
});

describe('POST /auth/signup abuse limits and password edge cases', () => {
  it('throttles signup retries for the same email and changes nothing when throttled', async () => {
    const email = emailFor('retry');
    await signup({ email, name: 'First' }).expect(201);

    const res = await signup({ email, name: 'Second' }).expect(429);
    expect(res.body.error.code).toBe('RATE_LIMITED');
    expect((await prisma.user.findUniqueOrThrow({ where: { email } })).name).toBe('First');
    expect(sendMail).toHaveBeenCalledTimes(1);
  });

  it('caps verification codes at 5 per hour per email, even when spaced out', async () => {
    const email = emailFor('flood');
    const past = new Date(Date.now() - 10 * 60 * 1000);
    await prisma.emailOtp.createMany({
      data: Array.from({ length: 5 }, () => ({
        email,
        codeHash: 'x'.repeat(64),
        expiresAt: past,
        createdAt: past,
      })),
    });

    const res = await signup({ email }).expect(429);
    expect(res.body.error.code).toBe('RATE_LIMITED');
    expect(sendMail).not.toHaveBeenCalled();
  });

  it('rejects passwords over 72 bytes, which bcrypt would silently truncate', async () => {
    const password = 'é'.repeat(40) + 'a1'; // 42 characters but 82 bytes
    const res = await signup({ password }).expect(400);
    expect(res.body.error.message).toMatch(/body\.password/);
  });
});
