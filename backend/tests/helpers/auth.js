const request = require('supertest');
const { sendMail } = require('nodemailer');
const app = require('../../src/app');
const prisma = require('../../src/lib/prisma');

const DOMAIN = process.env.ALLOWED_EMAIL_DOMAIN;
const PASSWORD = 'Passw0rdTest';

/** Wipes app tables. Safe: NODE_ENV=test points Prisma at TEST_DATABASE_URL only. */
async function resetDb() {
  await prisma.$executeRaw`TRUNCATE TABLE "Ride", "RefreshToken", "EmailOtp", "User" CASCADE`;
  sendMail.mockClear();
}

function emailFor(label) {
  return `${label}@${DOMAIN}`;
}

/** Reads the 6-digit code from the most recent (mocked) email sent to `email`. */
function lastOtpCode(email) {
  const calls = sendMail.mock.calls.filter(([mail]) => mail.to === email);
  if (calls.length === 0) throw new Error(`No email was sent to ${email}`);
  return calls[calls.length - 1][0].text.match(/\b(\d{6})\b/)[1];
}

/** Makes existing codes look `ms` old, so the resend cooldown has passed. */
function ageOtps(email, ms = 61 * 1000) {
  return prisma.emailOtp.updateMany({
    where: { email },
    data: { createdAt: new Date(Date.now() - ms) },
  });
}

function signup(overrides = {}) {
  return request(app)
    .post('/auth/signup')
    .send({ name: 'Test User', email: emailFor('user'), password: PASSWORD, ...overrides });
}

/** Signs up and verifies; resolves to the verify-otp response body (tokens + user). */
async function createVerifiedUser(email = emailFor('user'), overrides = {}) {
  await signup({ email, ...overrides }).expect(201);
  const res = await request(app)
    .post('/auth/verify-otp')
    .send({ email, code: lastOtpCode(email) })
    .expect(200);
  return res.body;
}

module.exports = {
  app,
  prisma,
  sendMail,
  PASSWORD,
  resetDb,
  emailFor,
  lastOtpCode,
  ageOtps,
  signup,
  createVerifiedUser,
};
