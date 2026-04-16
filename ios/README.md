# GpsLogger — iOS App

Minimal SwiftUI app that records GPS points in the background and syncs them
to the backend. Uses raw `sqlite3` (system library) — no external Swift packages.

## Requirements

- macOS with Xcode 15 or newer
- iPhone running iOS 16 or newer
- Free Apple ID (no paid Developer Program needed)
- USB cable or Wi-Fi pairing between Mac and iPhone

## Project layout

```
ios/
├── README.md                           ← this file
├── project.yml                         ← xcodegen spec (app + test target)
├── GpsLogger.xcconfig.example          ← template for DEVELOPMENT_TEAM + API_BASE_URL
├── GpsLogger/
│   ├── GpsLoggerApp.swift              ← @main entry
│   ├── AppContainer.swift              ← dependency wiring (singleton)
│   ├── AppState.swift                  ← @Published counter + device ID
│   ├── ContentView.swift               ← UI (counter, device ID row, status dot, impairment banner)
│   ├── LocationTracker.swift           ← CLLocationManager delegate + pipeline + activityType swap
│   ├── LocationFilter.swift            ← validity → source → accuracy → speed → spike → min-distance
│   ├── StationaryDetector.swift        ← jitter-cluster suppression + clock-skew guard
│   ├── MotionClassifier.swift          ← CMMotionActivityManager wrapper, emits transport mode
│   ├── DeviceIdentity.swift            ← Keychain-backed UUID (UserDefaults fallback)
│   ├── SyncService.swift               ← sync timer + private syncQueue + HTTP upload
│   ├── Database.swift                  ← raw sqlite3 wrapper (points + fix_diagnostics)
│   ├── Config.swift                    ← tunables + apiBaseURL resolver
│   ├── GpsLogger.entitlements
│   └── Info.plist                      ← reference plist with required keys
└── GpsLoggerTests/
    ├── LocationFilterTests.swift       ← 15 cases covering every filter gate + pending-timeout
    ├── DatabaseTests.swift              ← 7 cases for insert/fetch/delete/retention invariants
    ├── MotionClassifierTests.swift     ← 10 cases for the pure classification rules
    └── StationaryDetectorTests.swift    ← 9 cases for Phase-A/B state machine + clock-skew guard
```

## One-time setup (xcodegen-based)

The repo is **xcodegen-driven**: the `.xcodeproj` is generated from
`project.yml` on every build. You do not create an Xcode project by
hand; you edit a single config file and run `xcodegen generate`. All
Info.plist keys, background modes, target membership, test target, and
entitlements are specified in `project.yml` and
`GpsLogger.xcconfig.example` — nothing needs to be clicked through in
Xcode's GUI.

Prerequisite (one-time): `brew install xcodegen`.

### 1. Clone the repo

```bash
git clone https://github.com/<you>/GpsLogger.git
cd GpsLogger/ios
```

### 2. Create the local personal config file

Copy the committed template to the gitignored real file:

```bash
cp GpsLogger.xcconfig.example GpsLogger.xcconfig
```

Then edit `GpsLogger.xcconfig` and fill in two values — see
**section 3. Set the backend URL** below for details on both.

### 3. Set the backend URL

`Config.apiBaseURL` resolves the backend base URL at every call site in
this order:

1. **`UserDefaults["apiBaseURL"]`** — runtime override via
   `defaults write`, useful for re-pointing the running app between
   hosts without a rebuild.
2. **`Info.plist["API_BASE_URL"]`** — baked into the `.app` bundle at
   build time from the **gitignored** `ios/GpsLogger.xcconfig` via
   `$(API_BASE_URL)` substitution (see `project.yml` info.properties).
   This is the path a physical-device build relies on in normal
   operation.
3. **`http://localhost:3000`** — simulator fallback wired into
   `Config.defaultApiBaseURL`. The simulator shares the Mac's network
   stack, so no configuration is needed there.

**Physical iPhone setup.** Edit `ios/GpsLogger.xcconfig` (create it from
`GpsLogger.xcconfig.example` on first run) and add your Mac's LAN IP:

```
DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
API_BASE_URL = http:/$()/192.168.1.129:3000
```

> **Quirk**: xcconfig treats `//` as the start of a line comment, so a
> literal `http://` must be escaped as `http:/$()/`. The `$()` is an
> empty variable expansion that breaks up the `//` sequence — after
> xcconfig parsing, the value is `http://192.168.1.129:3000` exactly
> as you'd expect.

Find your Mac's LAN IP via either of:

```bash
ipconfig getifaddr en0
# or: System Settings → Network → Wi-Fi → Details → TCP/IP
```

Then re-run `xcodegen generate` inside `ios/` and rebuild. The iPhone
and the Mac must share the same Wi-Fi.

**Verify the build carries the URL** before deploying:

```bash
plutil -p ~/Library/Developer/Xcode/DerivedData/GpsLogger-*/Build/Products/Debug-iphoneos/GpsLogger.app/Info.plist \
    | grep API_BASE_URL
# → "API_BASE_URL" => "http://192.168.1.129:3000"
```

If you see `http://$(API_BASE_URL)` or the literal `$()` artefact in
the output, the xcconfig wasn't picked up — re-run `xcodegen generate`
and make sure `GpsLogger.xcconfig` is present (not just the
`.example` template).

### 4. Fill in the two xcconfig values

`GpsLogger.xcconfig` has exactly two personal settings:

- **`DEVELOPMENT_TEAM`** — your Apple Developer Team ID, used by
  `xcodebuild` to sign for a real device. Find it via:
  ```bash
  security find-identity -p codesigning -v
  #   1) <hash> "Apple Development: you@example.com (TEAM_ID)"
  ```
  (or Xcode → Settings → Accounts → *Team ID* column).

- **`API_BASE_URL`** — your Mac's LAN IP + backend port, as covered in
  section 3 above. Remember the `http:/$()/` escape for the `//`
  sequence.

Without this file, `xcodegen generate` still works, but `xcodebuild`
will refuse to sign for a real device, and the built bundle will fall
back to `http://localhost:3000` — which only reaches the backend on
the Simulator.

### 5. Generate the Xcode project

```bash
cd ios
xcodegen generate
```

Look for:

```
Generating plists...
Generating project...
Writing project...
Created project at …/GpsLogger.xcodeproj
```

`project.yml` is the source of truth: it declares the app target, the
unit-test target, all Info.plist keys
(`NSLocationAlwaysAndWhenInUseUsageDescription`,
`NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`,
`NSAllowsLocalNetworking`), background modes, signing config, and the
`$(API_BASE_URL)` substitution into the Info.plist. Nothing has to be
configured manually in Xcode.

Re-run `xcodegen generate` every time you change `project.yml` or
`GpsLogger.xcconfig` — editing those files alone does not refresh the
`.xcodeproj`.

### 6. Deploy to your iPhone (free Apple ID)

Two paths, both supported and tested. Pick whichever is faster for you.

**GUI path (simplest first time):**

1. **Xcode → Settings → Accounts → +** add your Apple ID.
2. Open `ios/GpsLogger.xcodeproj` in Xcode.
3. Select the target → **Signing & Capabilities** → set **Team** to
   your Personal Team (it inherits `DEVELOPMENT_TEAM` from the
   xcconfig automatically).
4. Connect your iPhone (USB or Wi-Fi pairing).
5. Select the iPhone in the device picker next to the Run button.
6. Press ▶ **Run**.
7. First time on each device: **Settings → General → VPN & Device
   Management** on the iPhone, trust the developer profile.

**CLI path (for iteration / scripting):**

```bash
cd ios

# iPhone with iOS 17+ — CoreDevice / devicectl:
UDID=<your-udid>              # xcrun xctrace list devices
xcodebuild build -project GpsLogger.xcodeproj -scheme GpsLogger \
    -destination "id=$UDID" -configuration Debug
APP=$(find ~/Library/Developer/Xcode/DerivedData/GpsLogger-*/Build/Products/Debug-iphoneos \
    -maxdepth 1 -name "GpsLogger.app" | head -1)
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.gpslogger.personal

# iPhone with iOS 16.x — ios-deploy (CoreDevice only supports 17+):
brew install ios-deploy     # one-time
ios-deploy --id <udid-hex> --bundle "$APP" --no-wifi
```

Building against a UDID in `-destination` auto-registers the device
into your Personal Team provisioning profile, so one `.app` bundle
covers every device you've built for.

> Free Apple ID provisioning profiles expire after **7 days**. When
> that happens, re-run `xcodegen generate && xcodebuild build ...` and
> reinstall. On the Personal Team, you are limited to 3 registered
> devices at a time.

## Usage

1. Launch the app. Tracking starts immediately — there is no Start/Stop button.
2. iOS prompts for location permission — choose **Allow While Using App**, then
   upgrade to **Always** in Settings → GpsLogger → Location for background
   tracking.
3. The pulsing **green dot** in the top-right corner indicates the tracker is
   active. A solid gray dot means permission was denied or not yet granted.
4. The large number is the **unsynced points** counter — it increments on save
   and decrements as batches upload.
5. The **Device ID** row at the bottom shows the stable identifier for this
   install. Tap the copy icon to copy it to the clipboard, then paste it into
   the web UI's Device ID field to visualize this device's points.
6. Go for a drive/walk. Points save every ~10 m and are filtered for accuracy,
   teleport-class spikes, and stationary jitter clusters before insert.

## How it works

- **Collection**: `CLLocationManager` with `kCLLocationAccuracyBest`,
  `distanceFilter = 10`, `pausesLocationUpdatesAutomatically = false`,
  `allowsBackgroundLocationUpdates = true`. Points are saved **only**
  from `didUpdateLocations` callbacks — no timers are used for
  collection. The tracker is started in `AppContainer.init` and runs
  for the lifetime of the app; there is no Start/Stop button.
- **Multi-modal `activityType`**: a single install covers walking,
  cycling, and motorized transport (car, bus, train) through
  `MotionClassifier`. It wraps `CMMotionActivityManager` — which reads
  the phone's accelerometer/gyroscope, not GPS speed — and emits a
  coarse mode (`.pedestrian`, `.cycling`, `.automotive`, `.unknown`)
  that `LocationTracker.apply(mode:)` maps to
  `CLLocationManager.activityType` at runtime: `.fitness` for
  pedestrian and cycling, `.automotiveNavigation` for any motor
  vehicle. Startup default is `.fitness`, so a cold launch behaves
  exactly like a pedestrian tracker; the hint flips only on
  medium/high-confidence readings. Low-confidence or `.unknown`
  readings never change the hint, preventing thrashing. Requires the
  **Motion & Fitness** permission — if denied or the device has no
  motion coprocessor, the classifier emits `onUnavailable`, the
  tracker surfaces a `motionPermissionDenied` impairment in the UI,
  and `activityType` stays on `.fitness` for the rest of the session.
- **Filter pipeline** (every fix passes distanceFilter → LocationFilter
  → StationaryDetector before it lands in `points`):
  1. **`CLLocationManager.distanceFilter = 10 m`** and a defensive
     per-insert distance check (LocationFilter's minDistance rule).
  2. **`LocationFilter`** — nine rules in order:
     (a) **delivery age** (1.2.2) — `|now − timestamp| ≤ 10 s`. Rejects
     cached locations that CoreLocation replays after a signal gap.
     (b) validity — `horizontalAccuracy ≥ 0`.
     (c) **source gate** — `speed ≥ 0` AND `verticalAccuracy > 0`.
     GNSS fixes populate both (Doppler velocity + 3D solution);
     Wi-Fi / cell-tower fallback fixes leave them at Apple's
     documented sentinel negatives. This is the load-bearing defense
     against stale-BSSID Wi-Fi Positioning "teleport" fixes that
     otherwise pass the accuracy gate.
     (d) accuracy value — drops fixes with `horizontalAccuracy > 50 m`.
     (e) chronology — `Δt > 0` vs the last accepted fix (rejects
     replayed cached fixes).
     (f) **gap-aware accuracy** (1.2.2) — if `Δt > 60 s`, tightens
     the accuracy ceiling from 50 m to 20 m, filtering multipath
     convergence fixes after extended indoor / background signal loss.
     (g) implausible speed — rejects implied speeds > 500 km/h.
     (h) spike buffer — a fix > 750 m from the last accepted point is
     held one tick; if the next fix returns within 100 m of the last
     accepted point, the buffered fix is confirmed as a spike and
     dropped. A `pending` fix older than
     `Config.pendingTimeoutSeconds` (30 s) is discarded silently so
     an app-backgrounding event cannot corrupt the next session.
     (i) minimum distance — ≥ 10 m from the last accepted fix.
  3. **`StationaryDetector`** — after accepted fixes stay within 20 m
     of a candidate anchor for 150 s, suppresses subsequent fixes
     until one lands more than 30 m from the cluster center. The
     `age >= window` comparison is guarded against negative deltas
     (NTP correction, DST transition, cached replay) so a clock jump
     cannot stall the detector in Phase A. Coordinates are never
     smoothed or averaged — only accept/suppress decisions.
- **Tracking impairment UI**: `LocationTracker` publishes a
  `Set<TrackingImpairment>`, rendered as an orange banner at the top
  of `ContentView` whenever non-empty. Three cases:
  `.permissionDenied` (location auth denied or revoked — no tracking
  at all), `.backgroundRequiresAlways` (user has WhenInUse only —
  foreground works but background silently drops), and
  `.motionPermissionDenied` (vehicle mode never engages). The state
  machine in `locationManagerDidChangeAuthorization` also resets
  `LocationFilter` and `StationaryDetector` on a re-grant so stale
  anchors from a previous session don't bleed into the new one.
- **Post-indoor GPS reacquisition defense (1.2.2)**: two new
  `LocationFilter` gates address cached-fix replay and multipath
  convergence drift after extended indoor or background signal loss.
  See filter pipeline rules (a) and (f) above.
- **Correctness + resilience (1.2.1)**: `Database.insert` and
  `logDiagnostic` return `Bool`, so the in-memory unsynced counter
  only increments on confirmed SQLite success. All SQLite writes from
  the tracker hop onto a private serial `persistQueue` so the
  CoreLocation main-queue callback is never blocked by a synchronous
  `sqlite3_step`. All SyncService state (`pointsInFlight`,
  `diagnosticsInFlight`, the fetch+delete pair) runs on a private
  serial `syncQueue`; URLSession completion handlers re-dispatch back
  onto it before touching flags, eliminating the Bool data race that
  would otherwise arise between the main Timer callback and the
  URLSession background completion. `delete` / `deleteDiagnostics`
  chunk at 500 ids per statement so an oversized batch cannot exceed
  SQLite's parameter limit. `didFailWithError` switches on
  `CLError.code` (`.denied` stops the tracker and surfaces the
  impairment, `.locationUnknown` is ignored as transient).
- **Device identity**: `DeviceIdentity` mints a UUID on first launch and
  stores it in the Keychain (UserDefaults fallback) so it survives reinstalls.
  The ID is owned by `SyncService` and stamped on every upload payload — it
  is **not** written into individual rows of `points`, because it's a
  property of the install, not of each fix.
- **Storage**: `Documents/gpslogger.sqlite` (WAL journal mode) with two tables:
  - `points(id, latitude, longitude, created_at)` — unsynced upload queue.
    Pre-refactor installs may still have a legacy `device_id` column; it is
    dropped idempotently via `ALTER TABLE ... DROP COLUMN` on first launch
    after upgrade.
  - `fix_diagnostics(id, logged_at, fix_timestamp, latitude, longitude,
    horizontal_accuracy, vertical_accuracy, altitude, speed, speed_accuracy,
    course, course_accuracy, decision)` — debug/observability table capturing
    every raw `CLLocation` that enters `LocationTracker.didUpdateLocations`
    together with the filter's decision. **Uploaded** on the same 30 s sync
    cadence as `points` (see below); the authoritative store is the backend
    Postgres table. Local rows are deleted on successful 2xx; a 3-day
    retention window in `cleanupDiagnostics` covers prolonged backend
    outages. See `QA.md` for how to query the backend after an anomaly.
- **Sync**: a `Timer` (the only timer in the app) fires every 30 s and runs
  two independent drains:
  - `points` → `POST /points` — drives the visible trace. Pulls up to 100
    rows, stamps the device ID on each payload element (from the injected
    `SyncService.deviceId`, not per-row), and deletes on 2xx.
  - `fix_diagnostics` → `POST /diagnostics` — mirror shape of the points
    drain. Each channel has its own in-flight guard so one slow response
    cannot stall the other.
  Failures stay in the local DB for the next tick — no partial delete,
  no retry storms.
- **Counter**: lives in memory. Seeded once at launch from `SELECT COUNT(*)`,
  then increment/decrement only — no further `COUNT` queries.
- **Backend URL resolution**: `Config.apiBaseURL` is read at every call
  site and tries, in order, `UserDefaults["apiBaseURL"]` (runtime
  override), `Info.plist["API_BASE_URL"]` (baked in at build time from
  the gitignored `GpsLogger.xcconfig`, see section 5 of the setup
  above), and finally the simulator-friendly `http://localhost:3000`
  fallback. Changing the UserDefaults value takes effect on the next
  sync tick without a restart; changing the xcconfig requires a
  rebuild.

## Troubleshooting

- **Status dot is gray** — location permission was denied or not granted.
  Open **Settings → GpsLogger → Location** and set to **Always**.
- **Counter goes up but never down** — backend is unreachable. Check,
  in order: the Mac's docker-compose backend is running
  (`curl -fsS http://localhost:3000/health`); the `API_BASE_URL` in
  `ios/GpsLogger.xcconfig` matches the current LAN IP of the Mac
  (run `ipconfig getifaddr en0`); the built bundle actually picked it
  up (`plutil -p … | grep API_BASE_URL`); iPhone and Mac are on the
  same Wi-Fi. After any change to the xcconfig you must re-run
  `xcodegen generate` and rebuild — editing the file alone is not
  enough.
- **Counter doesn't move while sitting still** — expected. The 10 m distance
  filter and `StationaryDetector` actively suppress jitter clusters. Walk
  more than 30 m to resume.
- **7-day expiry** — reconnect iPhone to Xcode and re-run.
- **Blue bar in status bar while backgrounded** — normal; indicates the app is
  actively tracking location.
