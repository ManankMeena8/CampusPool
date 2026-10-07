const prisma = require('../lib/prisma');

function updateUser(id, data) {
  return prisma.user.update({ where: { id }, data });
}

module.exports = { updateUser };
