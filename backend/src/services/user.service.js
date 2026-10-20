const prisma = require('../lib/prisma');

function updateUser(id, data) {
  return prisma.user.update({ where: { id }, data });
}

/**
 * Stores the device's FCM token on the user. A token belongs to one device, so it is taken off
 * any other user first: otherwise a phone shared between accounts would keep receiving the
 * previous account's notifications.
 */
function setFcmToken(id, token) {
  return prisma.$transaction([
    prisma.user.updateMany({
      where: { fcmToken: token, id: { not: id } },
      data: { fcmToken: null },
    }),
    prisma.user.update({ where: { id }, data: { fcmToken: token } }),
  ]);
}

module.exports = { updateUser, setFcmToken };
