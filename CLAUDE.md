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
- Never commit .env files

## Decisions so far
- Backend: Express 4, Prisma 6; controllers are wrapped in asyncHandler (no try/catch)
- Tests use TEST_DATABASE_URL (a separate Neon branch), never the dev database
- Auth: access token 15 min, refresh token 7 days with rotation on every refresh

## Known gaps (decided, not forgotten)
- Login rate limiting by IP + email: add in Phase 7.1 (trust proxy = 1 on Render, limiter disabled in tests)
- Plus-addressing (a+1@, a+2@) can create duplicate accounts: accepted for the MVP
- Access tokens stay valid up to 15 minutes after logout: accepted
- Expired refresh tokens are never deleted: cleanup job planned for Part B
- Signup 409 and resend 429 reveal account state: accepted by design
- A refresh that times out, or returns 200 with a body the client can't parse, after the server already rotated the token makes the retry look like reuse, which logs the user out everywhere. Accepted for the MVP; possible fix is a short server-side grace window.
