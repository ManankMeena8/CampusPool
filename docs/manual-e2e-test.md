# Manual end-to-end test (two phones)

About 60-75 minutes. **Phone A** is the driver, **Phone B** the rider. Tick each box; anything that
doesn't match "Expect" is a bug: note the step number, both phones' screens and the API log.

## 0. Preparation

- [ ] Laptop and both phones are on the same Wi-Fi. Find the laptop's IP (`ipconfig`, IPv4
      Address, for example `192.168.1.20`).
- [ ] Windows firewall allows Node.js on private networks (or allow inbound TCP 3000).
- [ ] `backend/.env` has working SMTP settings and `FIREBASE_SERVICE_ACCOUNT_PATH` pointing at the
      service account of the same Firebase project as `mobile/android/app/google-services.json`.
- [ ] `cd backend && npm run migrate:deploy && npm run dev`. Expect the log to say
      `push notifications are enabled`.
- [ ] From a phone's browser, open `http://<laptop IP>:3000/health`. Expect a JSON response.
- [ ] Install on both phones (USB debugging, one at a time):
      `cd mobile && flutter run --release --dart-define=API_BASE_URL=http://<laptop IP>:3000`.
      `APP_ENV` stays `dev`, which allows http (only `prod` requires https). The app and
      `backend/.env.example` both use `nsut.ac.in`; only if your `backend/.env` uses another
      domain, add `--dart-define=ALLOWED_EMAIL_DOMAIN=<that domain>`.
- [ ] You need two email inboxes at the allowed domain. If you have only one, create the driver
      with `npm run seed:dev -- <driver email> <password>` and test signup on Phone B only.
- [ ] Both phones: location on, notifications allowed when asked, battery saver off.

## 1. Signup, OTP and login (Phone B)

| # | Do | Expect |
| --- | --- | --- |
| 1.1 | Open the app | Splash, then Log in |
| 1.2 | Sign up with an email at another domain | Error under the email field; no request sent |
| 1.3 | Sign up with a weak password (`password`) | Error: needs a number |
| 1.4 | Sign up with valid name, email, password | "Verify your email"; an email with a 6-digit code arrives |
| 1.5 | Enter a wrong code | Error, still on the screen |
| 1.6 | Tap "Resend code" before the countdown ends | Button disabled, shows "Resend code in m:ss" |
| 1.7 | Enter the newest code | Home screen, signed in |
| 1.8 | Profile → Log out, then log in with a wrong password | Error, no sign-in |
| 1.9 | Log in with the right password | Home |
| 1.10 | Kill the app and reopen | Goes straight to Home (session kept) |

Repeat 1.4-1.7 on **Phone A** (or log in with the seeded driver).

## 2. Roles

| # | Do | Expect |
| --- | --- | --- |
| 2.1 | Phone B (role Ride): Home → Offer a ride, fill in and post | Refused with a message pointing to Profile; no ride created |
| 2.2 | Phone A: Profile → "I want to" → Drive (or Both) | Saved; Profile shows the new role |
| 2.3 | Phone A: Profile shows "Notifications on" | If off, the link opens the app's system settings |

## 3. Post a ride (Phone A)

| # | Do | Expect |
| --- | --- | --- |
| 3.1 | Offer a ride → pick From and To on the map less than 200 m apart | Error on To |
| 3.2 | Set departure 5 minutes from now | Error: at least 15 minutes from now |
| 3.3 | From: a spot near you; To: 1-5 km away; departure **20 minutes from now**; 2 seats; price 30; a note → Post ride | Ride detail opens with a route line on the map, status Open, 2 seats left |
| 3.4 | Try to post a second ride departing 30 minutes later | Refused: overlaps the first (1-hour rule) |
| 3.5 | Home → My rides | The ride is listed as Open |

## 4. Search and request (Phone B)

| # | Do | Expect |
| --- | --- | --- |
| 4.1 | Find a ride: pickup within 1 km of A's From, drop within 1 km of A's To, a time window around the departure → Search rides | A's ride is listed with the pickup distance |
| 4.2 | Search with a drop on the other side of town | No results, empty state with "Change search" |
| 4.3 | Open A's ride → "Request seat" | "Seat requested. The driver will accept or reject it."; panel shows Pending |
| 4.4 | Phone A | Push "new seat request" within a few seconds; tapping it opens the ride detail |
| 4.5 | Phone B: open the same ride from search again | Shows the existing booking; no second Request button |

## 5. Reject, cancel, accept

| # | Do | Expect |
| --- | --- | --- |
| 5.1 | Phone A: ride detail → Seat requests → Reject → confirm | "Request rejected."; Phone B gets a "rejected" push |
| 5.2 | Phone B: My bookings | Booking shows Rejected |
| 5.3 | Phone B: search again and request again | New Pending request; Phone A gets a push |
| 5.4 | Phone B: Cancel booking → "Keep request" | Nothing changes |
| 5.5 | Phone B: Cancel booking → confirm | "Booking cancelled."; Phone A gets a push and the request disappears |
| 5.6 | Phone B: request once more; Phone A: Accept | "Request accepted."; Phone B gets an "accepted" push; seats left drops to 1 |
| 5.7 | Phone A: My rides; Phone B: My bookings | Ride Open with 1 seat left; booking Accepted |

## 6. Start the ride

| # | Do | Expect |
| --- | --- | --- |
| 6.1 | Phone A: turn GPS off, tap Start ride | "Location needed" (or a GPS prompt); ride not started |
| 6.2 | GPS on → Start ride → confirm | Live ride screen; an ongoing "Live ride tracking" notification appears; status In progress |
| 6.3 | Phone B | "Ride started" push; tapping it opens the Live ride screen directly |
| 6.4 | Phone B (if it was on the ride detail) | "Track ride" button visible |

## 7. Live tracking

Walk or drive at least 50 m with Phone A between checks (the GPS filter ignores moves under 20 m).

| # | Do | Expect |
| --- | --- | --- |
| 7.1 | Phone A moves | Phone B's car marker glides to the new position within ~3 s; "Last updated" stays under a few seconds |
| 7.2 | Phone A stands still for a minute | Phone B keeps showing "Last updated" refreshing about every 10 s (heartbeat), no warning |
| 7.3 | Phone A: airplane mode for 45 s | Phone B shows the "no updates" warning after ~30 s |
| 7.4 | Phone A: airplane mode off | A reconnects by itself; Phone B's marker updates and the warning clears |
| 7.5 | Phone B: airplane mode for 20 s, then off | B reconnects, shows the latest position |
| 7.6 | Phone B: press Back, then reopen via My bookings → Track ride | Rejoins and shows the current position |
| 7.7 | Phone A: press Home (app in background) and keep moving | Tracking notification stays; Phone B keeps getting updates |
| 7.8 | Phone A: back in the app, press Back on Live ride | "Stop sharing your location?" → "Keep driving" stays on the screen |
| 7.9 | (Optional, long ride) Keep tracking for over 15 minutes | No interruption when the access token expires (it reconnects with a refreshed token) |

## 8. Push in the background and when killed (Phone B)

Use a second ride (section 10) or redo a request on another ride to trigger pushes.

| # | Do | Expect |
| --- | --- | --- |
| 8.1 | Phone B in the background; trigger an event from A | Notification shows; tap opens the ride |
| 8.2 | Swipe Phone B's app away; trigger an event | Notification shows; tap launches the app and opens the ride, Back goes to Home |
| 8.3 | Phone B in the foreground; trigger an event | A heads-up notification still shows |

## 9. Complete the ride

| # | Do | Expect |
| --- | --- | --- |
| 9.1 | Phone A: End ride → "End this ride?" → confirm | Live screen closes, tracking notification goes away, ride Completed |
| 9.2 | Phone B | Live screen shows the ride ended and stops updating (no push for completion: known gap) |
| 9.3 | Both: My rides / My bookings | Ride Completed; booking Accepted on a completed ride |
| 9.4 | Phone B: try Cancel booking on the completed ride | Not offered, or refused |

## 10. Cancellations (a second ride)

| # | Do | Expect |
| --- | --- | --- |
| 10.1 | Phone A: post a ride 2+ hours away (outside the 1-hour rule); B requests, A accepts | As in 4-5 |
| 10.2 | Phone B: Cancel booking (accepted) → confirm | Phone A gets a push saying an accepted rider cancelled; seats go back up |
| 10.3 | Phone B requests again; Phone A accepts; Phone A: Cancel ride → confirm | Phone B gets "ride cancelled" push; booking shows Ride cancelled |
| 10.4 | Phone A: post a ride 2+ hours away with 1 seat; B requests; A accepts | Ride shows Full |
| 10.5 | Phone A: Start ride | Refused: too early (only from 30 minutes before departure) |

## 11. Error, empty and display states

| # | Do | Expect |
| --- | --- | --- |
| 11.1 | Stop the API (`Ctrl+C`); on either phone open My rides | Error state with Retry; no crash |
| 11.2 | Start the API again → Retry | Data loads |
| 11.3 | A fresh account: My rides and My bookings | Empty states with a hint |
| 11.4 | Switch the phone to dark mode | All screens readable; map pins keep their colours |
| 11.5 | Set the phone's font size to the largest | Main screens scroll, nothing cut off |
| 11.6 | Turn notifications off for the app in system settings, return to Profile | Shows "Notifications off" |

## 12. Sessions and devices

| # | Do | Expect |
| --- | --- | --- |
| 12.1 | Phone A: Log out; Phone B: request a seat on an open ride of A's | Phone A gets no push (logout cleared its token) |
| 12.2 | Phone A: log in again; B triggers another event | Push arrives again |
| 12.3 | Log in to A's account on Phone B, then trigger a push for A | Only Phone B gets it (one device per user: known gap) |

## After the run

- Check the API log for `INTERNAL_ERROR` stack traces or `[background] ... failed` lines.
- Delete test rides or accounts only from the dev database, never from production.
