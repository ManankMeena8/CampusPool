const prisma = require('../lib/prisma');
const AppError = require('../lib/AppError');
const { locations, locationThrottle } = require('../realtime/hub');
const { LOCATION_INTERVAL_MS } = require('../realtime/throttle');

async function findRide(rideId) {
  const ride = await prisma.ride.findUnique({
    where: { id: rideId },
    select: { id: true, driverId: true, status: true },
  });
  if (!ride) throw new AppError('RIDE_NOT_FOUND', 'Ride not found', 404);
  return ride;
}

/** The ride, if `userId` drives it or has an ACCEPTED booking on it; 403 otherwise. */
async function assertCanFollow(userId, rideId) {
  const ride = await findRide(rideId);
  if (ride.driverId === userId) return ride;
  const booking = await prisma.booking.findFirst({
    where: { rideId, riderId: userId, status: 'ACCEPTED' },
    select: { id: true },
  });
  if (!booking) {
    throw new AppError(
      'FORBIDDEN',
      'Only the driver and riders with an accepted booking can follow this ride',
      403,
    );
  }
  return ride;
}

/** The last stored location, only while the ride is IN_PROGRESS. */
async function lastLocation(ride) {
  return ride.status === 'IN_PROGRESS' ? locations.get(ride.id) : null;
}

/**
 * Stores the driver's location for an IN_PROGRESS ride they drive and returns it. Throttled per
 * driver before any query, so a flood of updates never reaches the database.
 */
async function recordLocation(userId, { rideId, lat, lng, heading, speed }) {
  if (!locationThrottle.tryAcquire(userId)) {
    throw new AppError(
      'THROTTLED',
      `At most one location update every ${LOCATION_INTERVAL_MS / 1000} seconds`,
      429,
    );
  }
  const ride = await findRide(rideId);
  if (ride.driverId !== userId) {
    throw new AppError('FORBIDDEN', 'Only the driver can send locations for this ride', 403);
  }
  if (ride.status !== 'IN_PROGRESS') {
    throw new AppError('RIDE_NOT_IN_PROGRESS', `This ride is ${ride.status}`, 409);
  }
  const location = { lat, lng, heading, speed, recordedAt: new Date(Date.now()).toISOString() };
  await locations.set(rideId, location);
  return location;
}

module.exports = { assertCanFollow, lastLocation, recordLocation };
