const AppError = require('../lib/AppError');
const asyncHandler = require('../lib/asyncHandler');
const prisma = require('../lib/prisma');
const { verifyAccessToken } = require('../lib/tokens');

/** Requires `Authorization: Bearer <accessToken>`; sets req.user to the current DB user. */
module.exports = asyncHandler(async (req, _res, next) => {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) {
    throw new AppError('UNAUTHORIZED', 'Authentication required', 401);
  }

  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      throw new AppError('TOKEN_EXPIRED', 'Access token expired', 401);
    }
    throw new AppError('INVALID_TOKEN', 'Invalid access token', 401);
  }

  // Load the user so role changes and deletions take effect before the token expires.
  const user = await prisma.user.findUnique({ where: { id: payload.sub } });
  if (!user) throw new AppError('INVALID_TOKEN', 'Invalid access token', 401);

  req.user = user;
  next();
});
