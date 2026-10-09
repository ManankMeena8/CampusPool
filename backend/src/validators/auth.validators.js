const { z } = require('zod');
const { env } = require('../config/env');

const email = z.string().trim().toLowerCase().pipe(z.email().max(254));

const password = z
  .string()
  .min(8, 'must be at least 8 characters')
  .max(72, 'must be at most 72 characters')
  .regex(/[A-Za-z]/, 'must contain a letter')
  .regex(/\d/, 'must contain a number')
  // bcrypt silently ignores everything after 72 bytes, and multi-byte characters use several.
  .refine((v) => Buffer.byteLength(v, 'utf8') <= 72, 'must be at most 72 bytes');

const signupEmail = email.refine((v) => v.endsWith(`@${env.ALLOWED_EMAIL_DOMAIN}`), {
  message: `must be a @${env.ALLOWED_EMAIL_DOMAIN} address`,
});

const refreshToken = z.string().min(1).max(512);

const signupBody = z.object({
  name: z.string().trim().min(1).max(100),
  email: signupEmail,
  password,
});

const verifyOtpBody = z.object({
  email,
  code: z.string().regex(/^\d{6}$/, 'must be a 6-digit code'),
});

const resendOtpBody = z.object({ email });

const loginBody = z.object({
  email,
  password: z.string().min(1).max(200),
});

const refreshBody = z.object({ refreshToken });

module.exports = {
  signupEmail,
  password,
  signupBody,
  verifyOtpBody,
  resendOtpBody,
  loginBody,
  refreshBody,
};
