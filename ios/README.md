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
    ├── Config.swift               ← backend URL & tunables
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

Edit `Config.swift`. The committed default is:

```swift
static let apiBaseURL = URL(string: "http://localhost:3000")!
```

- **iOS Simulator**: leave as-is — the simulator shares the Mac's network stack.
- **Physical iPhone**: replace with your Mac's LAN IP
  (**System Settings → Network → Wi-Fi → Details → TCP/IP**), e.g.
  `http://192.168.1.25:3000`. iPhone and Mac must share the same Wi-Fi.

### 6. Local signing config (for CLI builds via xcodegen + xcodebuild)

If you build from the command line rather than clicking Run in Xcode, the
signing team ID lives in a **gitignored** xcconfig file so nothing personal
ends up in the repo:

```bash
cd ios
cp GpsLogger.xcconfig.example GpsLogger.xcconfig
# edit GpsLogger.xcconfig and replace YOUR_APPLE_TEAM_ID
xcodegen generate
```

To find your team ID:

```bash
security find-identity -p codesigning -v
#   1) <hash> "Apple Development: you@example.com (TEAM_ID)"
```

(or Xcode → Settings → Accounts → *Team ID* column).

Without this file, `xcodegen generate` still works, but `xcodebuild` will
refuse to sign for a real device.

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
  `activityType = .automotiveNavigation`, `distanceFilter = 10`,
  `pausesLocationUpdatesAutomatically = false`,
  `allowsBackgroundLocationUpdates = true`. Points are saved **only** from
  `didUpdateLocations` callbacks — no timers are used for collection. The
  tracker is started in `AppContainer.init` and runs for the lifetime of the
  app; there is no Start/Stop button.
- **Filter pipeline** (in order; a fix must pass all three to be inserted):
  1. `CLLocationManager.distanceFilter = 10 m` and a defensive per-insert
     distance check.
  2. `LocationFilter` — drops fixes with `horizontalAccuracy > 50 m`, rejects
     implied speeds > 500 km/h, and buffers any > 750 m jump for one tick to
     catch A → B(far) → C(near A) spike patterns.
  3. `StationaryDetector` — once accepted fixes stay within 20 m of a
     candidate anchor for 150 s, suppresses subsequent fixes until one lands
     more than 30 m from the cluster center. Coordinates are never smoothed,
     only accept/suppress decisions are made.
- **Device identity**: `DeviceIdentity` mints a UUID on first launch and
  stores it in the Keychain (UserDefaults fallback) so it survives reinstalls.
  Every inserted point is stamped with this ID.
- **Storage**: single SQLite table `points(id, latitude, longitude, created_at,
  device_id)` in `Documents/gpslogger.sqlite`, WAL journal mode.
- **Sync**: a `Timer` (the only timer in the app) fires every 30 s, pulls up
  to 100 rows, POSTs them to `/points` with the device ID stamped on each
  row, and deletes the rows on a 2xx response. Failures stay in the DB for
  the next tick.
- **Counter**: lives in memory. Seeded once at launch from `SELECT COUNT(*)`,
  then increment/decrement only — no further `COUNT` queries.
- **Backend URL override**: `Config.apiBaseURL` reads UserDefaults at every
  call site, so you can re-point the app between hosts without a rebuild via
  `defaults write` for the `apiBaseURL` key.

## Troubleshooting

- **Status dot is gray** — location permission was denied or not granted.
  Open **Settings → GpsLogger → Location** and set to **Always**.
- **Counter goes up but never down** — backend is unreachable. Check
  `Config.apiBaseURL` (or the `apiBaseURL` UserDefaults override) and that
  Mac and iPhone share the same Wi-Fi.
- **Counter doesn't move while sitting still** — expected. The 10 m distance
  filter and `StationaryDetector` actively suppress jitter clusters. Walk
  more than 30 m to resume.
- **7-day expiry** — reconnect iPhone to Xcode and re-run.
- **Blue bar in status bar while backgrounded** — normal; indicates the app is
  actively tracking location.
