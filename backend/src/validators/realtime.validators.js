const { z } = require('zod');

const joinRidePayload = z.strictObject({ rideId: z.uuid() });

// GPS fixes may lack a heading (degrees) or speed (m/s), so both may be missing or null.
const locationUpdatePayload = z.strictObject({
  rideId: z.uuid(),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  heading: z
    .number()
    .min(0)
    .lt(360)
    .nullish()
    .transform((v) => v ?? null),
  speed: z
    .number()
    .min(0)
    .max(100)
    .nullish()
    .transform((v) => v ?? null),
});

module.exports = { joinRidePayload, locationUpdatePayload };
