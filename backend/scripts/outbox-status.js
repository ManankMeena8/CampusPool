// npm run outbox:status
// Prints the notification outbox: rows per status, the age of the oldest row still waiting, and
// rows that look stuck. Read-only; uses DATABASE_URL (whatever NODE_ENV says).

const STATUSES = ['PENDING', 'ENQUEUED', 'SENT', 'SKIPPED', 'FAILED'];
// A job runs for some 10 minutes at most (8 attempts with backoff), and the relay re-enqueues a
// lost one every 5 minutes: a row ENQUEUED for an hour will not finish by itself.
const STUCK_AFTER_MS = 60 * 60 * 1000;

/**
 * { counts: { STATUS: n }, oldest: { PENDING, ENQUEUED } (age in ms of the oldest row, by
 * createdAt, or null), stuck: n } where `stuck` counts rows ENQUEUED more than an hour ago.
 */
async function outboxStatus(db, now = Date.now()) {
  const grouped = await db.outbox.groupBy({
    by: ['status'],
    _count: { _all: true },
    _min: { createdAt: true },
  });
  const byStatus = new Map(grouped.map((g) => [g.status, g]));
  const counts = Object.fromEntries(STATUSES.map((s) => [s, byStatus.get(s)?._count._all ?? 0]));
  const age = (status) => {
    const oldest = byStatus.get(status)?._min.createdAt;
    return oldest ? Math.max(0, now - oldest.getTime()) : null;
  };
  const stuck = await db.outbox.count({
    where: { status: 'ENQUEUED', enqueuedAt: { lt: new Date(now - STUCK_AFTER_MS) } },
  });
  return { counts, oldest: { PENDING: age('PENDING'), ENQUEUED: age('ENQUEUED') }, stuck };
}

function formatAge(ms) {
  if (ms === null) return '-';
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds} s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
  if (seconds < 86400)
    return `${Math.floor(seconds / 3600)} h ${Math.floor((seconds % 3600) / 60)} min`;
  return `${Math.floor(seconds / 86400)} d ${Math.floor((seconds % 86400) / 3600)} h`;
}

function formatStatus({ counts, oldest, stuck }) {
  const lines = ['Notification outbox', ''];
  for (const status of STATUSES) {
    lines.push(`  ${status.padEnd(9)}${String(counts[status]).padStart(8)}`);
  }
  lines.push('');
  lines.push(`  Oldest PENDING row:   ${formatAge(oldest.PENDING)}`);
  lines.push(`  Oldest ENQUEUED row:  ${formatAge(oldest.ENQUEUED)}`);
  lines.push(`  ENQUEUED for over 1 h: ${stuck}`);
  if (stuck > 0) {
    lines.push('');
    lines.push(
      '  Rows ENQUEUED for over an hour are stuck: their job ended (sent, or out of attempts)',
      '  but the outcome could not be written, and the kept job blocks a re-enqueue until Redis',
      '  drops it. Check the "notifications" failed set and the logs before changing the rows.',
    );
  }
  if (oldest.PENDING !== null && oldest.PENDING > 60 * 1000) {
    lines.push('');
    lines.push(
      '  PENDING rows older than a minute mean the relay is not running (ENABLE_JOBS=0, or the',
      '  service is asleep) or cannot reach Redis (see "redis" in GET /health).',
    );
  }
  return lines.join('\n');
}

async function main() {
  const prisma = require('../src/lib/prisma');
  try {
    console.log(formatStatus(await outboxStatus(prisma)));
  } finally {
    await prisma.$disconnect();
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`outbox:status failed (${err.code ?? err.name})`);
    process.exit(1);
  });
}

module.exports = { outboxStatus, formatStatus, formatAge, STUCK_AFTER_MS };
