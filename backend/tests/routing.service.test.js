const {
  getDrivingRoute,
  parseRouteResponse,
  TIMEOUT_MS,
  USER_AGENT,
} = require('../src/services/routing.service');

// Trimmed real-shape OSRM /route/v1/driving responses (overview=full, geometries=geojson).
const OSRM_OK = {
  code: 'Ok',
  routes: [
    {
      geometry: {
        type: 'LineString',
        coordinates: [
          [77.594566, 12.971599],
          [77.6006, 12.9756],
          [77.6408, 12.9784],
        ],
      },
      legs: [{ steps: [], summary: '', weight: 812.4, duration: 812.4, distance: 6843.7 }],
      weight_name: 'routability',
      weight: 812.4,
      duration: 812.4,
      distance: 6843.7,
    },
  ],
  waypoints: [
    { hint: 'abc', distance: 12.3, name: 'MG Road', location: [77.594566, 12.971599] },
    { hint: 'def', distance: 412.9, name: '', location: [77.6408, 12.9784] },
  ],
};

const OSRM_NO_ROUTE = { code: 'NoRoute', message: 'Impossible route between points', routes: [] };

describe('parseRouteResponse', () => {
  it('parses a successful OSRM response', () => {
    expect(parseRouteResponse(OSRM_OK)).toEqual({
      ok: true,
      route: {
        geometry: OSRM_OK.routes[0].geometry,
        distanceMeters: 6844,
        durationSeconds: 812,
        startSnapMeters: 12.3,
        endSnapMeters: 412.9,
      },
    });
  });

  it('reports NoRoute as a failure', () => {
    expect(parseRouteResponse(OSRM_NO_ROUTE)).toEqual({
      ok: false,
      reason: 'OSRM returned NoRoute',
    });
  });

  it.each([
    ['no body', undefined],
    ['no code', { routes: [] }],
    ['Ok without routes', { ...OSRM_OK, routes: [] }],
    [
      'a single-point line',
      {
        ...OSRM_OK,
        routes: [
          { ...OSRM_OK.routes[0], geometry: { type: 'LineString', coordinates: [[77.5, 12.9]] } },
        ],
      },
    ],
    [
      'coordinates out of range',
      {
        ...OSRM_OK,
        routes: [
          {
            ...OSRM_OK.routes[0],
            geometry: {
              type: 'LineString',
              coordinates: [
                [200, 12],
                [77, 12],
              ],
            },
          },
        ],
      },
    ],
    ['missing waypoints', { ...OSRM_OK, waypoints: undefined }],
  ])('rejects %s', (_label, body) => {
    expect(parseRouteResponse(body).ok).toBe(false);
  });
});

describe('getDrivingRoute', () => {
  const start = { lat: 12.971599, lng: 77.594566 };
  const end = { lat: 12.9784, lng: 77.6408 };
  let fetchSpy;
  let warnSpy;

  beforeEach(() => {
    fetchSpy = jest.spyOn(global, 'fetch');
    warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => jest.restoreAllMocks());

  const respondWith = (body, status = 200) =>
    fetchSpy.mockResolvedValue(new Response(JSON.stringify(body), { status }));

  it('requests lng,lat pairs with the User-Agent and a timeout, and returns the route', async () => {
    respondWith(OSRM_OK);

    const route = await getDrivingRoute(start, end);

    expect(route).toMatchObject({ distanceMeters: 6844, durationSeconds: 812 });
    const [url, options] = fetchSpy.mock.calls[0];
    expect(url).toBe(
      'https://osrm.test.invalid/route/v1/driving/77.594566,12.971599;77.640800,12.978400' +
        '?overview=full&geometries=geojson',
    );
    expect(options.headers['User-Agent']).toBe(USER_AGENT);
    expect(options.signal).toBeInstanceOf(AbortSignal);
    expect(warnSpy).not.toHaveBeenCalled();
  });

  it('never formats coordinates in exponent notation', async () => {
    respondWith(OSRM_OK);
    await getDrivingRoute({ lat: 0.0000001, lng: -0.0000001 }, end);
    expect(fetchSpy.mock.calls[0][0]).toContain('/driving/-0.000000,0.000000;');
  });

  it('returns null and warns on NoRoute (HTTP 400)', async () => {
    respondWith(OSRM_NO_ROUTE, 400);
    await expect(getDrivingRoute(start, end)).resolves.toBeNull();
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('NoRoute'));
  });

  it('returns null and warns on a timeout', async () => {
    fetchSpy.mockRejectedValue(new DOMException('The operation timed out.', 'TimeoutError'));
    await expect(getDrivingRoute(start, end)).resolves.toBeNull();
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining(`timed out after ${TIMEOUT_MS} ms`),
    );
  });

  it('returns null and warns on a network error', async () => {
    fetchSpy.mockRejectedValue(new TypeError('fetch failed'));
    await expect(getDrivingRoute(start, end)).resolves.toBeNull();
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('fetch failed'));
  });

  it('returns null and warns on a non-JSON body', async () => {
    fetchSpy.mockResolvedValue(new Response('<html>502 Bad Gateway</html>', { status: 502 }));
    await expect(getDrivingRoute(start, end)).resolves.toBeNull();
    expect(warnSpy).toHaveBeenCalledTimes(1);
  });
});
