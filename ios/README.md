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
├── README.md              ← this file
└── GpsLogger/
    ├── GpsLoggerApp.swift   ← @main entry
    ├── AppContainer.swift   ← dependency wiring (singleton)
    ├── AppState.swift       ← @Published unsynced counter
    ├── ContentView.swift    ← UI (counter + Start/Stop)
    ├── LocationTracker.swift← CLLocationManager wrapper
    ├── SyncService.swift    ← sync timer + HTTP upload
    ├── Database.swift       ← raw sqlite3 wrapper
    ├── Config.swift         ← backend URL & tunables
    └── Info.plist           ← reference plist with required keys
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

Then drag all 8 `.swift` files from `ios/GpsLogger/` into the Xcode project.
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

1. Launch the app.
2. Tap **Start**.
3. iOS prompts for location permission — choose **Allow While Using App** (you can
   later upgrade to **Always** in Settings → GpsLogger → Location for background
   tracking).
4. Go for a drive/walk. Points save every ~10 m.
5. The large number is the **unsynced points** counter — it increments on save and
   decrements as batches upload.
6. Tap **Stop** when done.

## How it works

- **Collection**: `CLLocationManager` with `kCLLocationAccuracyBest`,
  `activityType = .automotiveNavigation`, `distanceFilter = 10`,
  `pausesLocationUpdatesAutomatically = false`,
  `allowsBackgroundLocationUpdates = true`. Points are saved **only** from
  `didUpdateLocations` callbacks — no timers are used for collection.
- **Storage**: single SQLite table `points(id, latitude, longitude, created_at)`
  in `Documents/gpslogger.sqlite`, WAL journal mode.
- **Sync**: a `Timer` (the only timer in the app) fires every 30s, pulls up to 100
  rows, POSTs them to `/points`, and deletes the rows on a 2xx response. Failures
  stay in the DB for the next tick.
- **Counter**: lives in memory. Seeded once at launch from `SELECT COUNT(*)`, then
  increment/decrement only — no further `COUNT` queries.

## Troubleshooting

- **App shows "Stopped" after tapping Start** — permission was denied or not
  granted. Open **Settings → GpsLogger → Location** and set to **Always**.
- **Counter goes up but never down** — backend is unreachable. Check
  `Config.apiBaseURL` and that Mac and iPhone share the same Wi-Fi.
- **7-day expiry** — reconnect iPhone to Xcode and re-run.
- **Blue bar in status bar while backgrounded** — normal; indicates the app is
  actively tracking location.
