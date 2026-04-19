# Quickstart — bring up GpsLogger with Claude Code

This guide walks a new user from a freshly cloned repo to a phone that's
recording GPS points and a browser tab visualizing the route, using
[Claude Code](https://claude.com/claude-code) as the assistant. Every
step shows the actual prompt you can paste; Claude Code does the work.

The rest of the project (architecture, schema, filter pipeline) is
covered in [`README.md`](README.md). This doc is purely the
"how do I start using it from zero" path.

## What you need installed before talking to Claude Code

These are prerequisites Claude Code cannot install for you (they need
GUI consent, App Store, or your Apple ID):

- **macOS** with **Xcode 15+** (App Store).
- **Docker Desktop** running.
- **Homebrew** (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`).
- A **free Apple ID** added to *Xcode → Settings → Accounts* (paid
  Developer Program is **not** required — the free tier signs apps for
  7 days at a time).
- An **iPhone** running iOS 16+ on the **same Wi-Fi** as the Mac.
- Claude Code itself: `npm install -g @anthropic-ai/claude-code`, then
  run `claude` inside the cloned repo.

Everything else (xcodegen, the Xcode project, signing config, the
docker stack, IP discovery, build, install, launch) Claude Code can
do for you with the prompts below.

## Step 1 — clone the repo and open Claude Code

```bash
git clone https://github.com/<you>/GpsLogger.git
cd GpsLogger
claude
```

You're now in an interactive Claude Code session at the repo root.

## Step 2 — bring up the backend stack

**Prompt:**

> Bring up the docker-compose stack and confirm the backend is healthy.

What Claude Code will do:

1. `docker compose up -d --build` — starts `db`, `db-backup`,
   `backend`, and `frontend`.
2. `curl -fsS http://localhost:3000/health` — expects `{"ok":true}`.
3. `curl -fsS http://localhost:3001/` — expects HTML.

If anything fails (Docker not running, port 3000/3001/5434 occupied,
migration error), Claude Code reads the relevant logs
(`docker compose logs backend`) and reports the diagnosis. Common
fixes:

- **Port 3000 / 3001 / 5434 already in use** → ask Claude Code to
  identify the process holding the port (`lsof -nP -iTCP:3000`).
- **Docker Desktop not running** → start it from /Applications and
  re-run the prompt.

When the stack is healthy, open <http://localhost:3001/> in a browser.
You should see the UI; it'll be empty (no device has uploaded points
yet) — that's expected.

## Step 3 — configure the iOS xcconfig (LAN IP + Apple Team ID)

The iPhone needs to know the Mac's LAN IP so it can reach
`backend:3000` over Wi-Fi. The signing config needs your Apple Team ID.
Both live in a gitignored file at `ios/GpsLogger.xcconfig` (created
from `ios/GpsLogger.xcconfig.example`).

**Prompt:**

> Find my Mac's current LAN IP and my Apple Team ID, then create
> `ios/GpsLogger.xcconfig` from the `.example` template with both
> values filled in. The API_BASE_URL should point at the LAN IP on
> port 3000. Then run `xcodegen generate` inside `ios/` so the
> `.xcodeproj` is regenerated with the new values.

What Claude Code will do:

1. `ipconfig getifaddr en0` (or `en1`) — your current Wi-Fi IP, e.g.
   `192.168.1.129`.
2. `security find-identity -p codesigning -v` — your Team ID is the
   parenthesized string after your Apple ID, e.g. `(ABCDE12345)`.
3. `cp ios/GpsLogger.xcconfig.example ios/GpsLogger.xcconfig` and
   substitute both values. The `API_BASE_URL` line uses the
   `http:/$()/192.168.1.129:3000` escape — `$()` is an empty
   variable expansion that breaks up the `//` so xcconfig doesn't
   read the rest of the line as a comment. After parsing the value
   is plain `http://192.168.1.129:3000`.
4. `xcodegen generate` inside `ios/` — produces
   `ios/GpsLogger.xcodeproj` from `project.yml`.

> **Caveat — moving between networks.** The IP is captured at build
> time. If you move between networks (home → office → cafe), ask
> Claude Code: *"My Mac's LAN IP changed. Update the xcconfig and
> rebuild."* The faster path is the runtime override:
> `defaults write com.gpslogger.personal apiBaseURL "http://<new-ip>:3000"`
> on the iPhone — this works without a rebuild and survives until you
> uninstall the app.

## Step 4 — install the app on your iPhone

Make sure the iPhone is connected (USB or Wi-Fi pairing — *Devices &
Simulators* in Xcode shows it).

**Prompt:**

> Build the iOS app for my connected iPhone and install it. Use
> `xcrun xctrace list devices` to find the UDID, then build with
> `xcodebuild` and install with `devicectl`. Launch the app afterward.

What Claude Code will do:

1. `xcrun xctrace list devices` — picks the physical iPhone (not a
   simulator).
2. `xcodebuild build -project ios/GpsLogger.xcodeproj -scheme GpsLogger
    -destination "id=<UDID>" -configuration Debug`
   — produces `GpsLogger.app` under `~/Library/Developer/Xcode/DerivedData/...`.
3. `xcrun devicectl device install app --device <UDID> <APP>`
4. `xcrun devicectl device process launch --device <UDID> com.gpslogger.personal`

If signing fails on the **first** install, the iPhone won't trust the
developer profile yet. On the iPhone:

> Settings → General → VPN & Device Management → tap your Apple ID →
> *Trust*

Then re-run the install. After this one-time trust, future installs
(including the 7-day re-signs) need no extra taps.

## Step 5 — first run + permissions

When the app launches you'll see prompts in this order:

1. **Allow location access** → choose **Allow While Using App** first,
   then immediately:
   *Settings → GpsLogger → Location → **Always***. Without "Always",
   tracking silently stops the moment the app goes to background.
2. **Motion & Fitness** → **Allow**. Without this, the app stays in
   pedestrian-mode hint forever (works fine for walking, less ideal in
   a car). The orange impairment banner at the top of the screen calls
   out denied permissions explicitly.
3. **Background App Refresh** → on the iPhone:
   *Settings → General → Background App Refresh* (global *and* per-app).
   Without this, the app cannot resurrect itself after iOS terminates
   it; tracking stops silently.

The pulsing **green dot** in the top-right corner means the tracker is
live. The big number is the **unsynced points** counter — it goes up
as fixes are recorded and down as batches upload over **Wi-Fi only**.
On cellular it will accumulate without uploading; that's by design
(see the Wi-Fi-only sync policy in [`README.md`](README.md)).

Tap the **device ID** row at the bottom and copy it to the clipboard —
you'll paste it into the web UI next.

## Step 6 — visualize the route in the browser

Open <http://localhost:3001/> on the Mac:

1. Paste the **Device ID** from the iPhone into the field.
2. The **From / To** range defaults to *today since local 00:00 → now*
   (1.4.2). Adjust if needed.
3. Click **Visualize**. After the first reload (1.4.3), the page
   auto-fires the same fetch when a device ID is already stored, so
   you don't have to re-click on every refresh.

The trace renders as a single uniform-color polyline with `S` (start)
and `E` (end) badges, semi-transparent direction arrows along the
path, and per-point cards on click that show coordinates, address
(reverse-geocoded on demand), local time, and cumulative distance
from start.

If nothing renders:

> Prompt: *"The web UI shows zero points for device ID <ID>. Tail the
> backend logs and the iOS device logs and tell me where the pipeline
> is breaking."*

Claude Code will check, in order:

- `docker compose logs --tail=100 backend` — were any `POST /points`
  calls made?
- `curl -fsS "http://localhost:3000/points?device_id=<ID>&from=<ISO>&to=<ISO>"`
  — does the backend return rows directly?
- iOS console (`xcrun devicectl device process logs`) — is the iOS
  app trying to upload? Is it stalled on Wi-Fi reachability? On the
  401 from a missing API key?

## What Claude Code can keep doing for you after setup

- **Move LAN IPs**: *"Update xcconfig with my new IP and rebuild."*
- **7-day re-sign**: *"Re-sign and reinstall the app — the provisioning
  profile expired."*
- **Reset the local DB**: *"Drop and recreate the Postgres data — I
  want to start fresh."*
- **Investigate a bad fix**: *"This point at lat=… lng=… looks wrong.
  Pull the matching `fix_diagnostics` row and tell me which filter
  gate would have caught it."*
- **Tail and diagnose silent failures**: *"My counter went up by 200
  but the backend got nothing in the last hour."* — Claude Code will
  check Wi-Fi reachability, the URLSession config, and the backend
  health.
- **Bring the stack down cleanly**: *"Stop everything and prune the
  containers but keep the DB volume."*

## Optional — frontend hot-reload while developing

The docker-compose `frontend` is a built nginx image; it doesn't
hot-reload. If you're iterating on the UI:

> Prompt: *"Run the Vite dev server against the dockerized backend."*

Claude Code will `cd frontend && npm install && npm run dev` and tell
you to open <http://localhost:5173/>. The dev server defaults to
`http://localhost:3000` for the API, which is exactly what the
docker-compose backend is bound to.
