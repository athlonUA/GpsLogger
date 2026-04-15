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
├── README.md                      ← this file
├── project.yml                    ← xcodegen spec
├── GpsLogger.xcconfig.example     ← template for local signing config
└── GpsLogger/
    ├── GpsLoggerApp.swift         ← @main entry
    ├── AppContainer.swift         ← dependency wiring (singleton)
    ├── AppState.swift             ← @Published counter + device ID
    ├── ContentView.swift          ← UI (counter + device ID row + status dot)
    ├── LocationTracker.swift      ← CLLocationManager wrapper, always-on
    ├── LocationFilter.swift       ← accuracy / speed / spike gates
    ├── StationaryDetector.swift   ← jitter-cluster suppression
    ├── DeviceIdentity.swift       ← Keychain-backed UUID (UserDefaults fallback)
    ├── SyncService.swift          ← sync timer + HTTP upload
    ├── Database.swift             ← raw sqlite3 wrapper
    ├── MotionClassifier.swift     ← CMMotionActivityManager wrapper, emits transport mode
    ├── Config.swift               ← tunables + apiBaseURL resolver (xcconfig → Info.plist → fallback)
    ├── GpsLogger.entitlements
    └── Info.plist                 ← reference plist with required keys
```

## One-time Xcode setup

### 1. Create an Xcode project

1. **Xcode → File → New → Project…**
2. **iOS → App**
3. Product Name: `GpsLogger`
4. Organization Identifier: anything unique (e.g. `com.yourname.gpslogger`)
5. Interface: **SwiftUI** / Language: **Swift** / Storage: **None**
6. Leave tests unchecked.
7. Save the project at e.g. `~/Projects/GpsLogger/ios-xcode/`
   (keeping it **outside** the `ios/GpsLogger` source folder keeps the repo clean).

### 2. Replace the template source files

In the Xcode project navigator, **delete** the two files Xcode generated:

- `ContentView.swift`
- `GpsLoggerApp.swift`

Then drag all `.swift` files from `ios/GpsLogger/` into the Xcode project
(currently 11: `GpsLoggerApp`, `AppContainer`, `AppState`, `ContentView`,
`LocationTracker`, `LocationFilter`, `StationaryDetector`, `DeviceIdentity`,
`SyncService`, `Database`, `Config`).
In the dialog:

- ✅ **Copy items if needed** (uncheck if you want Xcode to reference the files in-place)
- ✅ **Create groups**
- ✅ Add to the `GpsLogger` target

### 3. Configure Info.plist

Open `ios/GpsLogger/Info.plist` (in this repo) and copy its keys into your project's
Info tab:

**Target → Info → Custom iOS Target Properties → +**

| Key | Type | Value |
|---|---|---|
| `NSLocationAlwaysAndWhenInUseUsageDescription` | String | `GpsLogger records your location in the background to log your trip.` |
| `NSLocationWhenInUseUsageDescription` | String | `GpsLogger records your current position to log your trip.` |
| `App Transport Security Settings` | Dictionary | — |
| &nbsp;&nbsp;↳ `Allow Arbitrary Loads` | Boolean | `YES` |

> The ATS exception is **dev-only** so the app can reach your LAN backend over plain
> HTTP. Remove it and use HTTPS in production.

### 4. Enable Background Modes

**Target → Signing & Capabilities → + Capability → Background Modes**

Check: **Location updates**

### 5. Set the backend URL

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

### 6. Local personal config (signing team + backend URL)

Everything personal lives in a single **gitignored** file,
`ios/GpsLogger.xcconfig`, which you create once from the committed
template:

```bash
cd ios
cp GpsLogger.xcconfig.example GpsLogger.xcconfig
# then edit GpsLogger.xcconfig
xcodegen generate
```

Two settings to fill in:

- **`DEVELOPMENT_TEAM`** — your Apple Developer Team ID, used by
  `xcodebuild` to sign for a real device. Find it via:
  ```bash
  security find-identity -p codesigning -v
  #   1) <hash> "Apple Development: you@example.com (TEAM_ID)"
  ```
  (or Xcode → Settings → Accounts → *Team ID* column).

- **`API_BASE_URL`** — your Mac's LAN IP + backend port, for the
  physical-device build (see section 5 above). Remember the
  `http:/$()/` escape for the `//` sequence.

The iOS target's `configFiles` in `project.yml` points Debug and
Release at this file, and `project.yml`'s info.properties block
references `$(API_BASE_URL)` so it lands in the bundled `Info.plist`.
After editing the xcconfig, always re-run `xcodegen generate` to
refresh the `.xcodeproj`.

Without this file, `xcodegen generate` still works, but `xcodebuild`
will refuse to sign for a real device, and the built bundle will fall
back to `http://localhost:3000` — which only reaches the backend on
the simulator.

### 7. Deploy to your iPhone (free Apple ID)

1. **Xcode → Settings → Accounts → +** add your Apple ID.
2. Select the target → **Signing & Capabilities** → set **Team** to your Personal Team.
3. Connect your iPhone (USB or Wi-Fi pairing).
4. Select the iPhone in the device picker next to the Run button.
5. Press ▶ **Run**.
6. First time: on your iPhone, go to
   **Settings → General → VPN & Device Management** and trust the developer profile.
7. Launch the app.

> Free Apple ID provisioning profiles expire after **7 days**. When that happens,
> connect the iPhone to Xcode and hit Run again to refresh.

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
  `activityType = .fitness` (pedestrian-appropriate hint to CoreLocation's
  fusion engine), `distanceFilter = 10`,
  `pausesLocationUpdatesAutomatically = false`,
  `allowsBackgroundLocationUpdates = true`. Points are saved **only** from
  `didUpdateLocations` callbacks — no timers are used for collection. The
  tracker is started in `AppContainer.init` and runs for the lifetime of the
  app; there is no Start/Stop button.
- **Filter pipeline** (in order; a fix must pass all three to be inserted):
  1. `CLLocationManager.distanceFilter = 10 m` and a defensive per-insert
     distance check.
  2. `LocationFilter` — drops fixes with `horizontalAccuracy > 50 m`; rejects
     any fix whose `speed < 0` or `verticalAccuracy ≤ 0` as **non-GPS**
     (Wi-Fi / cell-tower fallback fixes leave those fields at the sentinel
     negatives because network positioning has no Doppler velocity and no
     altitude — this is the load-bearing defense against stale BSSID
     registrations in Apple's Wi-Fi Positioning database delivering
     plausible-looking-but-wrong fixes in degraded-signal environments);
     rejects implied speeds > 500 km/h; and buffers any > 750 m jump for one
     tick to catch A → B(far) → C(near A) spike patterns.
  3. `StationaryDetector` — once accepted fixes stay within 20 m of a
     candidate anchor for 150 s, suppresses subsequent fixes until one lands
     more than 30 m from the cluster center. Coordinates are never smoothed,
     only accept/suppress decisions are made.
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
