const AppError = require('../lib/AppError');

const PARTS = ['params', 'query', 'body'];

/**
 * Validates req.params, req.query and req.body against zod schemas.
 * Parsed (typed, trimmed, defaulted) values replace the raw ones, so handlers only see valid data.
 * Failures become a 400 in the standard error format.
 *
 *   router.post('/x', validate({ body: schema }), asyncHandler(controller))
 */
function validate(schemas = {}) {
  return (req, _res, next) => {
    const problems = [];
    for (const part of PARTS) {
      const schema = schemas[part];
      if (!schema) continue;
      const result = schema.safeParse(req[part] ?? {});
      if (result.success) {
        req[part] = result.data;
      } else {
        for (const issue of result.error.issues) {
          const field = [part, ...issue.path].join('.');
          problems.push(`${field}: ${issue.message}`);
        }
      }
    }
    if (problems.length) {
      return next(new AppError('VALIDATION_ERROR', problems.join('; '), 400));
    }
    next();
  };
}

module.exports = validate;
