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

const body = (code, message) => ({ error: { code, message } });

/** Maps any error to { status, body } in the API's error format. Shared with Socket.io acks. */
function toErrorResponse(err) {
  if (err instanceof AppError) return { status: err.status, body: body(err.code, err.message) };
  if (err instanceof ZodError) {
    const message = err.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
    return { status: 400, body: body('VALIDATION_ERROR', message) };
  }
  if (err.type === 'entity.parse.failed') {
    return { status: 400, body: body('INVALID_JSON', 'Malformed JSON body') };
  }
  if (err.type === 'entity.too.large') {
    return { status: 413, body: body('PAYLOAD_TOO_LARGE', 'Request body too large') };
  }
  // Other client errors raised by Express/body-parser (bad URL encoding, unsupported charset...).
  if (Number.isInteger(err.status) && err.status >= 400 && err.status < 500) {
    return { status: err.status, body: body('BAD_REQUEST', 'Malformed request') };
  }
  if (env.NODE_ENV !== 'test') console.error(describeForLog(err));
  return { status: 500, body: body('INTERNAL_ERROR', 'Something went wrong') };
}

// Express identifies error middleware by its 4-argument signature.
function errorHandler(err, _req, res, _next) {
  const { status, body: payload } = toErrorResponse(err);
  res.status(status).json(payload);
}

module.exports = { notFound, errorHandler, toErrorResponse, describeForLog };
