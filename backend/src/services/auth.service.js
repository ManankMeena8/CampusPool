const crypto = require('crypto');
const bcrypt = require('bcrypt');
const { env } = require('../config/env');
const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const { sendOtpEmail } = require('../lib/mailer');
const { toPublicUser } = require('../lib/serializers');
const {
  ACCESS_TOKEN_TTL_SECONDS,
  REFRESH_TOKEN_TTL_MS,
  signAccessToken,
  sha256,
  generateRefreshToken,
} = require('../lib/tokens');

const OTP_TTL_MS = 5 * 60 * 1000;
const OTP_MAX_ATTEMPTS = 5;
const OTP_RESEND_COOLDOWN_MS = 60 * 1000;
const OTP_MAX_PER_HOUR = 5;
const BCRYPT_ROUNDS = env.NODE_ENV === 'test' ? 4 : 12;

// ---------- helpers ----------

/** HMAC (not a bare hash): a 6-digit code is trivially brute-forced from a plain hash. */
function hashOtp(email, code) {
  return crypto
    .createHmac('sha256', env.JWT_ACCESS_SECRET)
    .update(`${email}:${code}`)
    .digest('hex');
}

function safeEqualHex(a, b) {
  const x = Buffer.from(a, 'hex');
  const y = Buffer.from(b, 'hex');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

let dummyHash;
/** Compared against when the email is unknown, so login timing does not reveal which emails exist. */
async function getDummyHash() {
  dummyHash ??= await bcrypt.hash('not-a-real-password', BCRYPT_ROUNDS);
  return dummyHash;
}

/**
 * Every new code gets a fresh set of guesses, so issuing codes must be throttled or an attacker
 * could keep requesting codes and guessing. Limits: 1 per 60 seconds and 5 per hour, per email.
 */
async function assertCanIssueOtp(email) {
  const recent = await prisma.emailOtp.findMany({
    where: { email, purpose: 'SIGNUP', createdAt: { gt: new Date(Date.now() - 60 * 60 * 1000) } },
    orderBy: { createdAt: 'desc' },
    select: { createdAt: true },
  });
  if (recent.length === 0) return;

  const waitMs = recent[0].createdAt.getTime() + OTP_RESEND_COOLDOWN_MS - Date.now();
  if (waitMs > 0) {
    throw new AppError(
      'RATE_LIMITED',
      `Please wait ${Math.ceil(waitMs / 1000)} seconds before requesting another code`,
      429,
    );
  }
  if (recent.length >= OTP_MAX_PER_HOUR) {
    throw new AppError(
      'RATE_LIMITED',
      'Too many verification codes requested. Try again in an hour',
      429,
    );
  }
}

/** Invalidates earlier unused codes for the email, stores a new hashed one, and emails it. */
async function issueOtp(email) {
  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  const now = new Date();
  await prisma.$transaction([
    prisma.emailOtp.updateMany({
      where: { email, purpose: 'SIGNUP', consumedAt: null },
      data: { consumedAt: now },
    }),
    prisma.emailOtp.create({
      data: {
        email,
        codeHash: hashOtp(email, code),
        purpose: 'SIGNUP',
        expiresAt: new Date(now.getTime() + OTP_TTL_MS),
      },
    }),
  ]);
  await sendOtpEmail(email, code, OTP_TTL_MS / 60000);
}

async function createSession(user) {
  const { token, tokenHash } = generateRefreshToken();
  await prisma.refreshToken.create({
    data: {
      userId: user.id,
      tokenHash,
      expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL_MS),
    },
  });
  return {
    accessToken: signAccessToken(user),
    refreshToken: token,
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
    user: toPublicUser(user),
  };
}

function revokeAllSessions(userId) {
  return prisma.refreshToken.updateMany({
    where: { userId, revokedAt: null },
    data: { revokedAt: new Date() },
  });
}

// ---------- operations ----------

async function signup({ name, email, password }) {
  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing?.isVerified) {
    throw new AppError('EMAIL_TAKEN', 'An account with this email already exists', 409);
  }
  await assertCanIssueOtp(email); // before touching the account, so a throttled retry changes nothing

  const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
  try {
    if (existing) {
      // Abandoned signup: let the person retry with new details and a fresh code.
      await prisma.user.update({ where: { email }, data: { name, passwordHash } });
    } else {
      await prisma.user.create({ data: { name, email, passwordHash } });
    }
  } catch (err) {
    if (err.code === 'P2002') {
      throw new AppError('EMAIL_TAKEN', 'An account with this email already exists', 409);
    }
    throw err;
  }

  await issueOtp(email);
  return { email };
}

async function verifyOtp({ email, code }) {
  const invalid = () => new AppError('INVALID_CODE', 'Invalid verification code', 400);

  const otp = await prisma.emailOtp.findFirst({
    where: { email, purpose: 'SIGNUP', consumedAt: null },
    orderBy: { createdAt: 'desc' },
  });
  if (!otp) throw invalid();
  if (otp.expiresAt <= new Date()) {
    throw new AppError('CODE_EXPIRED', 'Verification code expired. Request a new one', 400);
  }

  // Count the attempt first, atomically, so parallel guesses cannot exceed the limit.
  const counted = await prisma.emailOtp.updateMany({
    where: { id: otp.id, consumedAt: null, attempts: { lt: OTP_MAX_ATTEMPTS } },
    data: { attempts: { increment: 1 } },
  });
  if (counted.count === 0) {
    throw new AppError('TOO_MANY_ATTEMPTS', 'Too many incorrect attempts. Request a new code', 429);
  }

  if (!safeEqualHex(otp.codeHash, hashOtp(email, code))) throw invalid();

  // Single use: only one request can flip consumedAt from null.
  const consumed = await prisma.emailOtp.updateMany({
    where: { id: otp.id, consumedAt: null },
    data: { consumedAt: new Date() },
  });
  if (consumed.count === 0) throw invalid();

  const user = await prisma.user.findUnique({ where: { email } });
  if (!user) throw invalid();
  const verified = user.isVerified
    ? user
    : await prisma.user.update({ where: { id: user.id }, data: { isVerified: true } });

  return createSession(verified);
}

async function resendOtp({ email }) {
  await assertCanIssueOtp(email);

  // Same response whether or not the email is registered, so this cannot be used to probe accounts.
  const user = await prisma.user.findUnique({ where: { email } });
  if (user && !user.isVerified) await issueOtp(email);
}

async function login({ email, password }) {
  const user = await prisma.user.findUnique({ where: { email } });
  const ok = await bcrypt.compare(password, user ? user.passwordHash : await getDummyHash());
  if (!user || !ok) {
    throw new AppError('INVALID_CREDENTIALS', 'Invalid email or password', 401);
  }
  if (!user.isVerified) {
    throw new AppError('EMAIL_NOT_VERIFIED', 'Verify your email before logging in', 403);
  }
  return createSession(user);
}

async function refresh({ refreshToken }) {
  const tokenHash = sha256(refreshToken);
  const stored = await prisma.refreshToken.findUnique({ where: { tokenHash } });
  if (!stored) {
    throw new AppError('INVALID_REFRESH_TOKEN', 'Invalid refresh token', 401);
  }

  const reuse = async () => {
    // A rotated-out token showing up again means it may have been stolen: end every session.
    await revokeAllSessions(stored.userId);
    return new AppError('REFRESH_TOKEN_REUSED', 'Refresh token already used. Log in again', 401);
  };

  if (stored.revokedAt) throw await reuse();
  if (stored.expiresAt <= new Date()) {
    throw new AppError('REFRESH_TOKEN_EXPIRED', 'Refresh token expired. Log in again', 401);
  }

  // Only one concurrent request can revoke the token; the loser is treated as a reuse.
  const claimed = await prisma.refreshToken.updateMany({
    where: { id: stored.id, revokedAt: null },
    data: { revokedAt: new Date() },
  });
  if (claimed.count === 0) throw await reuse();

  const user = await prisma.user.findUnique({ where: { id: stored.userId } });
  return createSession(user);
}

async function logout({ refreshToken }) {
  await prisma.refreshToken.updateMany({
    where: { tokenHash: sha256(refreshToken), revokedAt: null },
    data: { revokedAt: new Date() },
  });
}

module.exports = { signup, verifyOtp, resendOtp, login, refresh, logout };
