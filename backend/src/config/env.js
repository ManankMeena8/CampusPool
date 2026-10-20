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
    TEST_DATABASE_URL: z.string().min(1).optional(),
    JWT_ACCESS_SECRET: z.string().min(32, 'must be at least 32 characters'),
    ALLOWED_EMAIL_DOMAIN: z
      .string()
      .min(1, 'is required')
      .transform((v) => v.trim().toLowerCase().replace(/^@/, '')),
    SMTP_HOST: z.string().min(1, 'is required'),
    SMTP_PORT: z.coerce.number().int().positive().default(587),
    SMTP_USER: z.string().optional(),
    SMTP_PASS: z.string().optional(),
    MAIL_FROM: z.string().min(1).default('CampusPool <no-reply@campuspool.local>'),
    ROUTING_BASE_URL: z
      .url()
      .default('https://router.project-osrm.org')
      .transform((v) => v.replace(/\/+$/, '')),
    // Path to the Firebase service account JSON (kept outside the repo). Unset or empty: push
    // notifications are not sent.
    FIREBASE_SERVICE_ACCOUNT_PATH: z
      .string()
      .trim()
      .optional()
      .transform((v) => v || undefined),
  })
  .refine((v) => v.NODE_ENV !== 'test' || v.TEST_DATABASE_URL, {
    path: ['TEST_DATABASE_URL'],
    message: 'is required when NODE_ENV=test',
  })
  .superRefine((v, ctx) => {
    if (v.NODE_ENV !== 'production') return;
    const issue = (message) => ctx.addIssue({ code: 'custom', path: ['CORS_ORIGIN'], message });
    if (!v.CORS_ORIGIN) return issue('is required when NODE_ENV=production');
    for (const origin of splitOrigins(v.CORS_ORIGIN)) {
      if (origin === '*')
        return issue('must list the allowed origins; * is not allowed in production');
      // cors compares exact strings: "https://x.app/" or a path would never match a browser.
      if (!isOrigin(origin))
        return issue(`"${origin}" is not an origin like https://app.example.com`);
    }
  })
  .transform((v) => ({ ...v, CORS_ORIGIN: v.CORS_ORIGIN ?? '*' }));

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

module.exports = { env: loadEnv(), loadEnv, splitOrigins };
