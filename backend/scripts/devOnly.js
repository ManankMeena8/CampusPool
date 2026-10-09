// Loads and validates env (.env included), then stops unless NODE_ENV is explicitly development.
// env.js defaults a missing NODE_ENV to development; these scripts do not trust that default,
// and the npm scripts deliberately do not set NODE_ENV, so a host configured as production or
// test (whose DATABASE_URL is not the dev database) can never run them.
const { env } = require('../src/config/env');

function assertDevelopment(scriptName) {
  if (process.env.NODE_ENV !== 'development') {
    console.error(
      `${scriptName} only runs with NODE_ENV=development (got ${process.env.NODE_ENV ?? 'unset'}).`,
    );
    process.exit(1);
  }
  return env;
}

module.exports = { assertDevelopment };
