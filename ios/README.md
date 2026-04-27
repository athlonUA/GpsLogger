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
│   ├── SyncService.swift               ← Wi-Fi-only sync timer + private syncQueue + HTTP upload
│   ├── Database.swift                  ← raw sqlite3 wrapper (points + fix_diagnostics)
│   ├── KalmanSmoother.swift            ← 2D constant-velocity KF over accepted fixes (1.2.7)
│   ├── Config.swift                    ← tunables + apiBaseURL resolver + Wi-Fi URLSession factory + diagnostics flag
│   ├── GpsLogger.entitlements
│   └── Info.plist                      ← reference plist with required keys
└── GpsLoggerTests/
    ├── LocationFilterTests.swift       ← 20 cases covering every filter gate + pending-timeout + automotive spike-jump widening
    ├── KalmanSmootherTests.swift        ←  9 cases covering first-fix passthrough, attenuation, outlier damping, reset paths, ENU round-trip
    ├── DatabaseTests.swift              ←  7 cases for insert/fetch/delete/retention invariants
    ├── MotionClassifierTests.swift     ← 10 cases for the pure classification rules
    ├── StationaryDetectorTests.swift   ← 11 cases for Phase-A/B state machine + clock-skew guard + gap-reset
    ├── TrackingImpairmentTests.swift    ←  7 cases for the 1.2.8 silent-failure mappings
    ├── SyncPolicyTests.swift           ← 10 cases for the 1.2.10 Wi-Fi-only predicate + URLSession config + diagnostics flag
    ├── WakeMonitorRoutingTests.swift   ←  3 cases locking in the 1.2.11 wake-only SLC contract (no persist on wake events)
    ├── AutoWakeSettingsTests.swift     ←  8 cases for the 1.2.12 Auto Wake kill switch (default-off, persistence, @Published mirror, data-safety)
    └── HomeZoneTests.swift             ← 23 cases for the 1.2.13 unified home-zone anchor (round-trip + freshness + decision matrix + wake-fix evaluation + persist gate + flag-clear contract + WhenInUse invariants)
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

- **Collection** (tightened 1.2.7): `CLLocationManager` with
  `kCLLocationAccuracyBestForNavigation`,
  `distanceFilter = kCLDistanceFilterNone`,
  `pausesLocationUpdatesAutomatically = false`,
  `allowsBackgroundLocationUpdates = true`,
  `showsBackgroundLocationIndicator = true`. `BestForNavigation` pulls
  in additional accelerometer / gyroscope / barometer data and reduces
  reported HA in partial-sky conditions; `kCLDistanceFilterNone`
  delivers every computed fix (~1 Hz) so the downstream Kalman smoother
  has 5–7× more observations to average against. Battery impact is
  real and accepted as a product trade. Points are saved **only** from
  `didUpdateLocations` callbacks — no timers are used for collection.
  The tracker is started in `AppContainer.init` and runs for the
  lifetime of the app; there is no Start/Stop button.
  The `didUpdateLocations` array is sorted ascending by timestamp
  before iteration (1.2.5 defensive sort) so a future iOS change in
  array ordering cannot corrupt the spike-buffer logic.
- **SLC as a wake-only trigger** (refined 1.2.11). The tracker owns a
  second `CLLocationManager` (`wakeMonitor`) dedicated solely to
  `startMonitoringSignificantLocationChanges()`. Its only purpose is
  to let iOS relaunch the process via
  `UIApplicationLaunchOptionsLocationKey` for users who haven't opened
  the app in a while. SLC is **not** a tracking source — wake-monitor
  delegate callbacks are intentional no-ops, identity-checked against
  `self.wakeMonitor` so SLC fixes never enter the
  filter → smoother → stationary → persist pipeline. The relaunch
  flow runs through the
  `AppContainer.bootstrap(launchedForLocation:)` →
  `tracker.start(launchedForLocation:)` startup path (single startup
  branch); by the time the wake event is delivered the regular
  update stream is either already running (`.fullTracking`) or
  intentionally idle awaiting displacement confirmation
  (`.deferred`, see 1.2.13 home-zone below).
- **Auto Wake kill switch** (1.2.12). The wake-monitor subscription
  is now an explicit opt-in, **off by default**. State lives in
  `UserDefaults` under `Config.autoWakeEnabledKey` (key
  `"autoWakeEnabled"`); the absence-or-`false` default is what makes
  a clean install (or an upgrade from a pre-1.2.12 build that armed
  SLC unconditionally) start with no OS-level wake subscription.
  `LocationTracker.applyAutoWakeSetting()` is the single point that
  reconciles the persisted preference with the OS — ON ⇒
  `startMonitoringSignificantLocationChanges()`, OFF ⇒
  `stopMonitoringSignificantLocationChanges()` — and it runs from
  three places: `init()` (so an upgrade actively disarms a leftover
  subscription), `handleAuthorizationState(.authorizedAlways)` (so
  the subscription becomes effective the moment Always auth is
  granted), and `setAutoWakeEnabled(_:)` (the toggle's side effect).
  The OFF path produces a real OS-level halt of SLC delivery, not
  just a UI flag — iOS will not relaunch the app on significant
  movement until the user re-enables Auto Wake. Toggling has zero
  side effect on stored points, device identity, sync state, or
  always-on regular tracking; opening the app manually still calls
  `manager.startUpdatingLocation()` regardless.

  **Hidden access.** The toggle has no visible entry point on the
  main screen. To reach it, tap the unsynced-points counter ten
  times in a row (≤ 1.5 s between taps); a single-row Auto Wake
  settings sheet then appears. The 10-tap accumulator lives in
  `ContentView`'s local `@State` and resets on every present, on a
  dropped-cadence stray gap, and on every cold launch. The thresholds
  (`tapWindow = 1.5 s`, `tapsToReveal = 10`) sit comfortably above
  iOS's double-tap interval so the gesture doesn't interfere with
  accessibility shortcuts.

  **Battery.** When the user opts in, SLC is system-level cellular
  triangulation that is already running for OS-level features, so
  adding the subscription does not materially increase power use
  compared to the high-accuracy GPS stream the app runs anyway. When
  opted out, the subscription is actively removed at the OS level so
  the device spends no power on wake monitoring.
- **Unified home-zone anchor** (1.2.13). A single
  last-known-position triple persisted in `UserDefaults`
  (`lastAnchorLatitude` / `lastAnchorLongitude` /
  `lastAnchorTimestamp`) drives three previously independent
  decisions through one predicate — distance against
  `Config.homeZoneRadiusMeters` (100 m):

  1. **Cold-start under SLC-launch context.** When iOS launches the
     process specifically because of a SLC event
     (`launchOptions[.location] != nil`, captured by
     `AppDelegate.application(_:didFinishLaunchingWithOptions:)`)
     **and** Auto Wake is enabled **and** a fresh anchor exists
     (within `Config.anchorMaxAgeSeconds = 24 h`), the tracker
     enters `.deferred` mode. Regular GPS stream stays off, only
     the wake-monitor subscription is armed. Eliminates the
     overnight blue-pill blink + phantom one-off points that iOS
     produced on every cellular-tower handoff while the user slept.
  2. **Wake-monitor delegate while in `.deferred`.** The first SLC
     fix delivered to the wake-monitor identity-checks against the
     anchor. Inside the radius → stay deferred (iOS will re-suspend
     us shortly). Outside → `exitDeferredIfNeeded` engages
     `manager.startUpdatingLocation()` and the regular pipeline.
  3. **`maybePersist` pre-pipeline gate.** Even in `.fullTracking`,
     any accepted fix landing inside the home zone is suppressed
     before reaching smoother / stationary / `points` insert. This
     plugs the indoor-jitter phantom-points hole exposed on
     2026-04-26 (a 19-minute LocationFilter-rejected window
     followed by two fixes 33–44 m from the evening's last accepted
     point — both inside the 100 m home zone). Without the gate,
     `StationaryDetector`'s gap-reset rule treats the returning fix
     as a fresh anchor and writes it.

  **Anchor lifecycle.** `LocationTracker.persist(_:)` updates the
  anchor in `UserDefaults` immediately after every successful
  SQLite insert, so it naturally tracks the user's most recent
  recorded position across days. Walking → anchor moves with each
  accepted fix. Arrived somewhere → anchor freezes at the last fix
  before stationary suppression kicks in. Left that place →
  anchor moves again. No explicit "where do you live" UI is
  required.

  **Anchor freshness.** `Config.anchorMaxAgeSeconds = 24 h` bounds
  trust. Returning users from a long trip have a stale anchor — all
  three call sites short-circuit back to the pre-1.2.13 always-on
  behavior, recording everything and rebuilding a fresh anchor on
  the first persist of the new session.

  **Conscious-launch UX is preserved bit-for-bit.** Manual
  app-icon taps, App Switcher returns, and BGAppRefresh wakes have
  `launchOptions[.location] == nil`, so `launchedForLocation` is
  `false` and `shouldEnterDeferredMode` returns `false` regardless
  of anchor / Auto Wake state. The deferred path is unreachable
  from any user-initiated launch.

  **Single-evaluation contract.** `launchedForLocation` is cleared
  at the end of every `handleAuthorizationState(.authorizedAlways)`
  / `.authorizedWhenInUse` evaluation, so a later revoke + re-grant
  while the user is in foreground does NOT push the tracker back
  into deferred. The flag captures *boot* context, not a persistent
  property.

  **Mode invariants under permission downgrade.** An
  `.authorizedAlways → .authorizedWhenInUse` downgrade while in
  `.deferred` defensively promotes to `.fullTracking` — SLC
  requires Always per Apple's contract, so the wake-monitor would
  go silent under WhenInUse and we'd be stuck in a state machine
  with no exit. The defensive `exitDeferredIfNeeded` in the
  WhenInUse branch closes that hole.

  **Bootstrapping change.** `AppContainer.init()` is now
  lightweight (DB / identity / state only); a new
  `bootstrap(launchedForLocation:)` is called from
  `AppDelegate.application(_:didFinishLaunchingWithOptions:)` so the
  tracker's mode decision sees the authoritative
  `launchOptions[.location]` flag instead of guessing from
  `applicationState`. The `@UIApplicationDelegateAdaptor` is the
  minimal SwiftUI hook needed to surface that dictionary.
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
- **Filter pipeline** (every fix passes LocationFilter → KalmanSmoother
  → StationaryDetector before it lands in `points`):
  1. **`LocationFilter`** — nine rules in order:
     (a) **delivery age** (1.2.2, symmetric in 1.2.5) —
     `|now − timestamp| ≤ 10 s`. Rejects cached locations that
     CoreLocation replays after a signal gap; the 1.2.5 symmetric
     variant also rejects fixes with timestamps *ahead* of wall-clock
     (system-clock skew backward: NTP correction, manual time change,
     DST edge).
     (b) validity — `horizontalAccuracy ≥ 0`.
     (c) **source gate** — `speed ≥ 0` AND `verticalAccuracy > 0`.
     GNSS fixes populate both (Doppler velocity + 3D solution);
     Wi-Fi / cell-tower fallback fixes leave them at Apple's
     documented sentinel negatives. This is the load-bearing defense
     against stale-BSSID Wi-Fi Positioning "teleport" fixes that
     otherwise pass the accuracy gate.
     (d) accuracy value — drops fixes with
     `horizontalAccuracy > 25 m` (1.2.9, tightened from 50 m based
     on empirical HA distribution).
     (e) chronology — `Δt > 0` vs the last accepted fix (rejects
     replayed cached fixes).
     (f) implausible speed — rejects implied speeds > 500 km/h.
     (g) spike buffer — a fix farther than the spike-jump threshold
     from the last accepted point is held one tick; if the next fix
     returns within 100 m of the last accepted point, the buffered
     fix is confirmed as a spike and dropped. Threshold is
     **mode-aware** (1.2.9): 250 m for walking / cycling, 750 m
     under `MotionClassifier.Mode == .automotive`. Pedestrian default
     tightened from the blanket 750 m after real 410 m multipath
     jumps on iPhone 8 slipped through; automotive keeps 750 m so
     legitimate high-speed sample deltas pass. A `pending` fix older
     than `Config.pendingTimeoutSeconds` (30 s) is discarded silently
     so an app-backgrounding event cannot corrupt the next session.
     (h) minimum distance — ≥ 10 m from the last accepted fix.

     Removed in 1.2.9: a three-tier `poorResumeAccuracy` gate that
     fired on only one deadlocked iPhone 8 session in the whole
     dataset and zero times ever on iPhone 13 Pro Max; the single
     25 m ceiling subsumes its intent.
  2. **`KalmanSmoother` (1.2.7)** — 2D constant-velocity Kalman filter
     in local ENU meters. State `[x, y, vx, vy]`, process-noise
     acceleration σ = 2 m/s² (multi-modal), measurement noise R from
     CLLocation's own `horizontalAccuracy`². Resets on `dt > 10 s` so
     velocity never carries across a GNSS blackout. Output
     `CLLocation` preserves altitude / vertical accuracy / speed /
     course from the raw input and reports the post-update
     position-variance RMS as the new `horizontalAccuracy`. Raw
     coordinates are still logged to `fix_diagnostics`, so filter
     debugging is unaffected.
  3. **`StationaryDetector`** — after accepted fixes stay within 20 m
     of a candidate anchor for 150 s, suppresses subsequent fixes
     until one lands more than 30 m from the cluster center. The
     `age >= window` comparison is guarded against negative deltas
     (NTP correction, DST transition, cached replay) so a clock jump
     cannot stall the detector in Phase A. A 1.2.7 gap-reset guard
     also invalidates the candidate / stationary state when the
     inter-sample gap exceeds 60 s, so a GNSS blackout cannot be
     reinterpreted as sustained stationarity. Coordinates are never
     smoothed or averaged *inside this stage* — smoothing happens
     upstream in `KalmanSmoother`.
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
- **Post-indoor GPS reacquisition defense (1.2.2)**: stale-delivery
  gate on `LocationFilter` addresses cached-fix replay after a
  signal gap. See filter pipeline rule (a) above. *Historical note:*
  a companion multipath-convergence gate (`poorResumeAccuracy`) was
  part of this release; it was removed in 1.2.9 after empirical
  evidence showed it triggered almost exclusively in one deadlocked
  session. The tighter 25 m single ceiling handles the original
  multipath-convergence concern without the deadlock failure mode.
- **Background drain + error-aware backoff (1.2.4)**: `SyncService`
  classifies HTTP outcomes into a `SyncResult` enum — 2xx `.success`,
  network errors / 408 / 429 / 5xx `.retryable` (exponential backoff
  up to 5 min), every other 4xx `.nonRetryable` (batch retained, loud
  release-build log, interval held steady so a client-side bug surfaces
  in seconds rather than being hidden behind a 5-min cadence).
  `NWPathMonitor` short-circuits the drain when there is no usable
  network, replacing 15 s URLSession-timeout spins in airplane mode
  with a fast no-op skip. `GpsLoggerApp` registers a `BGAppRefreshTask`
  (`com.gpslogger.personal.refresh`) and submits a new request on
  every background scene-phase transition, so the local queue drains
  even when the foreground 30 s `Timer` is suspended. The
  fetch → upload → delete invariant is documented at the class level
  and depends on the backend's unique `(device_id, created_at)` /
  `(device_id, fix_timestamp)` indexes from migration 004; replayed
  batches are absorbed server-side as no-ops. `Database` sets
  `PRAGMA synchronous=NORMAL` alongside WAL mode to make the
  crash-safety posture reviewable in code.
- **GPS audit follow-ups (1.2.5)**: stale-delivery gate is now
  symmetric (see filter rule (a) above). `LocationTracker.didUpdateLocations`
  sorts the incoming `[CLLocation]` by timestamp before iteration as
  defensive insurance against a future iOS change in array ordering.
  First-fix short-circuit in `LocationFilter` is explicitly documented:
  a multi-hour app relaunch is a first fix, not a first fix after gap,
  so the gap-aware rule is bypassed by design — the other gates
  (stale-delivery, validity, source, 50 m accuracy) have already run.
- **Wi-Fi-only uploads + opt-in diagnostics (1.2.10)**: battery-first,
  LAN-first product policy — uploads must never run on cellular,
  personal hotspot, or Low Data Mode. Enforcement is defense-in-depth:
  a `ReachabilitySnapshot` derived from `NWPathMonitor` gates every
  drain (`isSatisfied && usesWifi && !isExpensive && !isConstrained`),
  and the `URLSession` is built with `allowsCellularAccess = false`,
  `allowsExpensiveNetworkAccess = false`, and
  `allowsConstrainedNetworkAccess = false` so the OS itself refuses to
  carry the traffic if the predicate ever misfires. A Wi-Fi-regained
  transition resets the backoff to the base 30 s so accumulated queue
  drains on the next tick. `fix_diagnostics` is gated behind
  `Config.syncDiagnosticsEnabled` (UserDefaults, default `false`) —
  the channel was scaffolding for the 1.2.x filter audits and produced
  ~95% of on-device writes and uplink bytes on a typical walk. When
  off, `LocationTracker` skips snapshot construction + queue hop, and
  `SyncService.drainDiagnostics` early-returns. Table, backend endpoint,
  and 3-day retention are unchanged, so legacy rows continue to drain
  on the next Wi-Fi window. Flip at runtime for the next tuning
  campaign:

  ```
  defaults write com.gpslogger.personal syncDiagnosticsEnabled -bool YES
  ```

  then kill + relaunch so both callers re-read the flag. 10 new tests
  in `SyncPolicyTests` cover the predicate across every combination
  (cellular / hotspot / Low Data Mode / offline / wired / Wi-Fi-happy
  / pessimistic default), the URLSession configuration flags, and the
  diagnostics flag default + override.

- **Audit-driven simplification (1.2.9)**: an independent review of
  `LocationFilter` / `KalmanSmoother` / `StationaryDetector` against
  9,300 `fix_diagnostics` rows from two devices over four days drove
  the following subtractions. No functionality was added.

  1. **Tightened accuracy ceiling** from 50 m to 25 m. iPhone 13 Pro
     Max p90 = 14 m (near-lossless). iPhone 8 under canopy p90 =
     32 m; the tighter ceiling produces honest gaps instead of the
     earlier regime of `accept` rows at 30–50 m that were distorting
     traces by up to half a city block.
  2. **Deleted the three-tier `poorResumeAccuracy` gate** (60 s /
     120 s tiers from 1.2.2 / 1.2.6). Audit: 269 lifetime hits, all
     on iPhone 8, concentrated in a single deadlocked session that
     1.2.6 was specifically added to escape. Zero hits ever on
     iPhone 13 Pro Max. The single 25 m ceiling subsumes its intent
     without the self-reinforcing deadlock failure mode.
  3. **Mode-aware spike buffer**. Pedestrian / cycling threshold
     tightened from 750 m to 250 m after real multipath jumps of
     410 m on iPhone 8 were observed slipping through. Automotive
     mode (`MotionClassifier.Mode == .automotive`) keeps the
     original 750 m so legitimate high-speed sample deltas pass.
     `LocationTracker.apply(mode:)` flips via
     `LocationFilter.setAutomotive(_:)` on every mode change.
  4. **Stationary suppressions now logged** to `fix_diagnostics` as
     `<filter-decision>:stationarySuppress`. Stationary decisions
     used to be invisible post-hoc; without that signal, the
     detector could not be empirically tuned. The refactor moves
     the diagnostic snapshot write to *after* the full
     filter → smoother → stationary pipeline so the composed tag
     can include both verdicts.
  5. **Kalman `cos(origin.lat)` cached at reset** instead of
     recomputed on every `enuOffset` / `latLonFromENU` call.
     Numerical behavior unchanged; saves two trig calls per fix.
     Preserves the public static signatures for the round-trip
     unit test.
  6. **Gap-threshold documentation**. Config now includes a table
     enumerating the two remaining "lost the user" thresholds:
     `kalmanResetGapSeconds = 10 s` (velocity-staleness; a
     velocity prior older than 10 s is not a useful predictor)
     vs `resumeGapSeconds = 60 s` (cluster-validity; a candidate
     anchor with no observed fixes in 60 s can't be trusted).
     Different semantics, different thresholds, documented once so
     future edits don't have to rediscover the distinction.

  Deliberately *not* done, per the same audit: Kalman smoother
  removal (it's doing real work on clean GNSS, even if it cannot
  repair biased measurements on degraded GNSS), per-device
  filter tuning, map-matching re-introduction, multipath-from-
  residual detection. All rejected on empirical or platform
  grounds.

- **Silent-failure detectors (1.2.8)**: three classes of "everything
  looks fine but nothing records" scenarios now surface as impairment
  banners instead of failing quietly. All three are backed by
  specific Apple Developer Forum reports or WWDC23/24 guidance, and
  share the same observable symptom — an authorized app with an
  empty `points` table after a day of movement.

  1. **Reduced-accuracy detection (iOS 14+)** via
     `CLLocationManager.accuracyAuthorization`. "Always + Precise
     Location off" looks identical to "Always + Precise Location on"
     at the authorization-status level, but produces
     `horizontalAccuracy` values of 1–20 km that the 50 m filter
     rejects unconditionally. A new `TrackingImpairment.reducedAccuracy`
     banner now surfaces the condition and directs the user to
     Settings. Re-evaluated on every
     `locationManagerDidChangeAuthorization` callback, which iOS 14+
     fires both for permission changes and for accuracy-only toggles.

  2. **Background App Refresh impairment** via
     `UIApplication.shared.backgroundRefreshStatus` +
     `backgroundRefreshStatusDidChangeNotification`. Without
     Background App Refresh the
     `startMonitoringSignificantLocationChanges` relaunch path cannot
     resurrect a terminated app — the #1 cause of "tracking
     disappeared after I swiped the app away" reports. New
     `TrackingImpairment.backgroundRefreshDenied` banner fires for
     both `.denied` and `.restricted` (the latter is the Screen Time
     / MDM case) because the symptom is identical.

  3. **`didPauseLocationUpdates` / `didResume` delegate**
     implementations. Apple documents these as unused under
     `pausesLocationUpdatesAutomatically = false`, but production
     reports on the Apple Developer Forums show the system still
     pausing on rare OS/device combinations. The pause callback now
     re-issues `startUpdatingLocation()` (idempotent) and emits an
     unconditional `[tracker] WARN` line so the event is visible in
     Console.app on a release build.

  Mapping logic is pure and unit-tested:
  `TrackingImpairment.impairment(for:)` accepts either a
  `CLAccuracyAuthorization` or a `UIBackgroundRefreshStatus` and
  returns the corresponding impairment or `nil`. 7 tests in
  `TrackingImpairmentTests` cover the classification + a CaseIterable
  sanity check that no new impairment case ever ships with an empty
  `shortMessage`.

- **High-density sampling + Kalman smoother (1.2.7)**: the 2026-04-17
  session exposed the limits of the deterministic filter: 21 minutes
  of walking under partial-sky / canopy produced 69 accepted fixes
  all at HA=16 m or HA=32 m — Apple's own quality buckets — so the
  visible track zigzagged by ±30 m around the true path despite
  nothing being technically wrong with any individual sample. Three
  changes address it:

    1. `desiredAccuracy` promoted to `kCLLocationAccuracyBestForNavigation`
       and `distanceFilter` dropped to `kCLDistanceFilterNone` — the
       chip is given the inertial side-channels it needs and delivers
       every computed fix (~1 Hz) instead of throttling at 10 m.
    2. New `KalmanSmoother` module layered between `LocationFilter`
       and `StationaryDetector`; it averages the denser stream against
       a constant-velocity motion prior, collapsing per-sample HA
       noise well below the chip's quantization bucket without
       smearing sharp turns the way a coordinate-space moving average
       would.
    3. `StationaryDetector` gap-reset guard: the 2026-04-17 session
       also lost 4 real movement points at 18:45:06–18:45:31 because
       the detector interpreted a 5-minute GPS blackout as "user stood
       still for 5 minutes". New rule: if no fix is processed within
       `Config.resumeGapSeconds` (60 s), the returning fix becomes a
       fresh candidate anchor rather than the confirmation of a
       stationary window.

  Battery impact of (1) is real — Apple flags `BestForNavigation` as
  a "while plugged in / actively navigating" mode — and is accepted
  as the product trade for continuous high-fidelity tracking. Process
  noise σ_a defaults to 2 m/s² (multi-modal: walking, cycling,
  typical driving); future transport modes can tune it without
  touching the filter interface.
- **Discard-streak observability (1.2.6)**: `LocationTracker` counts
  consecutive discards and emits an unconditional
  `[tracker] WARN: N consecutive discards` line every 20 rejections
  so compound deadlocks are visible in Console.app without needing a
  `fix_diagnostics` Postgres query. *Historical note:* 1.2.6 also
  shipped a "deadlock escape valve" — a third tier in the gap-aware
  accuracy gate — that was removed in 1.2.9. Audit evidence showed
  the gate mostly just caused the deadlock its own escape valve was
  added to escape; a single 25 m accuracy ceiling subsumes the
  original multipath-convergence concern more cleanly.
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
    course, course_accuracy, decision)` — opt-in since 1.2.10. When
    `Config.syncDiagnosticsEnabled` is `true`, every raw `CLLocation` that
    enters `LocationTracker.didUpdateLocations` is captured here together
    with the filter's decision. **Uploaded** on the same 30 s Wi-Fi sync
    cadence as `points` (see below); the authoritative store is the backend
    Postgres table. Local rows are deleted on successful 2xx; a 3-day
    retention window in `cleanupDiagnostics` covers prolonged backend
    outages and also drains legacy rows left over from before the flag was
    flipped off. Default is `false` — the channel was scaffolding for the
    1.2.x filter tuning and produced ~95% of disk writes and uplink bytes
    on a typical walk. Enable at runtime for the next tuning campaign:
    `defaults write com.gpslogger.personal syncDiagnosticsEnabled -bool YES`
    (restart required). See `QA.md` for how to query the backend after an
    anomaly.
- **Sync**: a `Timer` (the only in-app timer) fires every 30 s and runs
  two independent drains on a private serial `syncQueue`:
  - `points` → `POST /points` — drives the visible trace. Pulls up to 100
    rows, stamps the device ID on each payload element (from the injected
    `SyncService.deviceId`, not per-row), and deletes on 2xx.
  - `fix_diagnostics` → `POST /diagnostics` — mirror shape of the points
    drain. Gated (1.2.10) on `Config.syncDiagnosticsEnabled`; when the
    flag is false the channel short-circuits with no fetch and no HTTP.
    Each channel has its own in-flight guard so one slow response cannot
    stall the other.

  **Wi-Fi-only uploads (1.2.10).** Both channels gate on a
  `ReachabilitySnapshot` derived from `NWPathMonitor` — any
  non-Wi-Fi path (cellular, personal hotspot, Low Data Mode) skips the
  drain entirely. The `URLSession` is constructed via
  `Config.makeSyncSessionConfiguration()` with
  `allowsCellularAccess`, `allowsExpensiveNetworkAccess`, and
  `allowsConstrainedNetworkAccess` all `false`, so even a logic bug
  above cannot leak bytes onto cellular. A Wi-Fi-regained transition
  resets the backoff interval to the base 30 s so a queue accumulated
  during the offline window drains promptly.

  HTTP outcomes are classified (1.2.4): 2xx resets the backoff interval;
  network errors / 408 / 429 / 5xx double it up to a 5-min cap; every
  other 4xx holds the interval steady and logs loudly so a schema drift
  or rotated API key is visible within seconds. The same code path is
  exposed as `drainOnce(completion:)` and invoked by a registered
  `BGAppRefreshTask` so the local queue drains in background even when
  the `Timer` is suspended. Failures stay in the local DB for the next
  tick — no partial delete, no retry storms; replay safety is
  guaranteed by the backend's idempotent `ON CONFLICT DO NOTHING`
  constraints (migration 004).
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
