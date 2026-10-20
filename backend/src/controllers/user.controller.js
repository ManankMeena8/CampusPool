const userService = require('../services/user.service');
const { toPublicUser } = require('../lib/serializers');

async function getMe(req, res) {
  res.json({ user: toPublicUser(req.user) });
}

async function updateMe(req, res) {
  const user = await userService.updateUser(req.user.id, req.body);
  res.json({ user: toPublicUser(user) });
}

async function setFcmToken(req, res) {
  await userService.setFcmToken(req.user.id, req.body.token);
  res.status(204).end();
}

module.exports = { getMe, updateMe, setFcmToken };
