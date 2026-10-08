const rideService = require('../services/ride.service');
const { toRide } = require('../lib/serializers');

async function createRide(req, res) {
  const { ride, warnings } = await rideService.createRide(req.user.id, req.body);
  res.status(201).json({ ride: toRide(ride), warnings });
}

async function listMyRides(req, res) {
  const rides = await rideService.findRidesByDriver(req.user.id);
  res.json({ rides: rides.map(toRide) });
}

async function getRide(req, res) {
  const ride = await rideService.getRide(req.params.id);
  res.json({ ride: toRide(ride) });
}

module.exports = { createRide, listMyRides, getRide };
