const prisma = require('../lib/prisma');
const { verifyAccessToken } = require('../lib/tokens');
const { describeForLog } = require('../middleware/errorHandler');
const { env } = require('../config/env');

/** A handshake refusal: the client's connect_error carries `message` and `data.code`. */
function refusal(code, message) {
  const err = new Error(message);
  err.data = { code };
  return err;
}

/**
 * Socket.io middleware: requires the access token in `auth.token` and, like requireAuth, loads
 * the user so a deleted account cannot connect. Sets socket.data.userId and socket.data.tokenExp
 * (seconds); events check the expiry, since a socket outlives its 15-minute token.
 */
async function authenticateSocket(socket, next) {
  const token = socket.handshake.auth?.token;
  if (typeof token !== 'string' || token === '') {
    return next(refusal('UNAUTHORIZED', 'Authentication required'));
  }

  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      return next(refusal('TOKEN_EXPIRED', 'Access token expired'));
    }
    return next(refusal('INVALID_TOKEN', 'Invalid access token'));
  }

  let user;
  try {
    user = await prisma.user.findUnique({ where: { id: payload.sub }, select: { id: true } });
  } catch (err) {
    if (env.NODE_ENV !== 'test') console.error(describeForLog(err));
    return next(refusal('INTERNAL_ERROR', 'Something went wrong'));
  }
  if (!user) return next(refusal('INVALID_TOKEN', 'Invalid access token'));

  socket.data.userId = user.id;
  socket.data.tokenExp = payload.exp;
  return next();
}

const msUntilTokenExpires = (socket) => socket.data.tokenExp * 1000 - Date.now();
const tokenExpired = (socket) => msUntilTokenExpires(socket) <= 0;

module.exports = { authenticateSocket, msUntilTokenExpires, tokenExpired };
