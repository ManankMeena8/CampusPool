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

/** A search result: the ride plus how far its ends are from the rider's pickup and drop-off. */
function toRideSearchResult(row) {
  return {
    ...toRide(row),
    pickupDistanceMeters: row.pickupDistanceMeters,
    dropDistanceMeters: row.dropDistanceMeters,
  };
}

/**
 * Shapes a row from booking.service for the API. Pickup and drop points become {lat, lng,
 * address}. Rows listed for the driver carry the rider by name and rating only; rows listed for
 * the rider carry their ride.
 */
function toBooking(row) {
  const booking = {
    id: row.id,
    rideId: row.rideId,
    status: row.status,
    seats: row.seats,
    pickup: { ...fromGeoJsonPoint(row.pickupPoint), address: row.pickupAddress },
    drop: { ...fromGeoJsonPoint(row.dropPoint), address: row.dropAddress },
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
  if ('riderName' in row) {
    booking.rider = {
      id: row.riderId,
      name: row.riderName,
      ratingAvg: row.riderRatingAvg,
      ratingCount: row.riderRatingCount,
    };
  }
  if (row.ride) booking.ride = toRide(row.ride);
  return booking;
}

module.exports = { toPublicUser, toRide, toRideSearchResult, toBooking };
