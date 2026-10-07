/** The only user fields that may leave the API. Never add passwordHash, fcmToken or token hashes. */
function toPublicUser(user) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    phone: user.phone,
    role: user.role,
    isVerified: user.isVerified,
    ratingAvg: user.ratingAvg,
    ratingCount: user.ratingCount,
    createdAt: user.createdAt,
    updatedAt: user.updatedAt,
  };
}

module.exports = { toPublicUser };
