const bcrypt = require('bcrypt');
const {
  prisma,
  sendMail,
  resetDb,
  emailFor,
  lastOtpCode,
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
