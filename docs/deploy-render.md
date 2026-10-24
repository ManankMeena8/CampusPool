# Deploying the API to Render (free plan)

The API runs as one Render **free web service** in **Singapore**, next to a separate production
database in **Neon, AWS ap-southeast-1 (Singapore)**. Render builds it from
[render.yaml](../render.yaml) at the repo root. OTP emails go through **Brevo's HTTP API**,
because Render's free web services block outbound SMTP (ports 25, 465 and 587).

Commands below are PowerShell on Windows. Use `curl.exe`, not `curl`: in Windows PowerShell 5.1,
`curl` is an alias for `Invoke-WebRequest`.

What Render runs (from `render.yaml`):

| Step         | Command                                                     |
| ------------ | ----------------------------------------------------------- |
| Build        | `npm ci && npx prisma generate` (in `backend/`)             |
| Start        | `node scripts/migrate-deploy.js && exec node src/server.js` |
| Health check | `GET /health` (checks the database and PostGIS)             |

The free plan has no pre-deploy command, so `prisma migrate deploy` runs at the start of every
boot. That is safe with one instance:

- Prisma takes a Postgres advisory lock while migrating, so two runs never apply the same
  migration twice.
- If a migration fails, the start command exits before the server starts, the deploy fails, and
  Render keeps the previous version serving.
- While a new version deploys, the old one keeps serving on the old code. **Migrations must stay
  backward compatible**: add columns and tables first, and remove old ones in a later deploy.
- Each wake from sleep re-runs the step. With nothing pending, that is a no-op of a second or two.

---

## 1. Production database (Neon)

Use a **new Neon project**, never the dev data.

1. In the Neon console, click **New project**:
   - Name: `campuspool-prod`
   - Cloud and region: **AWS, Asia Pacific (Singapore) `ap-southeast-1`**
   - Postgres version: the same as the dev project (the tests use Postgres 18)
2. Open **Connect** on the project dashboard and copy two connection strings for the default
   database and role:
   - **Pooled** (connection pooling on; the host contains `-pooler`). This becomes `DATABASE_URL`.
   - **Direct** (connection pooling off). This becomes `DIRECT_URL`. Migrations need a direct
     connection; `scripts/migrate-deploy.js` uses it only for `prisma migrate deploy`.

   Keep both strings, including `?sslmode=require`, in your password manager, not in a file in
   the repo.

3. **PostGIS:** migration `20261008000000_enable_postgis` runs
   `CREATE EXTENSION IF NOT EXISTS postgis`, and Neon lets the project owner role do that, so
   nothing needs doing by hand. After the first deploy, `/health` returning `"db": "ok"` confirms
   it, because it calls `postgis_version()`. If the deploy log shows that extension step failing,
   run `CREATE EXTENSION IF NOT EXISTS postgis;` in the Neon **SQL Editor** on the production
   database, then redeploy.

### Fallback: Neon won't create a second project

If the free plan refuses a second project, keep the production data in the **existing us-east-2
project**, and move the API next to it instead:

1. In the existing project, create a **new database** (for example `campuspool_prod`) on the
   main branch: **Databases → New database**. A new database starts empty. A branch would copy
   the dev data, so don't use one.
2. Use that database's pooled and direct connection strings as above.
3. Change `region: singapore` to **`region: ohio`** in `render.yaml` and commit it **before**
   creating the service: Render can't change a service's region later.

Dev and production then share one compute and the free plan's limits. Never point a dev `.env`
at `campuspool_prod`.

---

## 2. Email sender (Brevo)

1. Create a free account at brevo.com (300 emails a day).
2. Go to **Senders, Domains & Dedicated IPs → Senders → Add a sender**. Enter a name
   (`CampusPool`) and an address you can read, then click the link in Brevo's confirmation email.
   Brevo only sends from verified senders.
3. Go to **SMTP & API → API Keys → Generate a new API key**, name it `campuspool-render`, and
   copy it. Brevo shows it only once. Don't confuse it with the SMTP key on the same page.
4. `MAIL_FROM` is then `CampusPool <the-verified-address>`.

A sender at a free-mail domain (such as gmail.com) works, but may land in spam or be rewritten by
Brevo. Check the spam folder during the smoke test. Authenticating a domain you own in Brevo is
the long-term fix.

---

## 3. Secrets to prepare

Generate a **new** `JWT_ACCESS_SECRET` for production. Never reuse the dev one: it signs access
tokens and also hashes the OTP codes, so anyone holding the dev `.env` could otherwise mint
production tokens.

```powershell
node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"
```

Firebase service account: in the Firebase console, open the **same project** as the app's
`google-services.json`, then **Project settings → Service accounts → Generate new private key**.
Use a production-only key, separate from the dev one, so either can be revoked on its own. The
downloaded JSON stays outside the repo. You upload it to Render in step 5.

---

## 4. Create the service from render.yaml

1. Push the branch containing `render.yaml` to GitHub.
2. In the Render dashboard, click **New → Blueprint**, connect the repo, and select the branch.
   Render reads `render.yaml` and shows one web service, `campuspool-api`, region **Singapore**
   (or Ohio with the fallback above), plan **Free**.
3. Render asks for every `sync: false` variable. **This prompt appears only at creation**: a
   variable added to `render.yaml` later must be added by hand in **Environment**. Fill them in
   from the table below.
4. Click **Apply**. The first deploy starts and serves requests, but push notifications stay off
   until the Secret File exists: the log says `cannot read /etc/secrets/... (ENOENT)`. Continue
   with step 5.

The service URL is `https://campuspool-api.onrender.com`, unless Render shows a different one on
the service page because the name is taken. If it differs, change `CORS_ORIGIN` to match.

### Environment variables

| Variable                                           | What it is                                               | Where to get it                                              | Differs from dev?            |
| -------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------ | ---------------------------- |
| `NODE_ENV`                                         | `production`                                             | Set in `render.yaml`                                         | **Yes**                      |
| `NODE_VERSION`                                     | `20` (Render's Node version)                             | Set in `render.yaml`                                         | No                           |
| `PORT`                                             | Port to listen on                                        | Set by Render (10000). **Don't set it**                      | n/a                          |
| `DATABASE_URL`                                     | Neon **pooled** URL (`-pooler` host), used by the app    | Neon production project → Connect, pooling on                | **Yes**, a separate database |
| `DIRECT_URL`                                       | Neon **direct** URL, used only for migrations            | Neon production project → Connect, pooling off               | **Yes**                      |
| `JWT_ACCESS_SECRET`                                | Signs access tokens and hashes OTP codes; 32+ characters | The `node -e` one-liner above                                | **Yes, newly generated**     |
| `ALLOWED_EMAIL_DOMAIN`                             | Only `@<domain>` emails can sign up                      | `nsut.ac.in`, the app's default                              | No (must match the app)      |
| `EMAIL_PROVIDER`                                   | `brevo`                                                  | Set in `render.yaml`                                         | **Yes** (dev uses `smtp`)    |
| `BREVO_API_KEY`                                    | Brevo API key                                            | Brevo → SMTP & API → API Keys                                | Production only              |
| `MAIL_FROM`                                        | `CampusPool <verified sender>`                           | The sender verified in Brevo                                 | Usually                      |
| `CORS_ORIGIN`                                      | The service's own URL, no trailing slash                 | The service page, e.g. `https://campuspool-api.onrender.com` | **Yes** (dev: `*`)           |
| `FIREBASE_SERVICE_ACCOUNT_PATH`                    | `/etc/secrets/firebase-service-account.json`             | Set in `render.yaml`; the file is a Secret File (step 5)     | **Yes** (path)               |
| `ROUTING_BASE_URL`                                 | OSRM server                                              | Leave unset: defaults to the public demo server              | No                           |
| `TRUST_PROXY_HOPS`                                 | Proxies in front of the API, for the client IP           | Leave unset (1) unless step 7 shows otherwise                | Production only              |
| `DEBUG_CLIENT_IP`                                  | `1` turns on `GET /debug/client-ip`                      | Leave unset; only for step 7                                 | Production only              |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` | Gmail SMTP for local development                         | Not used on Render                                           | Dev only                     |

The API checks these at startup and exits with a list of the variable names that are missing or
invalid, never their values. The list appears in the Render deploy log.

`CORS_ORIGIN` doesn't affect the app: Android sends no `Origin` header, and Socket.io accepts the
app's websocket connection with this setting (covered by `backend/tests/production.test.js`).
The access token in the handshake is what protects sockets. `*` is refused in production, so the
service's own URL is the value to use.

---

## 5. Upload the Firebase key as a Secret File

1. Open the service → **Environment → Secret Files → Add Secret File**.
2. Filename: `firebase-service-account.json` (exactly; Render serves it at
   `/etc/secrets/firebase-service-account.json`).
3. Paste the whole JSON file's contents, then save.
4. Click **Manual Deploy → Deploy latest commit**.
5. In **Logs**, look for `[notifications] push notifications are enabled`. A line saying
   `cannot read /etc/secrets/... (ENOENT)` means the filename doesn't match.

---

## 6. Smoke tests

Set the URL once:

```powershell
$api = "https://campuspool-api.onrender.com"
```

**Health.** The first request after sleep can take up to a minute:

```powershell
curl.exe -s "$api/health"
# {"status":"ok","db":"ok"}
```

**Sign up with a real NSUT email and receive the OTP:**

```powershell
$email = "your.name@nsut.ac.in"
$password = Read-Host "Password (8-72 chars, a letter and a digit)"
$json = @{ name = "Your Name"; email = $email; password = $password } | ConvertTo-Json
Invoke-RestMethod -Method Post "$api/auth/signup" -ContentType "application/json" -Body $json
# Check the inbox (and spam) for "Your CampusPool verification code"
$code = Read-Host "Code from the email"
$json = @{ email = $email; code = $code } | ConvertTo-Json
$session = Invoke-RestMethod -Method Post "$api/auth/verify-otp" -ContentType "application/json" -Body $json
```

A `503 EMAIL_SEND_FAILED` means Brevo refused the email. The log line `Failed to send OTP email:
Brevo answered <status>, <code>` says why: `401 unauthorized` is a wrong key, and a sender error
means `MAIL_FROM` isn't a verified sender.

**Log in:**

```powershell
$json = @{ email = $email; password = $password } | ConvertTo-Json
$session = Invoke-RestMethod -Method Post "$api/auth/login" -ContentType "application/json" -Body $json
$auth = @{ Authorization = "Bearer $($session.accessToken)" }
```

**Post a ride and search for it.** Posting needs the DRIVER or BOTH role; new accounts are
RIDER. The role is read from the database on every request, so the same token works right away:

```powershell
Invoke-RestMethod -Method Patch "$api/users/me" -Headers $auth -ContentType "application/json" -Body '{"role":"BOTH"}'

$departs = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ")
$ride = @{
  start = @{ lat = 28.6096; lng = 77.0384; address = "NSUT Main Gate, Dwarka" }
  end   = @{ lat = 28.5813; lng = 77.0583; address = "Sample destination, Dwarka" }
  departureTime = $departs; seats = 3; pricePerSeat = 0
} | ConvertTo-Json
$created = Invoke-RestMethod -Method Post "$api/rides" -Headers $auth -ContentType "application/json" -Body $ride
$created.ride.id

$from = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$to = (Get-Date).ToUniversalTime().AddHours(12).ToString("yyyy-MM-ddTHH:mm:ssZ")
Invoke-RestMethod -Headers $auth "$api/rides/search?pickupLat=28.6096&pickupLng=77.0384&dropLat=28.5813&dropLng=77.0583&from=$from&to=$to"
```

The search must list the ride. `$created.ride.distanceMeters` set means OSRM answered; if it's
empty, OSRM was unreachable (the log says `Routing unavailable`), and the ride is still created
without a route.

**Connect a socket.** Run this from `backend/`, where `socket.io-client` is installed:

```powershell
cd backend
$env:API = $api; $env:TOKEN = $session.accessToken; $env:RIDE = $created.ride.id
node -e "const {io}=require('socket.io-client');const s=io(process.env.API,{transports:['websocket'],auth:{token:process.env.TOKEN}});s.on('connect',async()=>{console.log('connected');console.log(await s.timeout(5000).emitWithAck('ride:join',{rideId:process.env.RIDE}));s.close()});s.on('connect_error',e=>{console.log('connect_error',e.message,e.data);process.exit(1)})"
Remove-Item Env:TOKEN, Env:RIDE, Env:API
```

Expected output: `connected`, then `{ ok: true, ride: { id: ..., status: 'OPEN' }, ... }`.

Clean up afterwards: cancel the test ride (`Invoke-RestMethod -Method Post
"$api/rides/$($created.ride.id)/cancel" -Headers $auth`). Then run the two-phone test in
[manual-e2e-test.md](manual-e2e-test.md) with the release APK.

---

## 7. Check the client IP (trust proxy)

The rate limits key on `req.ip`. Express takes it from `X-Forwarded-For`, counting
`TRUST_PROXY_HOPS` entries from the end (default 1). Render doesn't document how many proxies
it puts in front of a service, so check it once after the first deploy:

- **Too low:** every user appears as Render's proxy IP, and everyone shares one `/auth` limit.
- **Too high:** a client can choose its own IP by sending the header itself, and escape the
  limits.

1. In **Environment**, add `DEBUG_CLIENT_IP` = `1` and save. Render redeploys.
2. Look up your public IP, for example at <https://api.ipify.org>, from the same network.
3. Call the route plainly, then with a forged header:

   ```powershell
   curl.exe -s "$api/debug/client-ip"
   curl.exe -s -H "X-Forwarded-For: 1.2.3.4" "$api/debug/client-ip"
   ```

   Each call returns `{ ip, forwardedForEntries, trustProxyHops }`: only your own IP and a count,
   never the proxies' addresses. The response is your own IP, so nothing is exposed to anyone
   else.

4. Read the results:
   - Both calls show **your public IP**: correct. Done.
   - The forged call shows **`1.2.3.4`**: too many hops. Lower `TRUST_PROXY_HOPS`.
   - Both show an IP that **isn't yours** (a Render or Cloudflare address): too few. Set
     `TRUST_PROXY_HOPS` to 2 and repeat. `forwardedForEntries` on the plain call is the most
     it can ever need to be.
5. **Turn it off right after checking:** delete `DEBUG_CLIENT_IP` (or set it to `0`). While it
   is on, the startup log warns `GET /debug/client-ip is on`. When it is off, the route returns 404.

Record the result (the hop count that worked) in the project notes.

---

## 8. Cold starts on the free plan

- The service **sleeps after about 15 minutes without incoming requests**. The next request
  wakes it, which takes **about 30 to 60 seconds** (the boot also runs the migration check).
- The app gives up after 10 seconds per request, so a sleeping server looks like "can't reach
  the server" in the app. Open sockets and live tracking also drop when the service sleeps or
  redeploys, and the app reconnects.
- Last driver locations and rate-limit counters live in memory: a sleep or deploy forgets them.

**Before a demo:** about 2 minutes ahead, run `curl.exe -s "$api/health"` (or open the URL in a
browser) and wait for `{"status":"ok","db":"ok"}`. Then open the app. Any request keeps it awake
for another 15 minutes, so keep using it, or call `/health` again if there's a pause.

Don't keep it awake around the clock with an external pinger: every `/health` also wakes the
Neon database, whose free compute hours are limited.

---

## 9. Release APK with the Render URL

From `mobile/`, with `android/app/google-services.json` in place, and `android/key.properties`
for a properly signed build (see [mobile/README.md](../mobile/README.md)):

```powershell
flutter build apk --release --dart-define=APP_ENV=prod --dart-define=API_BASE_URL=https://campuspool-api.onrender.com
```

- No trailing slash. `APP_ENV=prod` requires `https://`; a wrong value opens the app's
  "misconfigured" screen instead of failing on every request.
- If the backend's `ALLOWED_EMAIL_DOMAIN` isn't `nsut.ac.in`, add
  `--dart-define=ALLOWED_EMAIL_DOMAIN=<same domain>`.
- The APK is at `build/app/outputs/flutter-apk/app-release.apk`. Wake the service first (step 8),
  then install it and sign in.

---

## Redeploys and later changes

- A push to the connected branch redeploys automatically. Render sends SIGTERM to the old
  instance, which closes its sockets and database connections; the app reconnects.
- A new environment variable added to `render.yaml` isn't prompted for on later syncs: add it in
  **Environment** by hand.
- The API must stay a **single instance**: live locations, the location throttle and the rate
  limits live in the process's memory.
