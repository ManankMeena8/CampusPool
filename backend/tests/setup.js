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

const LOCAL_HOSTS = ['localhost', '127.0.0.1', '[::1]'];
const LOCAL_TEST_DB = '/campuspool_test';

/** host:port/database, ignoring credentials and query params. */
function dbIdentity(url) {
  const u = new URL(url);
  return `${u.hostname.toLowerCase()}:${u.port || '5432'}${u.pathname}`;
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

  // Read the dev URL from the file itself: process.env.DATABASE_URL already holds .env.test's.
  const envFile = path.resolve(__dirname, '../.env');
  const devUrl = fs.existsSync(envFile)
    ? dotenv.parse(fs.readFileSync(envFile)).DATABASE_URL
    : undefined;
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

assertTestDatabase();
