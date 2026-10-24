const http = require('http');
const request = require('supertest');
const { io: ioClient } = require('socket.io-client');
const { resetDb, prisma } = require('./helpers/auth');
const { createUser, insertRide } = require('./helpers/rides');

// The settings render.yaml gives the API: its own https URL is the only CORS origin.
const SERVICE_URL = 'https://campuspool-api.onrender.com';
const PRODUCTION_ENV = {
  NODE_ENV: 'production',
  CORS_ORIGIN: SERVICE_URL,
  // Required in production; never read here (nothing in these tests sends a notification).
  FIREBASE_SERVICE_ACCOUNT_PATH: '/nonexistent/firebase-service-account.json',
};

const saved = {};
const isolated = [];

/** The app (and realtime) as production loads them, with `overrides` on top of PRODUCTION_ENV. */
function loadProduction(overrides = {}) {
  const vars = { ...PRODUCTION_ENV, ...overrides };
  for (const [name, value] of Object.entries(vars)) {
    if (!(name in saved)) saved[name] = process.env[name];
    process.env[name] = value;
  }
  let loaded;
  jest.isolateModules(() => {
    loaded = {
      app: require('../src/app'),
      attachRealtime: require('../src/realtime').attachRealtime,
      prisma: require('../src/lib/prisma'),
    };
  });
  isolated.push(loaded);
  return loaded;
}

afterEach(() => {
  for (const [name, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
    delete saved[name];
  }
});
afterAll(async () => {
  await Promise.all(isolated.map((l) => l.prisma.$disconnect()));
  await prisma.$disconnect();
});

describe('GET /debug/client-ip', () => {
  it('does not exist unless DEBUG_CLIENT_IP=1', async () => {
    const { app } = loadProduction();
    const res = await request(app).get('/debug/client-ip');
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });

  it('returns the client IP the proxy appended, and only a count of the forwarded entries', async () => {
    const { app } = loadProduction({ DEBUG_CLIENT_IP: '1' });
    // A client forging the header: Render appends the real IP after whatever it sent.
    const res = await request(app)
      .get('/debug/client-ip')
      .set('X-Forwarded-For', '1.2.3.4, 203.0.113.9');
    expect(res.status).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body).toEqual({ ip: '203.0.113.9', forwardedForEntries: 2, trustProxyHops: 1 });
  });

  it('shows the forged entry when TRUST_PROXY_HOPS is too high', async () => {
    const { app } = loadProduction({ DEBUG_CLIENT_IP: '1', TRUST_PROXY_HOPS: '2' });
    expect(app.get('trust proxy')).toBe(2);
    const res = await request(app)
      .get('/debug/client-ip')
      .set('X-Forwarded-For', '1.2.3.4, 203.0.113.9');
    expect(res.body).toMatchObject({ ip: '1.2.3.4', trustProxyHops: 2 });
  });

  it('refuses query parameters like every route', async () => {
    const { app } = loadProduction({ DEBUG_CLIENT_IP: '1' });
    const res = await request(app).get('/debug/client-ip?x=1');
    expect(res.status).toBe(400);
  });
});

describe('CORS in production', () => {
  it('serves a request without an Origin header (the Android app)', async () => {
    const { app } = loadProduction();
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });

  it("allows the service's own origin and no other", async () => {
    const { app } = loadProduction();
    const own = await request(app).get('/health').set('Origin', SERVICE_URL);
    expect(own.headers['access-control-allow-origin']).toBe(SERVICE_URL);
    const other = await request(app).get('/health').set('Origin', 'https://evil.example');
    expect(other.headers['access-control-allow-origin']).toBeUndefined();
  });

  describe('Socket.io', () => {
    let server;
    let io;
    let url;
    const clients = [];

    beforeAll(async () => {
      const { app, attachRealtime } = loadProduction();
      server = http.createServer(app);
      io = attachRealtime(server);
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      url = `http://127.0.0.1:${server.address().port}`;
    });
    beforeEach(() => resetDb());
    afterEach(() => {
      for (const socket of clients.splice(0)) socket.disconnect();
    });
    afterAll(() => new Promise((resolve) => io.close(() => resolve())));

    function connect(token, extraHeaders) {
      // Like the app: websocket transport only, the token in auth, no Origin unless given.
      const socket = ioClient(url, {
        auth: { token },
        transports: ['websocket'],
        reconnection: false,
        forceNew: true,
        extraHeaders,
      });
      clients.push(socket);
      return new Promise((resolve, reject) => {
        socket.once('connect', () => resolve(socket));
        socket.once('connect_error', reject);
      });
    }

    it("accepts the app's websocket connection (no Origin) and its ride:join", async () => {
      const driver = await createUser('driver');
      const rideId = await insertRide(driver.user.id);
      const socket = await connect(driver.token);
      const ack = await socket.timeout(2000).emitWithAck('ride:join', { rideId });
      expect(ack).toMatchObject({ ok: true, ride: { id: rideId, status: 'OPEN' } });
    });

    it('authenticates with the token, not the Origin', async () => {
      const driver = await createUser('driver');
      await expect(connect(driver.token, { Origin: 'https://evil.example' })).resolves.toBeTruthy();
      await expect(connect('not-a-token')).rejects.toMatchObject({
        data: { code: 'INVALID_TOKEN' },
      });
    });
  });
});
