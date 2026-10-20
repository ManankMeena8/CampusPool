const { z } = require('zod');
const AppError = require('../lib/AppError');

const PARTS = ['params', 'query', 'body'];

// A part a route does not declare must be empty (a missing body counts as empty).
const NOTHING = z.strictObject({});

/**
 * Validates req.params, req.query and req.body against zod schemas. A part without a schema
 * must be empty, so validate({}) means "this endpoint takes no input" and unexpected fields
 * are refused rather than silently ignored.
 * Parsed (typed, trimmed, defaulted) values replace the raw ones, so handlers only see valid data.
 * Failures become a 400 in the standard error format.
 *
 *   router.post('/x', validate({ body: schema }), asyncHandler(controller))
 */
function validate(schemas = {}) {
  return (req, _res, next) => {
    const problems = [];
    for (const part of PARTS) {
      const schema = schemas[part] ?? NOTHING;
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
