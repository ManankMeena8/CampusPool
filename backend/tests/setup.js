const fs = require('fs');
const path = require('path');
const dotenv = require('dotenv');

// Test database settings. Precedence: shell variables, then .env.test, then .env (which
// src/config/env.js loads later; dotenv never overrides a variable that is already set).
dotenv.config({ path: path.resolve(__dirname, '../.env.test'), quiet: true });

process.env.NODE_ENV = 'test';

// Hermetic auth/mail settings so tests do not depend on the developer's .env.
process.env.JWT_ACCESS_SECRET = 'test-secret-test-secret-test-secret-123456';
process.env.ALLOWED_EMAIL_DOMAIN = 'campus.test';
process.env.EMAIL_PROVIDER = 'smtp'; // nodemailer is mocked; Brevo tests build their own mailer
process.env.SMTP_HOST = 'smtp.test.invalid';
process.env.BREVO_API_KEY = '';
process.env.MAIL_FROM = 'CampusPool <no-reply@campus.test>';
// Routing calls are always mocked; this host can never resolve.
process.env.ROUTING_BASE_URL = 'https://osrm.test.invalid';
// Push notifications are never sent from tests, whatever .env says (empty counts as unset, and
// dotenv does not override a variable that is already set).
process.env.FIREBASE_SERVICE_ACCOUNT_PATH = '';
// The relay and the worker never start with the app in tests: the job tests build their own.
process.env.ENABLE_JOBS = '0';

const LOCAL_HOSTS = ['localhost', '127.0.0.1', '[::1]'];
const LOCAL_TEST_DB = '/campuspool_test';

/** host:port/database, ignoring credentials and query params. */
function dbIdentity(url) {
  const u = new URL(url);
  return `${u.hostname.toLowerCase()}:${u.port || '5432'}${u.pathname}`;
}

/**
 * A variable as backend/.env (the dev settings) has it. Read from the file itself: process.env
 * already holds .env.test's values.
 */
function envFileValue(name) {
  const envFile = path.resolve(__dirname, '../.env');
  return fs.existsSync(envFile) ? dotenv.parse(fs.readFileSync(envFile))[name] : undefined;
}

function refuse(reason) {
  throw new Error(`Refusing to run tests: ${reason}. See backend/README.md ("Tests").`);
}

/**
 * Tests TRUNCATE every table, so they must only ever reach a test database: the local Docker
 * one, or a remote one (the Neon test branch) explicitly allowed with ALLOW_REMOTE_TEST_DB=1.
 */
function assertTestDatabase() {
  const testUrl = process.env.TEST_DATABASE_URL;
  if (!testUrl) refuse('TEST_DATABASE_URL is not set (copy .env.test.example to .env.test)');
  let target;
  try {
    target = new URL(testUrl);
  } catch {
    refuse('TEST_DATABASE_URL is not a valid URL');
  }

  const devUrl = envFileValue('DATABASE_URL');
  if (devUrl && dbIdentity(devUrl) === dbIdentity(testUrl)) {
    refuse('TEST_DATABASE_URL is the dev DATABASE_URL from backend/.env');
  }

  if (LOCAL_HOSTS.includes(target.hostname)) {
    if (target.pathname !== LOCAL_TEST_DB) {
      refuse(`a local test database must be named ${LOCAL_TEST_DB.slice(1)}`);
    }
  } else if (process.env.ALLOW_REMOTE_TEST_DB !== '1') {
    refuse(
      `TEST_DATABASE_URL is remote (${target.hostname}); set ALLOW_REMOTE_TEST_DB=1 if it is a test database`,
    );
  }

  // The URL Prisma connects to is exactly the one checked above (src/config/env.js does the same).
  process.env.DATABASE_URL = testUrl;
}

/** host:port/db of a Redis URL, ignoring credentials. */
function redisIdentity(url) {
  const u = new URL(url);
  const db = u.pathname.replace(/^\//, '') || '0';
  return `${u.hostname.toLowerCase()}:${u.port || '6379'}/${db}`;
}

/**
 * The job tests run FLUSHDB, so they must only reach a test Redis: a local one that is not the
 * database `npm run dev` uses, or a remote one explicitly allowed with ALLOW_REMOTE_TEST_DB=1.
 * REDIS_URL must come from .env.test or the shell: left unset, src/config/env.js would load the
 * dev one from .env.
 */
function assertTestRedis(devUrl = envFileValue('REDIS_URL')) {
  const testUrl = process.env.REDIS_URL;
  if (!testUrl) refuse('REDIS_URL is not set (copy it from .env.test.example to .env.test)');
  let target;
  try {
    target = new URL(testUrl);
  } catch {
    refuse('REDIS_URL is not a valid URL');
  }
  if (!['redis:', 'rediss:'].includes(target.protocol)) refuse('REDIS_URL is not a redis:// URL');

  let devIdentity;
  try {
    devIdentity = devUrl && redisIdentity(devUrl);
  } catch {
    devIdentity = undefined; // an unusable dev URL cannot be the one under test
  }
  if (devIdentity && devIdentity === redisIdentity(testUrl)) {
    refuse('REDIS_URL is the dev REDIS_URL from backend/.env (tests use db 0, dev db 1)');
  }
  if (!LOCAL_HOSTS.includes(target.hostname) && process.env.ALLOW_REMOTE_TEST_DB !== '1') {
    refuse(
      `REDIS_URL is remote (${target.hostname}); set ALLOW_REMOTE_TEST_DB=1 if it is a test Redis`,
    );
  }
}

assertTestDatabase();
assertTestRedis();

module.exports = { assertTestDatabase, assertTestRedis };
