# CampusPool backend

Express + Prisma API for CampusPool. PostgreSQL + PostGIS on Neon in development and production.

## Setup

Requires Node.js 20+, and Docker for the tests.

```sh
npm install
cp .env.example .env        # fill in DATABASE_URL, JWT_ACCESS_SECRET, SMTP_*, ...
npm run migrate:deploy      # apply migrations to the dev database
npm run dev                 # http://localhost:3000
```

## Scripts

| Script                            | What it does                                                                  |
| --------------------------------- | ----------------------------------------------------------------------------- |
| `npm run dev`                     | Start the API with nodemon                                                    |
| `npm run migrate`                 | Create and apply a new migration (`prisma migrate dev`) on the dev database   |
| `npm run migrate:deploy`          | Apply pending migrations (through `DIRECT_URL` when set, else `DATABASE_URL`) |
| `npm run db:test:up`              | Start the local test database and wait until it is healthy                    |
| `npm run db:test:down`            | Stop and remove the local test database (all its data is discarded)           |
| `npm run migrate:test`            | Apply migrations to the test database                                         |
| `npm test`                        | `migrate:test`, then the full Jest suite                                      |
| `npm run lint` / `npm run format` | ESLint / Prettier                                                             |
| `npm run seed:dev -- ...`         | Create verified dev accounts without email codes (see below)                  |

### Dev seed

Runs only with `NODE_ENV=development` and writes to the dev database:

```sh
npm run seed:dev -- --demo <password>      # demo.driver@ (BOTH) + demo.rider@ (RIDER) + a sample ride
npm run seed:dev -- <email> <password>     # one verified RIDER
```

The demo ride is OPEN, has 3 seats and departs 2 hours after the run, near NSUT Dwarka. Its
coordinates are constants at the top of `scripts/seed-dev.js`. Re-running never changes an
existing account (it keeps its password) and adds no ride while the driver has an upcoming one.

## Push notifications

Sent through Firebase Cloud Messaging (`firebase-admin`) after each change commits: booking
requested, accepted, rejected and cancelled; ride started (to accepted riders, and to riders whose
pending requests it rejected) and ride cancelled. The app registers its device token with
`PUT /users/me/fcm-token`; logout clears it.

Set `FIREBASE_SERVICE_ACCOUNT_PATH` in `.env` to the absolute path of the service account JSON,
kept **outside the repo** (for example `C:/secrets/campuspool-firebase.json` locally, or a
Render secret file under `/etc/secrets/`). It is required in production. Elsewhere, when it is
unset, and anywhere when the file is unreadable, the API starts anyway, logs that notifications
are disabled and skips every send.
Tests never send: `tests/setup.js` empties the variable. A failed send is logged and never fails
the request; tokens FCM reports as invalid are cleared.

## Production

- `NODE_ENV=production` requires `CORS_ORIGIN` to list exact origins (`https://app.example.com`,
  no trailing slash); `*` is refused at startup.
- Deployment to Render (free plan, from `render.yaml` at the repo root): see
  [docs/deploy-render.md](../docs/deploy-render.md). The start command runs
  `scripts/migrate-deploy.js` (migrations through `DIRECT_URL`, Neon's direct URL, when set),
  then the server, which listens on `0.0.0.0:$PORT`.
- Render uses npm 10. After changing dependencies, regenerate the lock file with
  `npx npm@10 install` (or check with
  `docker run --rm -e NODE_ENV=production -v "$PWD:/app" -w /app node:20.20.2 npm ci` in a clean
  copy of `backend/`) before pushing. npm 11 can write a lock file that npm 10's `npm ci`
  refuses as out of sync.
- Startup refuses to run with a missing or invalid variable and lists the names, never the
  values. Production also requires `MAIL_FROM` and `FIREBASE_SERVICE_ACCOUNT_PATH`.
- OTP emails: `EMAIL_PROVIDER=smtp` (Nodemailer, local development) or `brevo` (Brevo's HTTP API
  with `BREVO_API_KEY`; Render's free plan blocks outbound SMTP). Same message either way; tests
  mock both (nodemailer through `moduleNameMapper`, Brevo by spying on `fetch`).
- SIGTERM (every Render deploy) closes the sockets, the HTTP server and Prisma, and exits; after
  10 s it forces the exit.
- `trust proxy` is `TRUST_PROXY_HOPS` (default 1) in production, so rate limits see the client
  IP. Check it after a deploy with `DEBUG_CLIENT_IP=1` and `GET /debug/client-ip` (404 when off;
  turn it off right after checking).
- Rate limits on `/auth` (in memory, so run a **single instance**, as for live locations):
  100 requests / 15 min per IP on every route but refresh, 1000 / 15 min per IP on
  `/auth/refresh`, and 10 failed logins / 15 min per IP + email. Refused requests get
  `429 RATE_LIMITED` with `Retry-After`. Off in tests unless `RATE_LIMIT_IN_TESTS=1`.

## Tests

Tests run against a throwaway PostgreSQL 18 + PostGIS 3.6 database in Docker (the same versions
as Neon), defined in `docker-compose.test.yml`: container `campuspool-test-db`, host port
**5433** (so it never clashes with another Postgres), database `campuspool_test`. Its data lives
in memory (tmpfs), with fsync off, so every `db:test:down` starts the next run from scratch.

```sh
cp .env.test.example .env.test   # once; .env.test is gitignored
npm run db:test:up
npm test
npm run db:test:down             # when you are done
```

`npm test` applies migrations first, so a freshly started database needs no extra step.

### Where tests connect

`tests/setup.js` loads `.env.test` before anything else. Precedence is: shell variables, then
`.env.test`, then `.env`. Under `NODE_ENV=test`, `TEST_DATABASE_URL` becomes `DATABASE_URL`.

Every test truncates the tables, so `tests/setup.js` refuses to run (and `npm test` stops before
migrating) unless `TEST_DATABASE_URL`:

- is never the dev `DATABASE_URL` (read straight from `backend/.env`), and
- is either local (`localhost` / `127.0.0.1`) with database `campuspool_test`, or remote with
  `ALLOW_REMOTE_TEST_DB=1` set explicitly.

### Running against the Neon test branch

Set the Neon test branch URL and the opt-in flag for one session (PowerShell):

```powershell
$env:TEST_DATABASE_URL = "postgresql://...neon.tech/neondb?sslmode=require"
$env:ALLOW_REMOTE_TEST_DB = "1"
npm test
```

Then clear both, so a later `npm test` in the same terminal does not silently hit Neon again:

```powershell
Remove-Item Env:TEST_DATABASE_URL, Env:ALLOW_REMOTE_TEST_DB
```

(Alternatively, put both lines in `.env.test` and restore it from `.env.test.example` afterwards.)
The full suite takes about 9 minutes on Neon versus about 10 seconds locally; Jest's 30 s
per-test timeout is sized for Neon.
