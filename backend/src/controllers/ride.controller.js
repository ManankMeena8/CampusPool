const rideService = require('../services/ride.service');
const { toRide } = require('../lib/serializers');

async function createRide(req, res) {
  const { ride, warnings } = await rideService.createRide(req.user.id, req.body);
  res.status(201).json({ ride: toRide(ride), warnings });
}

module.exports = { createRide };
