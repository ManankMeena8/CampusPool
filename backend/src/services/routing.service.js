const { z } = require('zod');
const { env } = require('../config/env');

const TIMEOUT_MS = 5000;
const USER_AGENT = 'CampusPool/0.1 (student project)';

const lngLat = z.tuple([z.number().min(-180).max(180), z.number().min(-90).max(90)]);

const okResponse = z.object({
  code: z.literal('Ok'),
  routes: z
    .array(
      z.object({
        geometry: z.object({
          type: z.literal('LineString'),
          coordinates: z.array(lngLat).min(2),
        }),
        distance: z.number().nonnegative(),
        duration: z.number().nonnegative(),
      }),
    )
    .min(1),
  waypoints: z.array(z.object({ distance: z.number().nonnegative() })).length(2),
});

/**
 * Turns an OSRM /route response body into
 *   { ok: true, route: { geometry, distanceMeters, durationSeconds, startSnapMeters, endSnapMeters } }
 * or { ok: false, reason }. `geometry` stays a GeoJSON LineString ([lng, lat] pairs).
 */
function parseRouteResponse(body) {
  if (body?.code !== 'Ok') {
    const code = typeof body?.code === 'string' ? body.code : 'missing code';
    return { ok: false, reason: `OSRM returned ${code}` };
  }
  const result = okResponse.safeParse(body);
  if (!result.success) return { ok: false, reason: 'OSRM response has an unexpected shape' };

  const [route] = result.data.routes;
  const [startWaypoint, endWaypoint] = result.data.waypoints;
  return {
    ok: true,
    route: {
      geometry: route.geometry,
      distanceMeters: Math.round(route.distance),
      durationSeconds: Math.round(route.duration),
      startSnapMeters: startWaypoint.distance,
      endSnapMeters: endWaypoint.distance,
    },
  };
}

// toFixed avoids exponent notation (1e-7), which OSRM cannot parse; 6 decimals is about 0.1 m.
const coord = ({ lat, lng }) => `${lng.toFixed(6)},${lat.toFixed(6)}`;

/**
 * Asks OSRM for a driving route between two {lat, lng} points.
 * Never throws: on timeout, network error or a non-Ok answer it logs a warning and returns null,
 * so callers can carry on without a route.
 */
async function getDrivingRoute(start, end) {
  const url =
    `${env.ROUTING_BASE_URL}/route/v1/driving/${coord(start)};${coord(end)}` +
    '?overview=full&geometries=geojson';

  let body;
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    body = await res.json();
  } catch (err) {
    const why = err?.name === 'TimeoutError' ? `timed out after ${TIMEOUT_MS} ms` : err?.message;
    console.warn(`Routing unavailable, creating ride without a route: ${why}`);
    return null;
  }

  const parsed = parseRouteResponse(body);
  if (!parsed.ok) {
    console.warn(`Routing unavailable, creating ride without a route: ${parsed.reason}`);
    return null;
  }
  return parsed.route;
}

module.exports = { getDrivingRoute, parseRouteResponse, TIMEOUT_MS, USER_AGENT };
