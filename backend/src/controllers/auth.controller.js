const authService = require('../services/auth.service');

async function signup(req, res) {
  const { email } = await authService.signup(req.body);
  res.status(201).json({ message: 'Verification code sent', email });
}

async function verifyOtp(req, res) {
  res.json(await authService.verifyOtp(req.body));
}

async function resendOtp(req, res) {
  await authService.resendOtp(req.body);
  res.json({ message: 'If the account is awaiting verification, a new code has been sent' });
}

async function login(req, res) {
  res.json(await authService.login(req.body));
}

async function refresh(req, res) {
  res.json(await authService.refresh(req.body));
}

async function logout(req, res) {
  await authService.logout(req.body);
  res.status(204).end();
}

module.exports = { signup, verifyOtp, resendOtp, login, refresh, logout };
