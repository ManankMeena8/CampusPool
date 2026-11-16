const { prisma, resetDb } = require('./helpers/auth');
const { createUser } = require('./helpers/rides');
const { outboxStatus, formatStatus, formatAge } = require('../scripts/outbox-status');

beforeEach(resetDb);
afterAll(() => prisma.$disconnect());

const MINUTE = 60 * 1000;

describe('outbox:status', () => {
  it('reports zeros and no ages for an empty outbox', async () => {
    const status = await outboxStatus(prisma);
    expect(status).toEqual({
      counts: { PENDING: 0, ENQUEUED: 0, SENT: 0, SKIPPED: 0, FAILED: 0 },
      oldest: { PENDING: null, ENQUEUED: null },
      stuck: 0,
    });
    const text = formatStatus(status);
    expect(text).toMatch(/Oldest PENDING row:\s+-/);
    expect(text).not.toMatch(/stuck/);
  });

  it('counts per status, the oldest waiting rows, and rows ENQUEUED for over an hour', async () => {
    const { user } = await createUser('rider', 'RIDER');
    const now = Date.now();
    const at = (msAgo) => new Date(now - msAgo);
    const base = { type: 'ride.started', recipientUserId: user.id, payload: {} };
    await prisma.outbox.createMany({
      data: [
        { ...base, status: 'PENDING', createdAt: at(3 * MINUTE) },
        { ...base, status: 'PENDING', createdAt: at(1 * MINUTE) },
        // Enqueued recently: in flight.
        { ...base, status: 'ENQUEUED', createdAt: at(10 * MINUTE), enqueuedAt: at(2 * MINUTE) },
        // Old, but re-enqueued by recovery a moment ago: not stuck yet.
        { ...base, status: 'ENQUEUED', createdAt: at(200 * MINUTE), enqueuedAt: at(4 * MINUTE) },
        // Enqueued over an hour ago and never finished.
        { ...base, status: 'ENQUEUED', createdAt: at(90 * MINUTE), enqueuedAt: at(61 * MINUTE) },
        { ...base, status: 'SENT', createdAt: at(500 * MINUTE), processedAt: at(499 * MINUTE) },
        { ...base, status: 'SENT', createdAt: at(400 * MINUTE), processedAt: at(399 * MINUTE) },
        { ...base, status: 'SENT', createdAt: at(300 * MINUTE), processedAt: at(299 * MINUTE) },
        { ...base, status: 'SKIPPED', createdAt: at(300 * MINUTE), lastError: 'no-token' },
        { ...base, status: 'FAILED', createdAt: at(300 * MINUTE), lastError: 'x' },
      ],
    });

    const status = await outboxStatus(prisma, now);

    expect(status.counts).toEqual({ PENDING: 2, ENQUEUED: 3, SENT: 3, SKIPPED: 1, FAILED: 1 });
    expect(status.oldest).toEqual({ PENDING: 3 * MINUTE, ENQUEUED: 200 * MINUTE });
    expect(status.stuck).toBe(1);

    const text = formatStatus(status);
    expect(text).toMatch(/PENDING\s+2\n/);
    expect(text).toMatch(/SENT\s+3\n/);
    expect(text).toMatch(/Oldest PENDING row:\s+3 min 0 s/);
    expect(text).toMatch(/Oldest ENQUEUED row:\s+3 h 20 min/);
    expect(text).toMatch(/ENQUEUED for over 1 h: 1/);
    expect(text).toMatch(/are stuck/);
    expect(text).toMatch(/relay is not running/);
  });

  it.each([
    [null, '-'],
    [0, '0 s'],
    [59_999, '59 s'],
    [61_000, '1 min 1 s'],
    [2 * 60 * MINUTE + 5 * MINUTE, '2 h 5 min'],
    [50 * 60 * MINUTE, '2 d 2 h'],
  ])('formats an age of %s ms as "%s"', (ms, text) => {
    expect(formatAge(ms)).toBe(text);
  });
});
