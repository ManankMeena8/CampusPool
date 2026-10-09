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

const rideIdParams = z.strictObject({ id: z.uuid() });

const MAX_SEARCH_WINDOW_MS = 24 * 60 * MINUTE_MS;

// Query values arrive as strings. Not z.coerce.number(): it would turn `?pickupLat=` into 0.
const numberParam = (schema) =>
  z.string().trim().min(1, 'is required').transform(Number).pipe(schema);
const latParam = numberParam(z.number().min(-90).max(90));
const lngParam = numberParam(z.number().min(-180).max(180));
const dateParam = z.iso.datetime({ offset: true }).transform((s) => new Date(s));

const searchRidesQuery = z
  .strictObject({
    pickupLat: latParam,
    pickupLng: lngParam,
    dropLat: latParam,
    dropLng: lngParam,
    from: dateParam,
    to: dateParam,
    seats: numberParam(z.number().int().min(1).max(6)).default(1),
    radius: numberParam(z.number().min(500).max(5000)).default(2000),
    limit: numberParam(z.number().int().min(1).max(50)).default(20),
    offset: numberParam(z.number().int().min(0)).default(0),
  })
  .superRefine((v, ctx) => {
    if (!(v.from instanceof Date && v.to instanceof Date)) return;
    const window = v.to.getTime() - v.from.getTime();
    if (window <= 0) {
      ctx.addIssue({ code: 'custom', path: ['to'], message: 'must be after from' });
    } else if (window > MAX_SEARCH_WINDOW_MS) {
      ctx.addIssue({
        code: 'custom',
        path: ['to'],
        message: 'must be at most 24 hours after from',
      });
    }
  });

module.exports = {
  createRideBody,
  rideIdParams,
  searchRidesQuery,
  MIN_LEAD_MS,
  MAX_LEAD_MS,
  MIN_TRIP_METERS,
  MAX_SEARCH_WINDOW_MS,
};
