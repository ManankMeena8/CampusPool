const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { env } = require('../config/env');

const ACCESS_TOKEN_TTL_SECONDS = 15 * 60;
const REFRESH_TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function signAccessToken(user) {
  return jwt.sign({ sub: user.id, role: user.role }, env.JWT_ACCESS_SECRET, {
    algorithm: 'HS256',
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
  });
}

/** Throws jsonwebtoken errors (TokenExpiredError, JsonWebTokenError) for the caller to map. */
function verifyAccessToken(token) {
  return jwt.verify(token, env.JWT_ACCESS_SECRET, { algorithms: ['HS256'] });
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

/** Refresh tokens are opaque random strings; only their SHA-256 is stored. */
function generateRefreshToken() {
  const token = crypto.randomBytes(48).toString('base64url');
  return { token, tokenHash: sha256(token) };
}

module.exports = {
  ACCESS_TOKEN_TTL_SECONDS,
  REFRESH_TOKEN_TTL_MS,
  signAccessToken,
  verifyAccessToken,
  sha256,
  generateRefreshToken,
};
