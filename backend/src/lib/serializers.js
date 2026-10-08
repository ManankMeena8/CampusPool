const { fromGeoJsonPoint, fromGeoJsonLine } = require('./geo');

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

/**
 * Shapes a row from ride.service (geo columns as GeoJSON) for the API: points become {lat, lng}
 * and the route an array of {lat, lng} (or null). List rows have no routeLine, so no `route` key.
 * The driver is exposed by name and rating only.
 */
function toRide(row) {
  const ride = {
    id: row.id,
    status: row.status,
    start: { ...fromGeoJsonPoint(row.startPoint), address: row.startAddress },
    end: { ...fromGeoJsonPoint(row.endPoint), address: row.endAddress },
    distanceMeters: row.distanceMeters,
    durationSeconds: row.durationSeconds,
    departureTime: row.departureTime,
    seatsTotal: row.seatsTotal,
    seatsAvailable: row.seatsAvailable,
    pricePerSeat: row.pricePerSeat,
    notes: row.notes,
    driver: {
      id: row.driverId,
      name: row.driverName,
      ratingAvg: row.driverRatingAvg,
      ratingCount: row.driverRatingCount,
    },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
  if ('routeLine' in row) ride.route = fromGeoJsonLine(row.routeLine);
  return ride;
}

module.exports = { toPublicUser, toRide };
