const { rateLimit, ipKeyGenerator, MemoryStore } = require('express-rate-limit');
const { env } = require('../config/env');
const AppError = require('../lib/AppError');

/*
 * Rate limits on /auth. Many students share one campus Wi-Fi address, so the per-IP limits are
 * generous; brute-force protection comes from the login limiter, keyed by IP and email, which
 * counts only failed attempts. Counts live in this process's memory (like the location store),
 * so they assume a single API instance and reset on restart.
 *
 * Off in tests unless RATE_LIMIT_IN_TESTS=1 (read per request, for tests/rateLimits.test.js).
 */

const WINDOW_MS = 15 * 60 * 1000;
const LIMITS = Object.freeze({
  // Every /auth route but refresh, per IP.
  auth: 100,
  // Every active app refreshes about every 15 minutes, so a campus behind one IP needs headroom.
  refresh: 1000,
  // Failed logins per IP + email.
  login: 10,
});

const stores = [];

const skip = () => env.NODE_ENV === 'test' && process.env.RATE_LIMIT_IN_TESTS !== '1';

/** Shared options; a refusal goes through the error handler, so it has the usual body. */
function limiter(limit, message, options = {}) {
  const store = new MemoryStore();
  stores.push(store);
  return rateLimit({
    windowMs: WINDOW_MS,
    limit,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    store,
    skip,
    handler: (_req, _res, next) => next(new AppError('RATE_LIMITED', message, 429)),
    ...options,
  });
}

const authLimiter = limiter(LIMITS.auth, 'Too many requests. Try again in a few minutes');

const refreshLimiter = limiter(
  LIMITS.refresh,
  'Too many session refreshes. Try again in a few minutes',
);

/** Runs before validation, so the email is normalized the way loginBody does it. */
function loginKey(req) {
  const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
  return `${ipKeyGenerator(req.ip)}|${email}`;
}

const loginLimiter = limiter(
  LIMITS.login,
  'Too many failed login attempts. Try again in 15 minutes',
  { keyGenerator: loginKey, skipSuccessfulRequests: true },
);

/** Clears every count. For tests only. */
async function resetRateLimits() {
  await Promise.all(stores.map((s) => s.resetAll()));
}

module.exports = { LIMITS, authLimiter, refreshLimiter, loginLimiter, resetRateLimits };
