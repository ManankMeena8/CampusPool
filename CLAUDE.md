# CampusPool
Real-time ride-pooling app for verified college students and staff.

## Stack
- Backend: Node.js 20, Express, PostgreSQL + PostGIS (Neon), Prisma, zod, JWT, bcrypt, Socket.io, Nodemailer, firebase-admin (FCM), express-rate-limit
- Mobile: Flutter, Riverpod, dio, go_router, flutter_map + OpenStreetMap, geolocator, flutter_secure_storage, FCM
- Routing: OSRM public demo server (no key); isolated in routing.service.js
- Only free services. No Google Maps, no Redis yet.

## Backend conventions
- Structure: src/routes -> controllers -> services -> prisma
- Validate every request body, query and param with zod. A part a route does not declare must be empty (validate() defaults it to z.strictObject({})), so validate({}) means "no input" and unexpected fields get 400
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
- Rate limits (src/middleware/rateLimits.js, in memory, 429 RATE_LIMITED with Retry-After): 100 / 15 min per IP on every /auth route but refresh (generous: a campus shares one Wi-Fi IP), 1000 / 15 min per IP on /auth/refresh, and 10 failed logins / 15 min per IP + normalized email (successes not counted; the brute-force protection). Off in tests unless RATE_LIMIT_IN_TESTS=1 (tests/rateLimits.test.js)
- trust proxy = 1 only when NODE_ENV=production (Render); elsewhere X-Forwarded-For is not trusted
- CORS: NODE_ENV=production requires CORS_ORIGIN as exact origins (no *, no trailing slash or path), checked at startup; outside production it defaults to *
- Dev seed: `npm run seed:dev -- --demo <password>` creates verified demo.driver@ (BOTH) and demo.rider@ (RIDER) and an OPEN sample ride near NSUT Dwarka (constants at the top of scripts/seed-dev.js); never changes existing accounts
- Rides: departure window, 200 m minimum trip and 1-hour overlap rule are enforced server-side; the full rule list is in the ride commit bodies
- Bookings: allowed status transitions live only in src/lib/bookingTransitions.js; invalid ones return 409 INVALID_TRANSITION. One active (PENDING or ACCEPTED) booking per rider per ride, enforced by a partial unique index
- Seats change only through conditional UPDATEs inside transactions (accept, rider cancel). Ride_seats_check (0 <= seatsAvailable <= seatsTotal) makes a double take or return fail loudly. There is no ride-edit endpoint; if one is added, it must refuse seat totals below the seats already ACCEPTED (409) and follow the lock order
- Lock order: any transaction touching a ride and its bookings locks the Ride row first, then Booking rows
- PENDING bookings on a FULL ride stay PENDING and can be accepted if a seat frees up; new requests on a FULL ride are refused
- Accepting on a ride that has departed is refused (409 SEAT_UNAVAILABLE). A rider can cancel while the ride is OPEN or FULL, even after departure. No role check on booking a seat: anyone but the ride's driver can
- Ride lifecycle: POST /rides/:id/start (driver, OPEN or FULL, from 30 min before to 30 min after departure; PENDING bookings become REJECTED) and POST /rides/:id/complete (driver, IN_PROGRESS; bookings stay ACCEPTED). IN_PROGRESS and COMPLETED rides refuse ride cancel, rider cancel, accept and new requests (409)
- Realtime: Socket.io on the API's HTTP server (src/realtime). Handshake sends the access token as auth.token. On connect the server schedules a disconnect for the token's expiry (cleared on disconnect), so a socket that only listens (a rider) cannot outlive its token; an event that arrives after the expiry but before that timer gets TOKEN_EXPIRED and the socket is disconnected. Either way the app reconnects with a refreshed token. Every event acks { ok: true, ... } or the REST error body
  - ride:join {rideId}: driver or ACCEPTED riders only; acks { ride: {id, status}, lastLocation } (lastLocation only while IN_PROGRESS). Rooms: ride:<id>, plus user:<id> per socket, used to remove a rider whose ACCEPTED booking is cancelled
  - location:update {rideId, lat, lng, heading?, speed?}: driver only, IN_PROGRESS only, at most 1 per 2 s per driver (THROTTLED); broadcast as driver:location to the rest of the room
  - ride:status {rideId, status} on start, complete and ride cancel. Emits and location/throttle cleanup happen in src/realtime/hub.js, called only after the transaction commits, and never fail the request
  - The location store sits behind async get/set/delete (src/realtime/locationStore.js) so Redis can replace it
- Push notifications (FCM, src/services/notification.service.js): one function per event; the caller passes the recipients' user ids, the service builds the text and looks up tokens. Events: bookingRequested (driver), bookingAccepted / bookingRejected (rider), bookingCancelled by the rider (driver, with wasAccepted), rideCancelled (riders whose PENDING or ACCEPTED bookings it ended), rideStarted (ACCEPTED riders), bookingAutoRejected (riders whose PENDING requests the start rejected). Ride cancel and start read those riders inside the transaction, before the booking update
  - Called only after the transaction commits, through src/lib/notify.js -> runInBackground: not awaited, and a throw or rejection is logged, never fails the request. notify lives outside the notification module so tests can mock the module (jest.mock) and still prove the request survives a failing send
  - Credentials: FIREBASE_SERVICE_ACCOUNT_PATH (JSON outside the repo, never committed or logged). Unset or unreadable: startup logs it and every send is skipped before any DB query. Always off in tests (setup.js empties it). Credential errors log only the path and an error code
  - Tokens FCM reports as registration-token-not-registered or invalid-registration-token are cleared, only if the user still has that token. Messages carry data {type, rideId, bookingId?} (strings) and android priority high
  - PUT /users/me/fcm-token {token} (204) stores the token and takes it off any other user (shared phone). Logout clears the user's token, but only when it actually revokes the refresh token
  - firebase-admin is pinned to 13.x: 14 requires Node 22
- Session refresh (mobile): SessionRefresher (lib/core/api) is the only caller of /auth/refresh. The dio AuthInterceptor and the socket share its single-flight call; freshAccessToken() refreshes when the JWT exp is under 60 s away (or forced)
- Live tracking (mobile, lib/features/tracking):
  - RideTrackingConnection turns socket_io_client's reconnection off (it would resend the token the socket was created with). Every attempt is a new socket with a fresh token, backoff 1 s doubling to 30 s, then a re-join whose ack replaces the shown state. A handshake TOKEN_EXPIRED/INVALID_TOKEN or a server-side disconnect forces a refresh; FORBIDDEN and RIDE_NOT_FOUND are final
  - Driver: geolocator stream (high accuracy, 20 m distance filter) in an Android foreground service with an ongoing notification, started from the foreground, so no ACCESS_BACKGROUND_LOCATION. LocationEmitter sends at most one fix per 2.2 s (latest wins) and resends the last fix after 10 s without one, so a stopped car does not look lost
  - The Live ride screen (/rides/:id/live) owns tracking: closing it, or the ride ending, stops the tracker and disconnects. The driver leaving while IN_PROGRESS is asked first. Start ride checks location permission and GPS before calling /start
  - Riders: the marker glides between updates; "Last updated" uses the phone's receive time (the server's recordedAt, never in the future, for the join ack); a warning shows after 30 s without an update

## Known gaps (decided, not forgotten)
- Rate-limit counts live in one process's memory, like the location store: another reason the API must run as a single instance, and a restart resets them
- Plus-addressing (a+1@, a+2@) can create duplicate accounts: accepted for the MVP
- Access tokens stay valid up to 15 minutes after logout: accepted
- Expired refresh tokens are never deleted: cleanup job planned for Part B
- Signup 409 and resend 429 reveal account state: accepted by design
- A refresh that times out, or returns 200 with a body the client can't parse, after the server already rotated the token makes the retry look like reuse, which logs the user out everywhere. Accepted for the MVP; possible fix is a short server-side grace window.
- OPEN rides past their departure time still show as OPEN in /rides/mine (nothing moves them to COMPLETED); the app must show them as expired
- OPEN/FULL seat changes emit no socket event (bookings and ride cancels now send push notifications instead)
- The mobile app does not register FCM tokens or handle notifications yet (Prompt 7.2), so nothing is delivered until then
- One FCM token per user: only the most recently registered device gets notifications, and logging out on any device clears it
- Notifications are fire-and-forget in the API process: no retry, no outbox. A failed send, or a crash between the commit and the send, loses that notification
- Completing a ride sends no notification
- Last locations and the location throttle live in one process's memory: the API must run as a single instance until they move to Redis, and a restart forgets the last locations
- Nothing completes an IN_PROGRESS ride the driver forgets to complete: it stays IN_PROGRESS (and keeps counting for the 1-hour overlap rule). A driver more than 30 min late cannot start the ride, which stays OPEN
- A location update checked just before a complete commits can be stored after the clear, leaving one stale entry in memory (never returned: joins only return locations for IN_PROGRESS rides)
- Driver locations are not checked for plausibility (jumps, speed) or against the route
- After a booking is accepted, rider and driver have no way to contact each other (no phone number shown, no chat) until chat in Part B
- A booking the rider cancelled shows as "Ride cancelled" (not "Cancelled") if the driver later cancels the ride: the app can't tell which came first. Fix needs the server to record who cancelled
- /rides/mine, /bookings/mine and /rides/:id/bookings have no pagination; the My Rides / My Bookings filters are client-side and must move to the server if pagination is added
- A booking's pickup and drop points are not checked against the ride's route or ends
- /rides/search matches only a ride's start and end points (each within the radius); a rider joining or leaving along the route (routeLine) is not matched yet
- Routing uses the public OSRM demo server: rate-limited, no SLA, for light use only. Move to a self-hosted OSRM (set ROUTING_BASE_URL) before real traffic
- Tracking stops if the driver swipes the app away or Android kills the process; it resumes only when they reopen the Live ride screen
- The Android 13+ notification permission is not requested yet: until Phase 7 asks for it (with firebase_messaging), the tracking notification may be hidden. Tracking still runs
- A rider whose booking is cancelled during the ride is removed from the room without an event: their screen just stops getting updates (and shows the 30 s warning) until a reconnect, whose join is refused
- The 10 s heartbeat resends the last fix, so "Last updated" shows that the driver's app is alive, not that the car moved
