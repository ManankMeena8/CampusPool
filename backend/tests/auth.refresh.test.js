const request = require('supertest');
const { app, prisma, resetDb, emailFor, createVerifiedUser } = require('./helpers/auth');

const email = emailFor('grace');
const refresh = (refreshToken) => request(app).post('/auth/refresh').send({ refreshToken });

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

describe('POST /auth/refresh', () => {
  it('rotates: returns a new pair and revokes the old token', async () => {
    const first = await createVerifiedUser(email);

    const res = await refresh(first.refreshToken).expect(200);
    expect(res.body.refreshToken).toEqual(expect.any(String));
    expect(res.body.refreshToken).not.toBe(first.refreshToken);
    expect(res.body.accessToken).toEqual(expect.any(String));
    expect(JSON.stringify(res.body)).not.toMatch(/passwordHash|tokenHash/);

    const rows = await prisma.refreshToken.findMany();
    expect(rows).toHaveLength(2);
    expect(rows.filter((r) => r.revokedAt === null)).toHaveLength(1);

    // The new token works too.
    await refresh(res.body.refreshToken).expect(200);
  });

  it('revokes every session of the user when a rotated token is reused', async () => {
    const first = await createVerifiedUser(email);
    const second = (await refresh(first.refreshToken).expect(200)).body;

    const reuse = await refresh(first.refreshToken).expect(401);
    expect(reuse.body.error.code).toBe('REFRESH_TOKEN_REUSED');

    // The token issued by the legitimate rotation is dead as well.
    const after = await refresh(second.refreshToken).expect(401);
    expect(after.body.error.code).toBe('REFRESH_TOKEN_REUSED');
    expect(await prisma.refreshToken.count({ where: { revokedAt: null } })).toBe(0);
  });

  it('lets only one of two simultaneous refreshes win, then ends all sessions', async () => {
    const first = await createVerifiedUser(email);

    const results = await Promise.all([refresh(first.refreshToken), refresh(first.refreshToken)]);

    const statuses = results.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 401]);
    const loser = results.find((r) => r.status === 401);
    expect(loser.body.error.code).toBe('REFRESH_TOKEN_REUSED');
    expect(await prisma.refreshToken.count({ where: { revokedAt: null } })).toBe(0);
  });

  it('does not touch other users when one user reuses a token', async () => {
    const mine = await createVerifiedUser(email);
    const other = await createVerifiedUser(emailFor('henry'));
    await refresh(mine.refreshToken).expect(200);
    await refresh(mine.refreshToken).expect(401);

    await refresh(other.refreshToken).expect(200);
  });

  it('rejects an unknown token', async () => {
    const res = await refresh('not-a-real-token').expect(401);
    expect(res.body.error.code).toBe('INVALID_REFRESH_TOKEN');
  });

  it('rejects an expired token', async () => {
    const first = await createVerifiedUser(email);
    await prisma.refreshToken.updateMany({ data: { expiresAt: new Date(Date.now() - 1000) } });

    const res = await refresh(first.refreshToken).expect(401);
    expect(res.body.error.code).toBe('REFRESH_TOKEN_EXPIRED');
  });

  it('returns 400 when the body is missing the token', async () => {
    const res = await request(app).post('/auth/refresh').send({}).expect(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
  });
});

describe('POST /auth/logout', () => {
  const logout = (refreshToken) => request(app).post('/auth/logout').send({ refreshToken });

  it('revokes the given refresh token', async () => {
    const session = await createVerifiedUser(email);
    await logout(session.refreshToken).expect(204);

    expect(await prisma.refreshToken.count({ where: { revokedAt: null } })).toBe(0);
    await refresh(session.refreshToken).expect(401);
  });

  it('is idempotent and does not reveal whether a token existed', async () => {
    await logout('not-a-real-token').expect(204);
  });

  it('returns 400 when the token is missing', async () => {
    await request(app).post('/auth/logout').send({}).expect(400);
  });
});
