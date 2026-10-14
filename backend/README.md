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

| Script                            | What it does                                                                |
| --------------------------------- | --------------------------------------------------------------------------- |
| `npm run dev`                     | Start the API with nodemon                                                  |
| `npm run migrate`                 | Create and apply a new migration (`prisma migrate dev`) on the dev database |
| `npm run migrate:deploy`          | Apply pending migrations to the dev database                                |
| `npm run db:test:up`              | Start the local test database and wait until it is healthy                  |
| `npm run db:test:down`            | Stop and remove the local test database (all its data is discarded)         |
| `npm run migrate:test`            | Apply migrations to the test database                                       |
| `npm test`                        | `migrate:test`, then the full Jest suite                                    |
| `npm run lint` / `npm run format` | ESLint / Prettier                                                           |

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
