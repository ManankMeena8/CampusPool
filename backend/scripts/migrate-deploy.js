// Applies pending migrations (prisma migrate deploy). Neon's pooled (-pooler) URL suits the app,
// but migrations need a direct connection: DIRECT_URL is used when set, else DATABASE_URL.
// Runs before the server in Render's start command; prints neither URL.
const { spawnSync } = require('child_process');

function migrationDatabaseUrl(env) {
  return env.DIRECT_URL ?? env.DATABASE_URL;
}

function main() {
  const { env } = require('../src/config/env'); // validates env (exits with a list on failure)
  console.log(
    `[migrate] applying migrations through ${env.DIRECT_URL ? 'DIRECT_URL' : 'DATABASE_URL'}`,
  );
  // The CLI from node_modules, without npx or a shell: nothing is downloaded at start time.
  const result = spawnSync(
    process.execPath,
    [require.resolve('prisma/build/index.js'), 'migrate', 'deploy'],
    { stdio: 'inherit', env: { ...process.env, DATABASE_URL: migrationDatabaseUrl(env) } },
  );
  process.exit(result.status ?? 1);
}

if (require.main === module) main();

module.exports = { migrationDatabaseUrl };
