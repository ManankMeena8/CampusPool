const nodemailer = require('nodemailer');
const { env, parseMailbox } = require('../config/env');
const AppError = require('./AppError');

const BREVO_URL = 'https://api.brevo.com/v3/smtp/email';
const BREVO_TIMEOUT_MS = 10000;

/*
 * OTP emails, through the provider EMAIL_PROVIDER selects: smtp (Nodemailer, for local
 * development) or brevo (Brevo's HTTP API, for Render, whose free plan blocks outbound SMTP).
 * Both send the same message. Logs never include the API key, the code or a response body.
 */

function otpMessage(code, ttlMinutes) {
  return {
    subject: 'Your CampusPool verification code',
    text: `Your CampusPool verification code is ${code}. It expires in ${ttlMinutes} minutes.`,
  };
}

function smtpSender(config) {
  let transporter;
  return async (to, { subject, text }) => {
    transporter ??= nodemailer.createTransport({
      host: config.SMTP_HOST,
      port: config.SMTP_PORT,
      secure: config.SMTP_PORT === 465,
      auth: config.SMTP_USER ? { user: config.SMTP_USER, pass: config.SMTP_PASS } : undefined,
    });
    await transporter.sendMail({ from: config.MAIL_FROM, to, subject, text });
  };
}

function brevoSender(config) {
  return async (to, { subject, text }) => {
    let res;
    try {
      res = await fetch(BREVO_URL, {
        method: 'POST',
        headers: {
          'api-key': config.BREVO_API_KEY,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify({
          sender: parseMailbox(config.MAIL_FROM),
          to: [{ email: to }],
          subject,
          textContent: text,
        }),
        signal: AbortSignal.timeout(BREVO_TIMEOUT_MS),
      });
    } catch (err) {
      throw new Error(
        err?.name === 'TimeoutError'
          ? `Brevo timed out after ${BREVO_TIMEOUT_MS} ms`
          : 'Brevo unreachable',
      );
    }
    if (!res.ok) {
      // Brevo's error code (e.g. "unauthorized") says why, without echoing the request.
      const body = await res.json().catch(() => ({}));
      const reason = typeof body.code === 'string' ? `, ${body.code}` : '';
      throw new Error(`Brevo answered ${res.status}${reason}`);
    }
  };
}

function createMailer(config = env) {
  const send = config.EMAIL_PROVIDER === 'brevo' ? brevoSender(config) : smtpSender(config);

  async function sendOtpEmail(to, code, ttlMinutes) {
    try {
      await send(to, otpMessage(code, ttlMinutes));
    } catch (err) {
      if (config.NODE_ENV !== 'test') console.error('Failed to send OTP email:', err.message);
      throw new AppError('EMAIL_SEND_FAILED', 'Could not send the verification email', 503);
    }
  }

  return { sendOtpEmail };
}

module.exports = { ...createMailer(), createMailer, BREVO_URL, BREVO_TIMEOUT_MS };
