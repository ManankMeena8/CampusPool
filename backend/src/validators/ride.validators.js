const { z } = require('zod');
const { distanceMeters } = require('../lib/geo');

const MINUTE_MS = 60 * 1000;
const MIN_LEAD_MS = 15 * MINUTE_MS;
const MAX_LEAD_MS = 7 * 24 * 60 * MINUTE_MS;
const MIN_TRIP_METERS = 200;

const place = z.strictObject({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  address: z.string().trim().min(1).max(200),
});

const createRideBody = z
  .strictObject({
    start: place,
    end: place,
    departureTime: z.iso.datetime({ offset: true }).transform((s) => new Date(s)),
    seats: z.number().int().min(1).max(6),
    pricePerSeat: z.number().int().min(0).max(1000).default(0),
    notes: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => v || null),
  })
  .superRefine((v, ctx) => {
    // zod still runs this when fields above failed; only check what parsed cleanly.
    const isPoint = (p) => Number.isFinite(p?.lat) && Number.isFinite(p?.lng);
    if (isPoint(v.start) && isPoint(v.end) && distanceMeters(v.start, v.end) <= MIN_TRIP_METERS) {
      ctx.addIssue({
        code: 'custom',
        path: ['end'],
        message: `must be more than ${MIN_TRIP_METERS} m from start`,
      });
    }
    if (!(v.departureTime instanceof Date)) return;
    // Date.now() (not new Date()) so tests can pin the clock with jest.spyOn.
    const lead = v.departureTime.getTime() - Date.now();
    if (lead < MIN_LEAD_MS) {
      ctx.addIssue({
        code: 'custom',
        path: ['departureTime'],
        message: 'must be at least 15 minutes from now',
      });
    } else if (lead > MAX_LEAD_MS) {
      ctx.addIssue({
        code: 'custom',
        path: ['departureTime'],
        message: 'must be at most 7 days from now',
      });
    }
  });

module.exports = { createRideBody, MIN_LEAD_MS, MAX_LEAD_MS, MIN_TRIP_METERS };
