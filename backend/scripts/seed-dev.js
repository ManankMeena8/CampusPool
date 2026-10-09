// Creates a verified RIDER account in the dev database, skipping the email OTP step.
// Usage: npm run seed:dev -- <email> <password>
//
// The email must be at ALLOWED_EMAIL_DOMAIN and the password must meet the signup rules. An
// existing account is never changed. Refuses to run unless NODE_ENV is explicitly development.
const { assertDevelopment } = require('./devOnly');

assertDevelopment('seed:dev');

const bcrypt = require('bcrypt');
const { z } = require('zod');
const prisma = require('../src/lib/prisma');
const { signupEmail, password } = require('../src/validators/auth.validators');
const { BCRYPT_ROUNDS } = require('../src/services/auth.service');

const args = z.tuple([signupEmail, password]);

function parseArgs(argv) {
  const result = args.safeParse(argv);
  if (result.success) return result.data;
  const names = ['email', 'password'];
  for (const issue of result.error.issues) {
    console.error(`  - ${names[issue.path[0]] ?? 'arguments'}: ${issue.message}`);
  }
  console.error('Usage: npm run seed:dev -- <email> <password>');
  process.exit(1);
}

async function main() {
  const [email, plainPassword] = parseArgs(process.argv.slice(2));
  try {
    const user = await prisma.user.create({
      data: {
        name: email.split('@')[0],
        email,
        passwordHash: await bcrypt.hash(plainPassword, BCRYPT_ROUNDS),
        role: 'RIDER',
        isVerified: true,
      },
      select: { id: true, email: true, role: true },
    });
    console.log(`Created verified ${user.role} ${user.email} (${user.id}).`);
  } catch (err) {
    if (err.code !== 'P2002') throw err;
    console.error(`An account with ${email} already exists; nothing was changed.`);
    process.exitCode = 1;
  }
}

main()
  .catch((err) => {
    console.error(err);
    process.exitCode = 1;
  })
  .finally(() => prisma.$disconnect());
