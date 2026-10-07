const { ZodError } = require('zod');
const AppError = require('../lib/AppError');
const { env } = require('../config/env');

function notFound(req, _res, next) {
  next(new AppError('NOT_FOUND', `Route ${req.method} ${req.originalUrl} not found`, 404));
}

/**
 * Prisma error messages embed the failing query's arguments, which here can include password
 * hashes, OTP hashes and emails. Log only the error type and code for those.
 */
function describeForLog(err) {
  if (typeof err?.name === 'string' && err.name.startsWith('PrismaClient')) {
    return `${err.name}${err.code ? ` (${err.code})` : ''}: details omitted from logs`;
  }
  return err;
}

// Express identifies error middleware by its 4-argument signature.
function errorHandler(err, _req, res, _next) {
  if (err instanceof AppError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message } });
  }
  if (err instanceof ZodError) {
    return res.status(400).json({
      error: {
        code: 'VALIDATION_ERROR',
        message: err.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; '),
      },
    });
  }
  if (err.type === 'entity.parse.failed') {
    return res
      .status(400)
      .json({ error: { code: 'INVALID_JSON', message: 'Malformed JSON body' } });
  }
  if (err.type === 'entity.too.large') {
    return res
      .status(413)
      .json({ error: { code: 'PAYLOAD_TOO_LARGE', message: 'Request body too large' } });
  }
  // Other client errors raised by Express/body-parser (bad URL encoding, unsupported charset...).
  if (Number.isInteger(err.status) && err.status >= 400 && err.status < 500) {
    return res
      .status(err.status)
      .json({ error: { code: 'BAD_REQUEST', message: 'Malformed request' } });
  }
  if (env.NODE_ENV !== 'test') console.error(describeForLog(err));
  return res
    .status(500)
    .json({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
}

module.exports = { notFound, errorHandler, describeForLog };
