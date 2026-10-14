# CampusPool
Real-time ride-pooling app for verified college students and staff.

## Stack
- Backend: Node.js 20, Express, PostgreSQL + PostGIS (Neon), Prisma, zod, JWT, bcrypt, Socket.io, Nodemailer
- Mobile: Flutter, Riverpod, dio, go_router, flutter_map + OpenStreetMap, geolocator, flutter_secure_storage, FCM
- Routing: OSRM public demo server (no key); isolated in routing.service.js
- Only free services. No Google Maps, no Redis yet.

## Backend conventions
- Structure: src/routes -> controllers -> services -> prisma
- Validate every request body, query and param with zod
- Geo queries use parameterized raw SQL via prisma.$queryRaw (never string concatenation)
- Consistent error format: { "error": { "code": "...", "message": "..." } }
- Central error-handling middleware; no try/catch duplication in controllers
- Every endpoint gets Jest + Supertest tests, including failure cases
- Coordinates: GeoJSON/PostGIS use (lng, lat); Flutter LatLng uses (lat, lng). Convert at the API boundary.

## Mobile conventions
- Feature folders: lib/features/<feature>/{data,providers,ui}
- All API calls go through a single dio client with auth interceptor
- Every screen handles loading, error and empty states
- Flutter targets Android only; the dev API URL is http://10.0.2.2:3000 and is overridden with --dart-define=API_BASE_URL

## Git
- Small commits with clear messages
- No Co-Authored-By or Claude attribution lines in commit messages
- Commit titles (the first line) must never contain the words "Claude", "CLAUDE.md", "Claude Code" or "Anthropic". When a commit changes CLAUDE.md, describe the content instead (for example "Record auth decisions and known gaps", "Update project conventions")
- Never commit .env files

## Decisions so far
- Backend: Express 4, Prisma 6; controllers are wrapped in asyncHandler (no try/catch)
- Tests use a local PostgreSQL 18 + PostGIS 3.6 database in Docker (matches Neon), never the dev database:
  container campuspool-test-db, port 5433, db campuspool_test, data on tmpfs, fsync off
  - Commands (in backend/): `npm run db:test:up`, `npm test` (runs migrate:test first), `npm run db:test:down`
  - backend/.env.test (gitignored; copy .env.test.example) sets TEST_DATABASE_URL; precedence is shell > .env.test > .env
  - tests/setup.js refuses the dev DATABASE_URL (read from .env), and any remote URL unless ALLOW_REMOTE_TEST_DB=1
  - The Neon test branch is still usable: set TEST_DATABASE_URL to it plus ALLOW_REMOTE_TEST_DB=1 (see backend/README.md)
- Auth: access token 15 min, refresh token 7 days with rotation on every refresh
- Rides: departure window, 200 m minimum trip and 1-hour overlap rule are enforced server-side; the full rule list is in the ride commit bodies
- Bookings: allowed status transitions live only in src/lib/bookingTransitions.js; invalid ones return 409 INVALID_TRANSITION. One active (PENDING or ACCEPTED) booking per rider per ride, enforced by a partial unique index
- Seats change only through conditional UPDATEs inside transactions (accept, rider cancel). Ride_seats_check (0 <= seatsAvailable <= seatsTotal) makes a double take or return fail loudly. There is no ride-edit endpoint; if one is added, it must refuse seat totals below the seats already ACCEPTED (409) and follow the lock order
- Lock order: any transaction touching a ride and its bookings locks the Ride row first, then Booking rows
- PENDING bookings on a FULL ride stay PENDING and can be accepted if a seat frees up; new requests on a FULL ride are refused
- Accepting on a ride that has departed is refused (409 SEAT_UNAVAILABLE). A rider can cancel while the ride is OPEN or FULL, even after departure. No role check on booking a seat: anyone but the ride's driver can

## Known gaps (decided, not forgotten)
- Login rate limiting by IP + email: add in Phase 7.1 (trust proxy = 1 on Render, limiter disabled in tests)
- Plus-addressing (a+1@, a+2@) can create duplicate accounts: accepted for the MVP
- Access tokens stay valid up to 15 minutes after logout: accepted
- Expired refresh tokens are never deleted: cleanup job planned for Part B
- Signup 409 and resend 429 reveal account state: accepted by design
- A refresh that times out, or returns 200 with a body the client can't parse, after the server already rotated the token makes the retry look like reuse, which logs the user out everywhere. Accepted for the MVP; possible fix is a short server-side grace window.
- OPEN rides past their departure time still show as OPEN in /rides/mine (nothing moves them to COMPLETED); the app must show them as expired
- Cancelling a ride cancels its bookings but notifies no one yet; neither do booking requests, accepts, rejects or cancels
- After a booking is accepted, rider and driver have no way to contact each other (no phone number shown, no chat) until chat in Part B
- A booking the rider cancelled shows as "Ride cancelled" (not "Cancelled") if the driver later cancels the ride: the app can't tell which came first. Fix needs the server to record who cancelled
- /rides/mine, /bookings/mine and /rides/:id/bookings have no pagination; the My Rides / My Bookings filters are client-side and must move to the server if pagination is added
- A booking's pickup and drop points are not checked against the ride's route or ends
- /rides/search matches only a ride's start and end points (each within the radius); a rider joining or leaving along the route (routeLine) is not matched yet
- Routing uses the public OSRM demo server: rate-limited, no SLA, for light use only. Move to a self-hosted OSRM (set ROUTING_BASE_URL) before real traffic
