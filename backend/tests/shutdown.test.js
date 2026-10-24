const http = require('http');
const { Server } = require('socket.io');
const { io: ioClient } = require('socket.io-client');
const { createShutdown } = require('../src/lib/shutdown');

let server;
let io;
let url;
let exit;
let prisma;
let logSpy;
let errSpy;

beforeEach(async () => {
  logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
  errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  // /slow never answers: a request still in flight when the signal arrives.
  server = http.createServer((req, res) => {
    if (req.url !== '/slow') res.end('ok');
  });
  io = new Server(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  url = `http://127.0.0.1:${server.address().port}`;
  prisma = { $disconnect: jest.fn().mockResolvedValue() };
  exit = jest.fn();
});

afterEach(() => {
  server.closeAllConnections();
  if (server.listening) server.close();
  jest.restoreAllMocks();
});

/** Resolves to the exit code once `exit` is called. */
const exited = () =>
  new Promise((resolve) => {
    exit.mockImplementation(resolve);
  });

function connectClient() {
  const socket = ioClient(url, { transports: ['websocket'], reconnection: false, forceNew: true });
  return new Promise((resolve, reject) => {
    socket.once('connect', () => resolve(socket));
    socket.once('connect_error', reject);
  });
}

describe('createShutdown', () => {
  it('disconnects sockets, closes the server and Prisma, then exits 0', async () => {
    const client = await connectClient();
    const disconnected = new Promise((resolve) => client.once('disconnect', resolve));
    const code = exited();

    createShutdown({ io, prisma, exit })('SIGTERM');

    expect(await code).toBe(0);
    await disconnected;
    expect(server.listening).toBe(false);
    expect(prisma.$disconnect).toHaveBeenCalledTimes(1);
    expect(logSpy).toHaveBeenCalledWith('SIGTERM received, shutting down');
    client.close();
  });

  it('runs once when a second signal arrives', async () => {
    const code = exited();
    const shutdown = createShutdown({ io, prisma, exit });
    shutdown('SIGTERM');
    shutdown('SIGINT');
    expect(await code).toBe(0);
    expect(prisma.$disconnect).toHaveBeenCalledTimes(1);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it('exits 1 when a request in flight keeps the server open too long', async () => {
    const pending = http.get(`${url}/slow`).on('error', () => {});
    await new Promise((resolve) => server.once('request', resolve));
    const code = exited();

    createShutdown({ io, prisma, exit, forceAfterMs: 100 })('SIGTERM');

    expect(await code).toBe(1);
    expect(errSpy).toHaveBeenCalledWith(expect.stringMatching(/did not finish within 100 ms/));
    pending.destroy();
  });

  it('exits 1 when Prisma fails to disconnect, logging only the error code', async () => {
    prisma.$disconnect.mockRejectedValue(
      Object.assign(new Error('postgresql://user:secret@host/db'), { code: 'P1001' }),
    );
    const code = exited();

    createShutdown({ io, prisma, exit })('SIGTERM');

    expect(await code).toBe(1);
    expect(errSpy).toHaveBeenCalledWith('Disconnecting Prisma failed (P1001)');
    expect(JSON.stringify(errSpy.mock.calls)).not.toMatch(/secret/);
  });
});
