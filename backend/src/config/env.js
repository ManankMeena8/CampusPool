const path = require('path');
const dotenv = require('dotenv');
const { z } = require('zod');

dotenv.config({ path: path.resolve(__dirname, '../../.env'), quiet: true });

const splitOrigins = (value) =>
  value
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

function isOrigin(value) {
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && url.origin === value;
  } catch {
    return false;
  }
}

/** "Name <user@host>" or "user@host" as { name?, email }, or null when it is neither. */
function parseMailbox(value) {
  const match = value
    .trim()
    .match(/^(?:"?([^"<>]*?)"?\s*<([^<>\s]+@[^<>\s]+)>|([^<>\s]+@[^<>\s]+))$/);
  if (!match) return null;
  const email = match[2] ?? match[3];
  const name = match[1]?.trim();
  return name ? { name, email } : { email };
}

// Unset and empty both mean "not configured".
const optionalString = () =>
  z
    .string()
    .trim()
    .optional()
    .transform((v) => v || undefined);

// Runs a check even when other variables failed, so startup lists every problem at once. The
// checks only read fields that keep their type: strings, undefined, or their defaults.
const alwaysCheck = { when: () => true };

const schema = z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().positive().default(3000),
    // Comma-separated origins, or * (not in production). Unset or empty: * outside production.
    CORS_ORIGIN: z
      .string()
      .trim()
      .optional()
      .transform((v) => v || undefined),
    DATABASE_URL: z.string().min(1, 'is required'),
    // Direct (non-pooled) URL used only by scripts/migrate-deploy.js; unset: DATABASE_URL.
    DIRECT_URL: optionalString(),
    TEST_DATABASE_URL: z.string().min(1).optional(),
    JWT_ACCESS_SECRET: z.string().min(32, 'must be at least 32 characters'),
    ALLOWED_EMAIL_DOMAIN: z
      .string()
      .min(1, 'is required')
      .transform((v) => v.trim().toLowerCase().replace(/^@/, '')),
    // smtp: Nodemailer (local development). brevo: Brevo's HTTP API (Render's free plan blocks
    // outbound SMTP).
    EMAIL_PROVIDER: z.enum(['smtp', 'brevo']).default('smtp'),
    SMTP_HOST: optionalString(),
    SMTP_PORT: z.coerce.number().int().positive().default(587),
    SMTP_USER: z.string().optional(),
    SMTP_PASS: z.string().optional(),
    BREVO_API_KEY: optionalString(),
    MAIL_FROM: optionalString(),
    // Proxies in front of the API in production (Render), for the client IP. See app.js.
    TRUST_PROXY_HOPS: z.coerce.number().int().min(1).max(10).default(1),
    // 1 mounts GET /debug/client-ip, to check TRUST_PROXY_HOPS after a deploy. Off by default.
    DEBUG_CLIENT_IP: z
      .enum(['', '0', '1'])
      .default('0')
      .transform((v) => v === '1'),
    ROUTING_BASE_URL: z
      .url()
      .default('https://router.project-osrm.org')
      .transform((v) => v.replace(/\/+$/, '')),
    // Path to the Firebase service account JSON (kept outside the repo). Unset or empty: push
    // notifications are not sent.
    // notifications are not sent. Required in production.
    FIREBASE_SERVICE_ACCOUNT_PATH: optionalString(),
  })
  .refine((v) => v.NODE_ENV !== 'test' || v.TEST_DATABASE_URL, {
    path: ['TEST_DATABASE_URL'],
    message: 'is required when NODE_ENV=test',
  })
  .superRefine((v, ctx) => {
    const issue = (path, message) => ctx.addIssue({ code: 'custom', path: [path], message });
    if (v.EMAIL_PROVIDER === 'smtp' && !v.SMTP_HOST) {
      issue('SMTP_HOST', 'is required when EMAIL_PROVIDER=smtp');
    }
    if (v.EMAIL_PROVIDER === 'brevo' && !v.BREVO_API_KEY) {
      issue('BREVO_API_KEY', 'is required when EMAIL_PROVIDER=brevo');
    }
    // Not quoted: the message must never echo a value.
    if (v.MAIL_FROM && !parseMailbox(v.MAIL_FROM)) {
      issue('MAIL_FROM', 'must look like "CampusPool <sender@example.com>"');
    }
  }, alwaysCheck)
  .superRefine((v, ctx) => {
    if (v.NODE_ENV !== 'production') return;
    const required = (path) =>
      ctx.addIssue({
        code: 'custom',
        path: [path],
        message: 'is required when NODE_ENV=production',
      });
    // The default sender is not a real address; Brevo only sends from a verified one.
    if (!v.MAIL_FROM) required('MAIL_FROM');
    if (!v.FIREBASE_SERVICE_ACCOUNT_PATH) required('FIREBASE_SERVICE_ACCOUNT_PATH');

    const issue = (message) => ctx.addIssue({ code: 'custom', path: ['CORS_ORIGIN'], message });
    if (!v.CORS_ORIGIN) return required('CORS_ORIGIN');
    for (const origin of splitOrigins(v.CORS_ORIGIN)) {
      if (origin === '*')
        return issue('must list the allowed origins; * is not allowed in production');
      // cors compares exact strings: "https://x.app/" or a path would never match a browser.
      if (!isOrigin(origin))
        return issue(`"${origin}" is not an origin like https://app.example.com`);
    }
  }, alwaysCheck)
  .transform((v) => ({
    ...v,
    CORS_ORIGIN: v.CORS_ORIGIN ?? '*',
    MAIL_FROM: v.MAIL_FROM ?? 'CampusPool <no-reply@campuspool.local>',
  }));

function loadEnv(source = process.env, exit = (code) => process.exit(code)) {
  const result = schema.safeParse(source);
  if (!result.success) {
    const lines = result.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`);
    console.error(`Invalid or missing environment variables:\n${lines.join('\n')}`);
    console.error('See backend/.env.example for the full list.');
    exit(1);
    return null;
  }
  const env = result.data;
  if (env.NODE_ENV === 'test') {
    // Tests must never touch the dev database.
    env.DATABASE_URL = env.TEST_DATABASE_URL;
    process.env.DATABASE_URL = env.TEST_DATABASE_URL;
  }
  return env;
}

module.exports = { env: loadEnv(), loadEnv, splitOrigins, parseMailbox };
