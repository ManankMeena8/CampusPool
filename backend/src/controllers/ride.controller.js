const rideService = require('../services/ride.service');
const { toRide, toRideSearchResult } = require('../lib/serializers');

async function createRide(req, res) {
  const { ride, warnings } = await rideService.createRide(req.user.id, req.body);
  res.status(201).json({ ride: toRide(ride), warnings });
}

async function listMyRides(req, res) {
  const rides = await rideService.findRidesByDriver(req.user.id);
  res.json({ rides: rides.map(toRide) });
}

async function searchRides(req, res) {
  const { rides, hasMore } = await rideService.searchRides(req.user.id, req.query);
  const { limit, offset } = req.query;
  res.json({ rides: rides.map(toRideSearchResult), limit, offset, hasMore });
}

async function getRide(req, res) {
  const ride = await rideService.getRide(req.params.id);
  res.json({ ride: toRide(ride) });
}

async function cancelRide(req, res) {
  const ride = await rideService.cancelRide(req.user.id, req.params.id);
  res.json({ ride: toRide(ride) });
}

module.exports = { createRide, listMyRides, searchRides, getRide, cancelRide };
