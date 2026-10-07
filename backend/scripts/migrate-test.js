require('../tests/setup'); // hermetic auth/mail defaults so env validation passes
// Applies migrations to TEST_DATABASE_URL (env.js swaps it in as DATABASE_URL under NODE_ENV=test).
const { spawnSync } = require('child_process');
const { env } = require('../src/config/env');

const result = spawnSync('npx', ['prisma', 'migrate', 'deploy'], {
  stdio: 'inherit',
  shell: true,
  env: { ...process.env, DATABASE_URL: env.DATABASE_URL },
});
process.exit(result.status ?? 1);
