// Seeds the dev database, skipping the email OTP step. Two forms:
//
//   npm run seed:dev -- <email> <password>
//     Creates one verified RIDER account.
//
//   npm run seed:dev -- --demo <password>
//     Creates a verified driver (demo.driver@ALLOWED_EMAIL_DOMAIN, role BOTH) and rider
//     (demo.rider@..., RIDER), both with <password>, and an OPEN sample ride by the driver
//     departing in 2 hours between DEMO_START and DEMO_END below.
//
// Emails must be at ALLOWED_EMAIL_DOMAIN and passwords must meet the signup rules. An existing
// account is never changed; the sample ride is skipped if the driver already has an upcoming
// one. Refuses to run unless NODE_ENV is explicitly development.
const { assertDevelopment } = require('./devOnly');

const env = assertDevelopment('seed:dev');

const bcrypt = require('bcrypt');
const { z } = require('zod');
const prisma = require('../src/lib/prisma');
const { signupEmail, password } = require('../src/validators/auth.validators');
const { createRideBody } = require('../src/validators/ride.validators');
const { BCRYPT_ROUNDS } = require('../src/services/auth.service');
const rideService = require('../src/services/ride.service');

// The sample ride, near NSUT Dwarka. Edit freely: the ride must be more than 200 m long.
const DEMO_START = { lat: 28.6096, lng: 77.0384, address: 'NSUT Main Gate, Dwarka' };
const DEMO_END = { lat: 28.5813, lng: 77.0583, address: 'Sample destination, Dwarka' };
const DEMO_DEPARTS_IN_MS = 2 * 60 * 60 * 1000;

const USAGE = [
  'Usage: npm run seed:dev -- <email> <password>',
  '       npm run seed:dev -- --demo <password>',
].join('\n');

const accountArgs = z.tuple([signupEmail, password]);
const demoArgs = z.tuple([z.literal('--demo'), password]);

function parseArgs(argv) {
  const demo = argv[0] === '--demo';
  const result = (demo ? demoArgs : accountArgs).safeParse(argv);
  if (result.success)
    return demo ? { demo, password: result.data[1] } : { demo, account: result.data };
  const names = demo ? ['--demo', 'password'] : ['email', 'password'];
  for (const issue of result.error.issues) {
    console.error(`  - ${names[issue.path[0]] ?? 'arguments'}: ${issue.message}`);
  }
  console.error(USAGE);
  process.exit(1);
}

/** Creates a verified user, or returns the existing one unchanged (`created: false`). */
async function ensureUser({ email, name, role, plainPassword }) {
  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) return { user: existing, created: false };
  try {
    const user = await prisma.user.create({
      data: {
        name,
        email,
        passwordHash: await bcrypt.hash(plainPassword, BCRYPT_ROUNDS),
        role,
        isVerified: true,
      },
    });
    return { user, created: true };
  } catch (err) {
    if (err.code !== 'P2002') throw err;
    // Created concurrently: report it as existing.
    return { user: await prisma.user.findUniqueOrThrow({ where: { email } }), created: false };
  }
}

function describeUser({ user, created }) {
  const state = created ? 'Created' : 'Kept existing';
  const warning = user.isVerified ? '' : ' (WARNING: not verified, cannot log in)';
  return `${state} ${user.role} ${user.email} (${user.id})${warning}`;
}

async function seedAccount([email, plainPassword]) {
  const result = await ensureUser({
    email,
    name: email.split('@')[0],
    role: 'RIDER',
    plainPassword,
  });
  if (!result.created) {
    console.error(`An account with ${email} already exists; nothing was changed.`);
    process.exitCode = 1;
    return;
  }
  console.log(describeUser(result));
}

async function seedDemo(plainPassword) {
  const domain = env.ALLOWED_EMAIL_DOMAIN;
  const driver = await ensureUser({
    email: `demo.driver@${domain}`,
    name: 'Demo Driver',
    role: 'BOTH',
    plainPassword,
  });
  const rider = await ensureUser({
    email: `demo.rider@${domain}`,
    name: 'Demo Rider',
    role: 'RIDER',
    plainPassword,
  });
  console.log(describeUser(driver));
  console.log(describeUser(rider));
  if (!driver.created || !rider.created) {
    console.log('Existing accounts keep their own passwords.');
  }

  if (!['DRIVER', 'BOTH'].includes(driver.user.role)) {
    console.error(`${driver.user.email} is a ${driver.user.role}, so no sample ride was created.`);
    process.exitCode = 1;
    return;
  }
  const upcoming = await prisma.ride.findFirst({
    where: {
      driverId: driver.user.id,
      status: { in: ['OPEN', 'FULL', 'IN_PROGRESS'] },
      departureTime: { gt: new Date() },
    },
    select: { id: true, departureTime: true },
  });
  if (upcoming) {
    console.log(
      `Kept the driver's upcoming ride ${upcoming.id} (departs ${upcoming.departureTime.toISOString()}); no new ride.`,
    );
    return;
  }

  // Same validation and service as POST /rides: the ride rules and routing apply.
  const input = createRideBody.parse({
    start: DEMO_START,
    end: DEMO_END,
    departureTime: new Date(Date.now() + DEMO_DEPARTS_IN_MS).toISOString(),
    seats: 3,
    pricePerSeat: 40,
    notes: 'Sample ride created by seed:dev',
  });
  const { ride, warnings } = await rideService.createRide(driver.user.id, input);
  const route = ride.distanceMeters
    ? `${ride.distanceMeters} m route`
    : 'no route (routing failed)';
  console.log(
    `Created OPEN ride ${ride.id}: ${DEMO_START.address} -> ${DEMO_END.address}, ` +
      `departs ${ride.departureTime.toISOString()}, ${route}.`,
  );
  for (const warning of warnings) console.log(`  warning: ${warning}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.demo) await seedDemo(args.password);
  else await seedAccount(args.account);
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
