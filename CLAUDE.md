# CampusPool
Real-time ride-pooling app for verified college students and staff.

## Stack
- Backend: Node.js 20, Express, PostgreSQL + PostGIS (Neon), Prisma, zod, JWT, bcrypt, Socket.io, Nodemailer (dev) / Brevo HTTP API (production), firebase-admin (FCM), BullMQ + ioredis (Redis), express-rate-limit
- Hosting: Render free web service + free Key Value instance (Redis-compatible; render.yaml, region singapore) + Neon production project in AWS ap-southeast-1; step by step in docs/deploy-render.md
- Mobile: Flutter, Riverpod, dio, go_router, flutter_map + OpenStreetMap, geolocator, flutter_secure_storage, FCM
- Routing: OSRM public demo server (no key); isolated in routing.service.js
- Only free services. No Google Maps. Redis is Render Key Value (free) in production and a Docker container locally; so far it holds only the BullMQ notification queue.

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
  - The same compose file runs Redis (redis:7.4-alpine, container campuspool-test-redis, port 6380, noeviction, no persistence). Tests use db 0 (REDIS_URL in .env.test, required), `npm run dev` uses db 1 (REDIS_URL in .env), so Docker Desktop must be running for `npm run dev` too. The job tests run FLUSHDB (never FLUSHALL); setup.js refuses a missing REDIS_URL, the dev one from .env (same host, port and db), and a remote one unless ALLOW_REMOTE_TEST_DB=1
  - setup.js sets ENABLE_JOBS=0: the relay and worker never start with the app in tests. tests/outbox.jobs.test.js builds its own against the real Redis with a fake FCM client and closes everything (redis.closeAll) so Jest exits without open handles
  - The Neon test branch is still usable: set TEST_DATABASE_URL to it plus ALLOW_REMOTE_TEST_DB=1 (see backend/README.md)
- Auth: access token 15 min, refresh token 7 days with rotation on every refresh
- Rate limits (src/middleware/rateLimits.js, in memory, 429 RATE_LIMITED with Retry-After): 100 / 15 min per IP on every /auth route but refresh (generous: a campus shares one Wi-Fi IP), 1000 / 15 min per IP on /auth/refresh, and 10 failed logins / 15 min per IP + normalized email (successes not counted; the brute-force protection). Off in tests unless RATE_LIMIT_IN_TESTS=1 (tests/rateLimits.test.js)
- trust proxy = TRUST_PROXY_HOPS (default 1) only when NODE_ENV=production (Render); elsewhere X-Forwarded-For is not trusted. GET /debug/client-ip (the caller's own req.ip and a count of X-Forwarded-For entries) exists only with DEBUG_CLIENT_IP=1, to check the hop count after a deploy; turn it off right after
- Deployment (render.yaml, docs/deploy-render.md): build `npm ci && npx prisma generate`, start `node scripts/migrate-deploy.js && exec node src/server.js` (the free plan has no pre-deploy command; Prisma's advisory lock and the single instance make it safe; migrations must stay backward compatible because the old instance serves during a deploy). Secrets are `sync: false`; the Firebase key is a Render Secret File at /etc/secrets/firebase-service-account.json. REDIS_URL is not typed: render.yaml links it to the keyvalue service campuspool-redis (plan free, noeviction, ipAllowList [], same region) with fromService connectionString, the internal URL
  - Render uses npm 10. After changing dependencies, regenerate the lock file with `npx npm@10 install` (or check with `docker run --rm -e NODE_ENV=production -v "$PWD:/app" -w /app node:20.20.2 npm ci` in a clean copy of backend/) before pushing: npm 11 once left out @emnapi peers that npm 10's npm ci requires
  - scripts/migrate-deploy.js migrates through DIRECT_URL (Neon direct URL) when set, else DATABASE_URL (pooled in production), with the CLI from node_modules. prisma is a dependency: NODE_ENV=production makes npm ci skip devDependencies, so the start command uses node, not cross-env
  - Startup lists every missing or invalid variable at once (names and rules, never values). Production requires CORS_ORIGIN, MAIL_FROM, FIREBASE_SERVICE_ACCOUNT_PATH and REDIS_URL; an unreadable Firebase file still only disables pushes. Outside production REDIS_URL is required unless ENABLE_JOBS=0
  - The server listens on 0.0.0.0:PORT. SIGTERM (src/lib/shutdown.js, once) stops the outbox relay, closes the sockets and HTTP server while the worker finishes its jobs in flight, then the queue, Redis and Prisma; a failed step is logged by code and the rest still run (exit 1); forced exit 1 after 10 s
  - CORS_ORIGIN in production is the service's own https URL: the Android app sends no Origin, and Socket.io accepts its websocket without one (tests/production.test.js); the handshake token is what protects sockets
- Email: EMAIL_PROVIDER=smtp (Nodemailer, Gmail SMTP for local development) or brevo (POST api.brevo.com/v3/smtp/email with BREVO_API_KEY; Render's free plan blocks outbound SMTP). Same OTP subject and text; MAIL_FROM ("Name <address>", a Brevo-verified sender) is parsed into Brevo's sender. Failures are 503 EMAIL_SEND_FAILED and log only Brevo's status and error code. Tests: nodemailer through moduleNameMapper, Brevo by spying on fetch; setup.js forces smtp
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
- Push notifications (FCM) go through a transactional outbox, a BullMQ queue and a worker. Events (type names in src/lib/notificationTypes.js): booking.requested (driver), booking.accepted / booking.rejected (rider), booking.cancelled by the rider (driver, with wasAccepted), ride.cancelled (riders whose PENDING or ACCEPTED bookings it ended), ride.started (ACCEPTED riders), booking.autoRejected (riders whose PENDING requests the start rejected)
  - Outbox (table Outbox, src/services/outbox.service.js): every event inserts one row per recipient with enqueue(tx, type, recipientIds, payload) INSIDE the transaction of the change, so the row exists exactly when the change committed; the service then calls nudge() after the commit. Who gets notified is still decided in booking.service / ride.service (ride cancel and start read the riders inside the transaction, before the booking update). Reject runs in a transaction for this reason. Payload: { rideId, bookingId?, wasAccepted? }. Statuses PENDING, ENQUEUED, SENT, SKIPPED, FAILED; lastError is a short code, never a message
  - Relay (src/jobs/relay.js): every 1 s and on nudge, one transaction claims up to 100 rows (PENDING, or ENQUEUED for over 5 min: recovery after a Redis restart) with FOR UPDATE SKIP LOCKED, addBulk with jobId = outbox id, marks them ENQUEUED. Redis gets 3 s; on failure the rows stay as they were and it is logged once per outage. BullMQ ignores a jobId it already has, which is what makes a repeated enqueue harmless
  - Worker (src/jobs/notificationWorker.js, concurrency 5): loads the row (missing or finished: nothing), then notification.service deliver(row) re-checks that the event is still true (the EVENTS table there: e.g. booking.accepted only while ACCEPTED, ride.started only while IN_PROGRESS), builds the text, looks up the token at send time and calls fcm.send with android.notification.tag = outbox id and data { type, rideId, bookingId?, outboxId } (strings), priority high. Every row update is conditional on status PENDING or ENQUEUED (PENDING too: the relay may have died before marking)
  - Outcomes: SENT; SKIPPED with a reason (not-configured, unknown-type, TOO_LATE, gone, stale, no-token); the two invalid-token codes clear the token (only if the user still has it) and, like invalid-argument (token kept: it can mean a bad message), end SKIPPED through UnrecoverableError with no retry; anything else is retried (8 attempts, exponential backoff from 5 s, jitter 0.5, about 10 min) and the last failure sets FAILED. Jobs: removeOnComplete 1 h, removeOnFail 7 days, 1000 each. Errors passed to BullMQ carry only the code, the worker's own database errors included (processJob rethrows every error as its code)
  - Maximum age (maxAgeMs in the EVENTS table, exported as MAX_AGE_MS): 30 min for booking.requested and ride.started (the reader has to act now), 6 h for the others, counted from the row's createdAt (the commit). Checked on every attempt right after the type check, before any lookup: an older row ends SKIPPED with lastError TOO_LATE, so a retry can run out of time too
  - Delivery is at least once; the tag and the app's matching slot hide a duplicate
  - Runs inside the web process (src/jobs/index.js startJobs, Render free has no workers) behind ENABLE_JOBS (default on). Redis connections come only from src/lib/redis.js: producer (enableOfflineQueue false, maxRetriesPerRequest 1, so commands fail fast when Redis is away) and worker (maxRetriesPerRequest null, as BullMQ requires); it logs an outage once, by error code, never the URL
  - GET /health adds redis: ok | down | disabled; the status code depends only on the database. `npm run outbox:status` prints counts per status, the age of the oldest PENDING / ENQUEUED row, and rows ENQUEUED for over 1 h (stuck: the job ended but the outcome was not written)
  - bullmq 6 with ioredis 6 (an optional peer of bullmq, so it is a direct dependency)
  - Credentials: FIREBASE_SERVICE_ACCOUNT_PATH (JSON outside the repo, never committed or logged). Unset or unreadable: startup logs it and every row ends SKIPPED (not-configured) before any other DB query. Always off in tests (setup.js empties it). Credential errors log only the path and an error code
  - PUT /users/me/fcm-token {token} (204) stores the token and takes it off any other user (shared phone). Logout clears the user's token, but only when it actually revokes the refresh token
  - firebase-admin is pinned to 13.x: 14 requires Node 22
- Session refresh (mobile): SessionRefresher (lib/core/api) is the only caller of /auth/refresh. The dio AuthInterceptor and the socket share its single-flight call; freshAccessToken() refreshes when the JWT exp is under 60 s away (or forced)
- Live tracking (mobile, lib/features/tracking):
  - RideTrackingConnection turns socket_io_client's reconnection off (it would resend the token the socket was created with). Every attempt is a new socket with a fresh token, backoff 1 s doubling to 30 s, then a re-join whose ack replaces the shown state. A handshake TOKEN_EXPIRED/INVALID_TOKEN or a server-side disconnect forces a refresh; FORBIDDEN and RIDE_NOT_FOUND are final
  - Driver: geolocator stream (high accuracy, 20 m distance filter) in an Android foreground service with an ongoing notification, started from the foreground, so no ACCESS_BACKGROUND_LOCATION. LocationEmitter sends at most one fix per 2.2 s (latest wins) and resends the last fix after 10 s without one, so a stopped car does not look lost
  - The Live ride screen (/rides/:id/live) owns tracking: closing it, or the ride ending, stops the tracker and disconnects. The driver leaving while IN_PROGRESS is asked first. Start ride checks location permission and GPS before calling /start
  - Riders: the marker glides between updates; "Last updated" uses the phone's receive time (the server's recordedAt, never in the future, for the join ack); a warning shows after 30 s without an update
- Push (mobile, lib/features/notifications): firebase_core, firebase_messaging, flutter_local_notifications behind a PushMessaging interface (DisabledPushMessaging when Firebase fails to start, and in tests)
  - PushTokenController follows authProvider: on sign-in it asks for the notification permission (this also shows the tracking notification on Android 13+), gets the token and PUTs /users/me/fcm-token; a token refresh is uploaded only while signed in; sign-out deletes the token on the device (the server clears it on logout). Steps run one at a time; failures are logged, never shown
  - Uses the deprecated getToken/onTokenRefresh/deleteToken on purpose: register/onRegistered hand out a FID, but the backend sends to registration tokens
  - Foreground messages are shown by flutter_local_notifications on the ride_updates channel (high importance; also the manifest's default channel, icon ic_notification and colour brand_blue)
  - Foreground notifications use the slot (tag = data.outboxId, id 0), the one FCM uses for the tagged background notification, so a duplicate delivery replaces the first whichever way each copy arrived (notificationSlotFor); without an outboxId the id is time-based
  - A tap (background, terminated or foreground) goes through routeForPush: ride.started opens the Live ride screen, every other event the ride detail; no rideId does nothing. The app matches the API's type names (it used to compare with 'rideStarted', which the API never sent). PushNavigator holds the route until signed in, then go() from splash or public routes, push() elsewhere
  - Signed-in routes are nested under the home route (Routes.child), so a deep link lands on [home, ride] and Back returns home
  - Profile shows "Notifications on/off" with a link to the app settings, re-checked when the app resumes
- Theme: lib/core/theme/app_theme.dart owns field, button, card and snack bar styling (screens don't set borders), light and dark (follows the system). RideColors (ThemeExtension) holds the start/end/pickup colours; map pins always use the light set
- Every main screen must fit a 320 x 568 dp phone at 1.3x text, with data, offline and empty: test/small_screens_test.dart
- Build config (lib/core/config/app_config.dart, AppConfig.resolve): APP_ENV dev|prod; API_BASE_URL is required in a release build and in prod, prod requires https; the 10.0.2.2 default is for debug builds only. No URL is hardcoded; a bad config shows MisconfiguredApp. The Render URL is passed with --dart-define after deployment
- Release: app label CampusPool, adaptive vector launcher icon (replaceable with flutter_launcher_icons, see mobile/README.md). Signing reads android/key.properties (gitignored, template key.properties.example) pointing at a keystore outside the repo; without it the release build uses the debug key with a Gradle warning. android/app/google-services.json is gitignored and required to build

## Known gaps (decided, not forgotten)
- First follow-up: upgrade to Node 22 (and firebase-admin 14, which requires it). The launch runs NODE_VERSION=20, which reached end of life in April 2026
- TRUST_PROXY_HOPS=1 is unverified on Render (Render doesn't document its proxy count; one report says 3): check with /debug/client-ip after the first deploy and record the result here
- Render free plan: the service sleeps after ~15 min idle and takes 30-60 s to wake, longer than the app's 10 s request timeout; wake it with /health before a demo. Sleeps and deploys drop sockets and forget last locations and rate-limit counts
- OTP emails from a free-mail sender through Brevo may land in spam; authenticating an owned domain in Brevo is the fix
- Rate-limit counts live in one process's memory, like the location store: another reason the API must run as a single instance, and a restart resets them (Redis is there now, but only the notification queue uses it)
- Plus-addressing (a+1@, a+2@) can create duplicate accounts: accepted for the MVP
- Access tokens stay valid up to 15 minutes after logout: accepted
- Expired refresh tokens are never deleted: cleanup job planned for Part B
- Signup 409 and resend 429 reveal account state: accepted by design
- A refresh that times out, or returns 200 with a body the client can't parse, after the server already rotated the token makes the retry look like reuse, which logs the user out everywhere. Accepted for the MVP; possible fix is a short server-side grace window.
- OPEN rides past their departure time still show as OPEN in /rides/mine (nothing moves them to COMPLETED); the app must show them as expired
- OPEN/FULL seat changes emit no socket event (bookings and ride cancels now send push notifications instead)
- One FCM token per user: only the most recently registered device gets notifications, and logging out on any device clears it
- Notification jobs pause while the free service sleeps (relay and worker live in the web process): a retry scheduled for later goes out at the next wake, possibly late; the re-check drops it if the event is no longer true, and the maximum age drops it once it is past its type's limit (TOO_LATE). Within the limit a late one is still sent: a "new request" can arrive up to 30 min after it was made
- Free Key Value keeps nothing across a restart: jobs in flight are re-enqueued from the outbox only after 5 minutes
- Notifications are delivered at least once and in no guaranteed order (5 at a time, retries): two events about one booking can arrive swapped
- A row stays ENQUEUED for ever if its job ended but the outcome could not be written (database down at that moment) while the kept job blocks a re-enqueue; `npm run outbox:status` reports these (ENQUEUED for over 1 h), nothing fixes them automatically
- Finished outbox rows (SENT, SKIPPED, FAILED) are never deleted: they get pruned by the B3 cleanup job
- The Outbox.type column is free text checked in code (enqueue refuses unknown types), not a database enum
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
- Android asks for the notification permission only a limited number of times: after a denial the app can only point to the system settings (Profile does). With it off, pushes and the tracking notification are hidden; tracking still runs
- The ride_updates channel is created on the app's first start: a push that arrives before the first launch lands on FCM's fallback channel
- A notification tap always opens the ride, even when the booking or ride has changed since; the screen then shows its current state
- A rider whose booking is cancelled during the ride is removed from the room without an event: their screen just stops getting updates (and shows the 30 s warning) until a reconnect, whose join is refused
- The 10 s heartbeat resends the last fix, so "Last updated" shows that the driver's app is alive, not that the car moved
