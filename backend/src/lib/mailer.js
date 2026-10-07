const nodemailer = require('nodemailer');
const { env } = require('../config/env');
const AppError = require('./AppError');

let transporter;

function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: env.SMTP_HOST,
      port: env.SMTP_PORT,
      secure: env.SMTP_PORT === 465,
      auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined,
    });
  }
  return transporter;
}

async function sendOtpEmail(to, code, ttlMinutes) {
  try {
    await getTransporter().sendMail({
      from: env.MAIL_FROM,
      to,
      subject: 'Your CampusPool verification code',
      text: `Your CampusPool verification code is ${code}. It expires in ${ttlMinutes} minutes.`,
    });
  } catch (err) {
    if (env.NODE_ENV !== 'test') console.error('Failed to send OTP email:', err.message);
    throw new AppError('EMAIL_SEND_FAILED', 'Could not send the verification email', 503);
  }
}

module.exports = { sendOtpEmail };
