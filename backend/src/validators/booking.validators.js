const { z } = require('zod');
const { place } = require('./ride.validators');

const createBookingBody = z.strictObject({
  pickup: place,
  drop: place,
  seats: z.number().int().min(1).max(6).default(1),
});

const bookingIdParams = z.strictObject({ id: z.uuid() });

module.exports = { createBookingBody, bookingIdParams };
