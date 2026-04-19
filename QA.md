# QA — GpsLogger

Covers automated tests and manual end-to-end scenarios.

## Automated tests

### iOS unit tests (74 cases across 7 test files)

```
cd ios
xcodegen generate
xcodebuild test -project GpsLogger.xcodeproj -scheme GpsLoggerTests \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

**`LocationFilterTests` (20 cases)** — every gate in the filter
pipeline end-to-end:

- validity gate (negative `horizontalAccuracy` → discard `.invalidFix`)
- **source gate** (GPS-origin detection via `speed` and `verticalAccuracy`):
  rejects fixes whose `speed < 0` or `verticalAccuracy ≤ 0`, which is the
  documented sentinel for Wi-Fi / cell-tower fallback fixes that lack Doppler
  velocity and altitude. Load-bearing defense against the "park-canopy
  teleport" anomaly.
- source gate runs before the accuracy value gate (so a pristine
  `horizontalAccuracy = 5 m` but `speed = -1` fix is still rejected)
- accuracy value gate (`horizontalAccuracy > 25 m` → discard `.poorAccuracy`,
  tightened from 50 m in 1.2.9)
- chronology gate (`Δt ≤ 0` → discard `.staleTimestamp`)
- implausible-speed gate (500 km/h ceiling)
- minimum-distance gate (`< 10 m` → discard `.tooClose`)
- spike buffer (A → B(far > 250 m walking / > 750 m automotive) →
  C(near A) → drop B), with pedestrian threshold tightened from
  blanket 750 m in 1.2.9
- **pending timeout** (1.2.1): a buffered spike older than
  `Config.pendingTimeoutSeconds` is dropped silently before the next
  fix is evaluated, so an app-backgrounding event cannot leave stale
  spike state across sessions
- **stale-delivery gate** (1.2.2, symmetric in 1.2.4): fix with
  timestamp > 10 s behind wall clock is rejected as
  `discard:staleDelivery`; gate runs before all other gates; fix
  within threshold is accepted; **symmetric variant (1.2.5)** also
  rejects fixes whose timestamp is > 10 s *ahead* of wall-clock, which
  happens on system-clock skew backward (NTP correction, manual time
  change, DST edge)
- **automotive spike-jump widening** (1.2.9): pedestrian default
  `spikeJumpMeters` is 250 m; `filter.setAutomotive(true)` switches
  it to 750 m so legitimate high-speed sample deltas pass. Test
  fabricates a ~500 m A→B jump: under walking the jump is buffered
  as suspicious, under automotive the same jump is accepted as real
  motion
- regression: stationary GPS fix (speed = 0, valid vertical accuracy)
  must still be accepted — the source gate must not confuse a
  standing-still user with a network-derived fix
- regression: a dense burst of Wi-Fi-style fallback fixes leaves
  `lastAccepted` pinned to the last real GPS fix and never corrupts
  the spike buffer

**`DatabaseTests` (7 cases)** — insert/fetch/delete/retention
invariants on an in-memory SQLite opened via `Database(path: ":memory:")`:

- `points`: insert 5 → fetch → delete → count == 0
- `points`: 250-row backlog drains in exactly 3 ticks of 100 each
- `fix_diagnostics`: log → fetch → delete cycle leaves the store empty
- `fix_diagnostics`: same 250-row drain cycle
- **sentinel round-trip**: `speed = -1, vAcc = -1, course = -1` survive
  the insert/fetch round trip intact (the whole point of the table)
- **race guard**: rows written *after* a `fetchDiagnosticsBatch` but
  *before* the matching `deleteDiagnostics(ids:)` are not collaterally
  deleted — the delete only targets the ids that were in the fetched
  batch
- retention: `cleanupDiagnostics(olderThanDays: 3)` does not touch
  fresh rows, so sync-pending rows can't be pruned from under the
  upload path

**`MotionClassifierTests` (10 cases)** — the pure static
`classify(...)` rule that maps CoreMotion flags to the coarse mode:

- low-confidence reading → returns nil so the caller keeps the prior mode
- each mode (`.automotive`, `.cycling`, `.pedestrian`, `.unknown`) at
  medium/high confidence
- running maps to `.pedestrian` (same activityType hint as walking)
- overlap priority: `automotive > cycling > pedestrian` so a
  transition moment where CoreMotion briefly reports `automotive &&
  walking` (e.g. getting out of a car) stays on the vehicle hint
  until walking is confident-alone
- stationary/no-activity with high confidence → `.unknown` (caller
  keeps the prior hint)

**`StationaryDetectorTests` (11 cases)** — Phase-A/B state machine,
the 1.2.1 clock-skew guard, and the 1.2.7 gap-reset guard:

- first fix is accepted and becomes the candidate
- fixes inside `stationaryRadius` before the window elapses are still
  forwarded
- fix outside the radius resets the candidate
- sustained cluster for ≥ `windowSeconds` transitions into Phase B
  (suppressing subsequent fixes)
- Phase B fix inside `resumeRadius` is suppressed
- Phase B fix beyond `resumeRadius` exits stationary and adopts the
  new fix as a fresh candidate
- hysteresis: a fix between `stationaryRadius` and `resumeRadius`
  stays suppressed (no flapping on a single borderline fix)
- **negative-age guard** (1.2.1): an anchor timestamp newer than the
  incoming fix (NTP correction / DST transition / cached replay)
  resets the candidate instead of stalling the window forever
- **gap-reset in Phase A** (1.2.7): a 5-min gap with no intermediate
  fixes followed by a returning fix inside the radius must not be
  reinterpreted as "stationary for 5 min" — the guard resets the
  candidate so the cluster clock restarts from real movement evidence
- **gap-reset in Phase B** (1.2.7): a long gap also clears a previously
  declared stationary center, so a returning fix inside `resumeRadius`
  is accepted rather than suppressed
- `reset()` clears both candidate and stationaryCenter

**`KalmanSmootherTests` (9 cases)** — observable contract of the 1.2.7
2D constant-velocity Kalman filter:

- first-fix passthrough: output coordinate equals input (no state yet
  to blend against), and non-horizontal fields (altitude, vertical
  accuracy, speed, course) flow through unchanged
- reported `horizontalAccuracy` on the output strictly improves after
  a handful of co-located fixes (position-only measurements collapse
  the state covariance)
- zigzag smoothing: a straight east-walk with ±10 m cross-track noise
  at HA=32 m has the smoothed cross-track average driven to ≤ 60 % of
  the raw average over the last-10-sample window
- outlier damping: a single 50 m cross-track spike in a clean walk
  pulls the smoothed output less than 30 m — the motion prior bounds
  the innovation, without the KF ever "rejecting" anything (that stays
  upstream in `LocationFilter`)
- long-gap reset: `dt > resetGapSeconds` discards the cached velocity
  estimate so the post-gap output equals the post-gap input
- out-of-order timestamp reset: `dt ≤ 0` triggers the same reset path
- ENU round-trip consistency: forward + inverse mapping agree to
  sub-meter tolerance at city scale so filter-space math does not
  silently shift coordinates

**`TrackingImpairmentTests` (7 cases)** — the 1.2.8 silent-failure
mapping helpers. Pure static functions, testable without mocking
`CLLocationManager` or `UIApplication`:

- `CLAccuracyAuthorization.fullAccuracy` → no impairment
- `CLAccuracyAuthorization.reducedAccuracy` → `.reducedAccuracy`
  (iOS 14+ Precise Location toggle off; the silent-black-trace case
  our 25 m filter ceiling would otherwise hide)
- `UIBackgroundRefreshStatus.available` → no impairment
- `.denied` → `.backgroundRefreshDenied`
- `.restricted` (Screen Time / MDM policy) → `.backgroundRefreshDenied`
  (same symptom as `.denied` — no SLC relaunch — same user-visible
  message)
- every `TrackingImpairment` case has a non-empty `shortMessage`
  (CaseIterable guard against a silent empty banner if someone
  forgets the switch arm)
- new 1.2.8 impairment messages mention user-actionable guidance
  (Settings / force-quit terminology) so the banner is never a
  dead-end warning

**`SyncPolicyTests` (10 cases)** — the 1.2.10 Wi-Fi-only enforcement:

- `ReachabilitySnapshot.isWifiOnlyReachable` predicate across every
  combination: Wi-Fi-happy (accept), pessimistic default before
  NWPathMonitor publishes (reject), cellular (reject via `!usesWifi`
  + `isExpensive`), personal hotspot (reject: Wi-Fi link but
  `isExpensive = true`), Low Data Mode (reject via `isConstrained`),
  airplane mode / offline (reject via `!isSatisfied`), wired /
  loopback-only default route (reject because `usesWifi = false`)
- `Config.makeSyncSessionConfiguration()` regression guard —
  `allowsCellularAccess`, `allowsExpensiveNetworkAccess`, and
  `allowsConstrainedNetworkAccess` all `false`;
  `waitsForConnectivity = false`;
  `timeoutIntervalForRequest == Config.syncRequestTimeoutSeconds`
- `Config.syncDiagnosticsEnabled` default is `false` (purge any
  stray UserDefaults override before asserting)
- `Config.syncDiagnosticsEnabled` honors a UserDefaults override
  (`defaults write … syncDiagnosticsEnabled -bool YES`) so the
  runtime enable path works without a rebuild

### Backend validator unit tests

```
cd backend
node --test test/
```

Covers `validate.js` — the pure input-validation layer that sits in front of every
DB write and read.

**`validateBatch` (POST /points):**

- valid single-point batch
- valid multi-point batch
- rejects non-array body / null / string / number
- rejects empty batch
- rejects batch > `MAX_BATCH` (1000)
- rejects `latitude` out of `[-90, 90]`, non-finite, non-number
- rejects `longitude` out of `[-180, 180]`, non-finite, non-number
- rejects missing/invalid `created_at`
- rejects missing/empty `device_id`, non-string `device_id`, `device_id` longer than 128 chars
- rejects `null` element

**`validateDiagnosticsBatch` (POST /diagnostics):**

- valid single-row batch
- valid multi-row batch
- **accepts negative sentinels** (`speed = -1`, `vertical_accuracy = -1`,
  `course = -1`, etc.) — these are CoreLocation's documented values for
  "no data" and are exactly what we need to preserve for post-hoc analysis
- rejects non-array body / empty / oversized
- rejects `null` element
- rejects out-of-range `latitude` / `longitude`
- rejects missing/invalid `logged_at`, `fix_timestamp`
- rejects missing / non-finite numeric fields (`horizontal_accuracy`,
  `vertical_accuracy`, `altitude`, `speed`, `speed_accuracy`, `course`,
  `course_accuracy`) — NaN/Infinity/string/missing all return 400
- rejects missing/empty/oversized `decision` (max 64 chars)
- rejects missing/empty/oversized/non-string `device_id`

**`validateRange` (GET /points):**

- requires `device_id`, parses optional `from`/`to`, rejects invalid dates, rejects `from > to`

The DB layer itself is intentionally thin (parameterized inserts and a single
filter+sort select) and is exercised end-to-end via the smoke tests below.

### Frontend unit tests (29 cases)

```
cd frontend
npm test
```

Covers the pure route-processing functions extracted into `src/route.ts`
so they can be tested in `vitest`'s default Node environment without
loading `react-leaflet` (which requires the DOM).

**`splitByTimeGaps` (6 cases)** — turns the time-sorted `Point[]` into
time-gap groups:

- empty input returns `[]` (no placeholder group)
- single point produces one one-point group — the input survives the
  segmentation stage even when there is nothing to gap against
- consecutive close points stay in the same group
- gap boundary is **strictly greater than** `GAP_MS` (exactly 5 min is
  not a split; 5 min + 1 s is)
- many gaps produce the expected number of groups
- a lone fix between two clusters becomes its own 1-point group,
  unblocking the singleton-render path in `buildSegments`

**`downsampleGroups` (5 cases)** — global budget with per-group
proportional allocation:

- under-budget input returns the same array reference (identity, no
  reallocation) so React's `useMemo` doesn't invalidate needlessly
- over-budget input compresses below `MAX_POINTS` while preserving the
  first and last fix of each group (polyline endpoints stay anchored
  to the real trace)
- 2-point group passes through unchanged (short-circuit for already-minimal groups)
- singleton group passes through unchanged
- budget splits proportionally: a 2N-point group ends up with more
  sampled points than a 0.5N-point group

**`gradientColor` (3 cases)** — Blue → Purple → Red hue mapping:

- output is always a valid `hsl(...)` string
- anchor values: t=0 → 240°, t=0.5 → 285°, t=1 → 360°
- monotonic across [0, 1]

**`buildSegments` (6 cases)** — render-primitives builder:

- empty input → empty render
- **singleton regression (1.2.4)**: a 1-point group emits a singleton
  with the right color, no polyline segments — the audit-day bug where
  lone fixes were silently dropped is locked in
- multi-point group emits polyline segments with ≥ 2 positions each,
  no singletons
- mixed groups emit both polyline segments and singletons
- global-`t` preservation: a singleton at the chronological centre
  picks up `hue = 285°` (purple), proving the gradient spans the whole
  query window rather than restarting per group
- bookends: first segment is near blue (240°) and last segment is near
  red (360°) across a two-group window

**`arrowsAlong` (9 cases, 1.3.1)** — direction-of-travel chevron
placement along a polyline group:

- empty input returns `[]` (fewer than 2 positions cannot carry a
  direction)
- a polyline shorter than one interval returns `[]` (no room between
  the Start and End markers for an arrow at the centre)
- a 1 km straight segment at the 150 m default interval places 5–7
  arrows — tolerates off-by-one in the count bound so the test doesn't
  fixate on implementation details
- the first arrow is placed at ~half-interval (≈75 m) from the start
  so it doesn't collide with the Start marker
- the last arrow keeps at least a half-interval clear of the end so
  it doesn't collide with the End marker
- bearing on a due-north polyline is ≈ 0° (with wrap-around tolerance
  for `359.x°`)
- bearing on a due-east polyline is ≈ 90°
- bearing follows a right-angle turn: arrows placed on the north leg
  read ≈ 0°, arrows placed on the east leg read ≈ 90°
- the `ARROW_INTERVAL_METERS` default is honoured: arrow density on a
  10 km trace tracks the constant within a ±30 m tolerance

### Smoke tests (after `docker-compose up`)

```bash
# health
curl -fsS http://localhost:3000/health

# insert (device_id is required on every element)
curl -fsS -X POST http://localhost:3000/points \
    -H 'Content-Type: application/json' \
    -d '[
      {"latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00Z", "device_id": "demo"},
      {"latitude": 37.7750, "longitude": -122.4180, "created_at": "2024-01-01T12:00:05Z", "device_id": "demo"}
    ]'
# → {"inserted":2,"submitted":2}

# idempotency — send the same batch a second time: duplicates skipped
curl -fsS -X POST http://localhost:3000/points \
    -H 'Content-Type: application/json' \
    -d '[
      {"latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00Z", "device_id": "demo"},
      {"latitude": 37.7750, "longitude": -122.4180, "created_at": "2024-01-01T12:00:05Z", "device_id": "demo"}
    ]'
# → {"inserted":0,"submitted":2}  ← migration 004 unique index + ON CONFLICT DO NOTHING

# read back (device_id is required on the query string)
curl -fsS 'http://localhost:3000/points?device_id=demo&from=2024-01-01T00:00:00Z&to=2024-01-02T00:00:00Z'
# → [{"id":1,"latitude":37.7749, ...}, ...]

# bad request — invalid latitude
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/points \
    -H 'Content-Type: application/json' \
    -d '[{"latitude":999,"longitude":0,"created_at":"2024-01-01T00:00:00Z","device_id":"demo"}]'
# → 400

# bad request — missing device_id on GET
curl -sS -o /dev/null -w '%{http_code}\n' \
    'http://localhost:3000/points?from=2024-01-01T00:00:00Z&to=2024-01-02T00:00:00Z'
# → 400

# diagnostics — healthy GNSS row
curl -fsS -X POST http://localhost:3000/diagnostics \
    -H 'Content-Type: application/json' \
    -d '[
      {
        "logged_at": "2026-04-15T17:45:00.000Z",
        "fix_timestamp": "2026-04-15T17:45:00.000Z",
        "latitude": 39.46975, "longitude": -0.37739,
        "horizontal_accuracy": 8.2, "vertical_accuracy": 4.5, "altitude": 15.3,
        "speed": 1.3, "speed_accuracy": 0.4,
        "course": 92.0, "course_accuracy": 5.0,
        "decision": "accept",
        "device_id": "demo"
      }
    ]'
# → {"inserted":1,"submitted":1}

# diagnostics — Wi-Fi / cell-tower fallback row (negative sentinels must pass)
curl -fsS -X POST http://localhost:3000/diagnostics \
    -H 'Content-Type: application/json' \
    -d '[
      {
        "logged_at": "2026-04-15T17:46:01.000Z",
        "fix_timestamp": "2026-04-15T17:46:01.000Z",
        "latitude": 39.48, "longitude": -0.31,
        "horizontal_accuracy": 42.0, "vertical_accuracy": -1, "altitude": 0,
        "speed": -1, "speed_accuracy": -1,
        "course": -1, "course_accuracy": -1,
        "decision": "discard:nonGpsSource",
        "device_id": "demo"
      }
    ]'
# → {"inserted":1,"submitted":1}

# bad request — invalid latitude in diagnostics
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/diagnostics \
    -H 'Content-Type: application/json' \
    -d '[{"logged_at":"2026-04-15T17:45:00Z","fix_timestamp":"2026-04-15T17:45:00Z","latitude":999,"longitude":0,"horizontal_accuracy":1,"vertical_accuracy":1,"altitude":0,"speed":0,"speed_accuracy":0,"course":0,"course_accuracy":0,"decision":"accept","device_id":"demo"}]'
# → 400
```

## Manual E2E scenarios

All scenarios assume:

- `docker-compose up --build` has run on the Mac (migrations 001–005 applied)
- iPhone has the app installed with `API_BASE_URL` in
  `ios/GpsLogger.xcconfig` pointing to the Mac's current LAN IP
- iPhone and Mac share the same Wi-Fi network (**required** since
  1.2.10 — sync skips on cellular, personal hotspot, and Low Data Mode;
  the URLSession itself is built with `allowsCellularAccess = false`)
- Location permission is **Always**; Motion & Fitness permission is
  allowed (both prompts appear on first launch)
- For any scenario that reads `fix_diagnostics` below, **diagnostics
  must be enabled on the device** (off by default since 1.2.10). On the
  iPhone via Xcode or a preconfigured profile, or via a dev Mac while
  the phone is mirroring its defaults:

  ```
  defaults write com.gpslogger.personal syncDiagnosticsEnabled -bool YES
  ```

  Kill + relaunch the app so `LocationTracker` and `SyncService`
  re-read the flag. Sessions recorded while the flag is off will have
  no corresponding `fix_diagnostics` rows at all.

> The iOS app is **always-on**: there is no Start/Stop button. Tracking begins
> in `AppContainer.init` and the pulsing green dot in the top-right corner
> indicates the tracker is active. Copy the **Device ID** from the app's
> footer into the web UI's Device ID field before visualizing.

### 1. Long drive (30+ min)

- Launch app → begin driving.
- Expected: counter ticks up as ~10 m+ movements accumulate.
  Every ~30 s it drops by the batch size (up to 100) after a successful sync.
- Park.
- Paste the device ID into the web UI, pick the drive's time range, click **Visualize**.
- Expected: a gradient polyline traces the actual route, blue at the start,
  red at the end. Route fits the viewport.

### 2. Stops / stationary periods (StationaryDetector)

- Launch app, sit stationary for 3+ minutes, then walk around.
- Expected: during the first ~150 s the distance filter alone suppresses
  inserts. After 150 s within 20 m of the candidate anchor, `StationaryDetector`
  declares the user stationary and drops everything until a fix lands more
  than 30 m from the cluster center.
- Walk away (≥30 m). New points start flowing again.

### 3. GPS spike rejection (LocationFilter)

- Launch app, walk normally for a few minutes.
- Expected: in the web UI the route has no >750 m teleport jumps even in
  urban canyons. The accuracy gate (>50 m horizontal accuracy) and spike
  buffer (A → B(>750 m) → C(near A) → drop B) silently filter glitches.
  No legitimate transport mode (walking, driving, train) is affected.

### 4. No internet (offline queue)

- Launch app, begin walking.
- Toggle the Mac backend off (`docker-compose stop backend`).
- Expected: counter keeps growing — upload fails silently, points stay in the
  local SQLite.
- Bring the backend back up (`docker-compose start backend`).
- Expected: counter drains within a few sync cycles as queued batches flush.

### 5. Background tracking

- Launch app, lock the iPhone.
- Put it in a pocket and walk for a few minutes.
- Expected: blue location indicator remains visible on unlock. Counter has
  increased. Visualizing the range in the web UI shows the walked route.

### 6. App restart mid-session

- Launch app, accumulate a few dozen points.
- Swipe-kill the app.
- Relaunch.
- Expected:
  - Counter reloads from the DB (seed via `initialCount()`) showing the
    still-unsynced points from before the kill.
  - Tracking resumes immediately — no button to press; `LocationTracker`
    starts from `AppContainer.init`.
  - `SyncService.start()` (also in `AppContainer.init`) drains the queue.
  - The same device ID is restored from the Keychain, so previously-uploaded
    points remain visible under the same ID in the web UI.

### 7. Backend restart (data durability)

- Insert points via the iPhone.
- `docker-compose restart db`
- Query `/points` again with the same `device_id` and range.
- Expected: all previously-inserted points are still there — Postgres volume
  `pgdata` persists across container restarts.

### 8. Frontend downsampling

- Insert 10k+ synthetic points via `curl` (remember `device_id`).
- Visualize the range.
- Expected: the polyline renders smoothly in <1 s. The status bar shows the
  full count ("10,247 points"). Internally, the map only renders ≤ 4000
  after downsampling, across up to 64 colored segments per group.

### 9. Time-gap polyline split

- Insert two clusters of points for the same `device_id` with a >5 minute
  gap between them at distant coordinates.
- Visualize a range that covers both clusters.
- Expected: two separate polylines render — **no straight line bridges the
  two clusters**. The gradient color (blue → red) is global across both
  groups, so the second cluster picks up the gradient where the first
  finished.

### 10. Logout / device switch (frontend)

- In the web UI, enter a device ID and visualize. Reload the page —
  expected: the device ID is restored from `localStorage`.
- Click **Logout**. Expected: device ID and points clear, time range resets,
  status reverts to "Enter device ID to begin". A reload now shows the
  empty initial state.

### 11. Multi-modal activityType swap (MotionClassifier)

- Launch app with **Motion & Fitness** permission granted. Go for a
  short walk. Then get on a bicycle or into a car/bus/train and stay
  on it for at least 2 minutes.
- Expected: while walking, CoreLocation's hint is `.fitness` (startup
  default). Within ~30–60 s of sustained vehicle motion,
  `MotionClassifier` sees `automotive` with medium/high confidence
  and `LocationTracker` swaps `manager.activityType` to
  `.automotiveNavigation`. In DEBUG builds the console shows
  `[motion] mode -> automotive` followed by
  `[tracker] activityType -> 1 (automotive)`.
- Cross-check via `fix_diagnostics`: after the swap, accepted rows
  should continue flowing with normal `speed` / `horizontal_accuracy`
  for vehicle-scale motion. `decision = accept`, no regression.
- When the trip ends and you step out, the classifier eventually
  flips back to `.pedestrian` and the hint returns to `.fitness`.

### 12. TrackingImpairment banner

- **permissionDenied**: open Settings → GpsLogger → Location → *Never*.
  Expected: within a few seconds the app shows an orange banner
  at the top saying "Location permission denied — open Settings to
  allow." Counter stops incrementing. Switch back to **Always** —
  banner disappears, counter resumes, tracking state machine resets
  internal filter anchors so the first new fix is a clean baseline.
- **backgroundRequiresAlways**: Settings → GpsLogger → Location →
  *While Using the App*. Expected: banner "Background tracking needs
  Always permission." Foreground tracking still works; background
  tracking silently drops (this is the whole reason the banner
  exists — tell the user before their trip has gaps). Restore
  **Always** to clear.
- **motionPermissionDenied**: Settings → GpsLogger → Motion & Fitness
  off. Expected: banner "Motion sensing off — vehicle mode will not
  engage." The app still records everything correctly, but
  `activityType` stays on `.fitness` regardless of real mode.

### 13. Background refresh drain (1.2.4, simulator-only)

Production delivery of `BGAppRefreshTask` is throttled by iOS based on
usage patterns and battery state (typically no more sooner than every
~15 min, often much longer on a new install). For a predictable
verification run use the debugger to simulate a launch.

- Run the app in the simulator from Xcode, then suspend it with
  `Cmd+Shift+H` twice to send it to background.
- In the Xcode debug console (lldb) run:
  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.gpslogger.personal.refresh"]
  ```
- Expected: the `handleBackgroundRefresh` log fires,
  `SyncService.drainOnce` posts at most one batch of `points` and one
  of `fix_diagnostics`, and the task completes with
  `setTaskCompleted(success: true)`. Re-submit the next refresh is
  logged by the `scheduleBackgroundRefresh` call at the top of the
  handler, so the next cycle is already queued before iOS releases
  our runtime.
- Re-foreground the app: the standard 30 s `Timer` path takes over;
  no duplicates appear in the backend because migration 004's unique
  `(device_id, created_at)` / `(device_id, fix_timestamp)` indexes
  absorb any race between the background drain and the foreground tick.

### 14. Error-aware backoff (1.2.4, optional manual)

To verify that 4xx responses do **not** stretch the sync interval,
temporarily set `API_KEY` on the backend to a random value after the
iOS app has already sent its first batch:

```bash
API_KEY=rotated docker compose up -d backend
```

- Expected: the iOS debug console shows
  `[sync] points NON-RETRYABLE: points HTTP 401 — batch retained` on
  every tick at the base 30 s cadence (not doubling).
- Restore the original `API_KEY` (or clear it) and within one tick
  the batch uploads successfully and the interval stays at the base
  value. Retryable failures (kill the backend entirely so requests
  time out) are the ones that actually double the interval up to the
  5-min cap.

## 1.2.7 sampling-density + Kalman regression plan

Targeted field regression for the 1.2.7 overhaul of the sampling path
(`BestForNavigation` + `distanceFilter = None`), the Kalman smoother
(`KalmanSmoother.swift`), and the `StationaryDetector` gap-reset guard.
Verifies:

- **K1** — straight outdoor walks no longer show the HA=32 m zigzag
  from 1.2.6 and earlier; the rendered polyline follows the true path
  within a handful of meters even in partial-sky conditions.
- **K2** — turns and true-motion changes are still visible (no
  smeared corners from over-smoothing).
- **K3** — GPS blackouts followed by signal recovery no longer lose
  the first few post-recovery fixes to a false-stationary verdict
  (regression for the 2026-04-17 18:45:06 bug).
- **K4** — upstream outlier rejection (`LocationFilter` spike buffer,
  source gate) still bites; the smoother must not be credited with
  rejection it doesn't perform.

Prereqs: iPhone on 1.2.7 (footer reads `v1.2.7 (12)`), `docker
compose ps` healthy, Console.app attached with filter `process =
GpsLogger`, Device ID copied as `<DEV>`. Total field time ~40 min.

### 19. Straight outdoor walk — zigzag gone (1.2.7, K1)

Primary acceptance test for the Kalman smoother. The 2026-04-17 session
walked a straight sidewalk for 10 min and the rendered polyline zigzagged
by ±20 m between consecutive points because every accept was at HA=32 m
and the raw coordinates scattered accordingly.

- Walk **≥ 500 m on a straight sidewalk** (not a park path — straight
  roads give a visual reference). Moderate tree canopy or 4-story
  buildings is ideal; pure clear-sky does not exercise the filter.
- Open the frontend, narrow the time range to this walk, zoom to
  street level.
- Expected: the polyline follows the sidewalk within ~10 m; no
  sawtooth pattern. Individual dots may still show HA circles up to
  32 m (that's the chip's report) but the **line between them** is
  smooth.
- Query to compare raw `fix_diagnostics` vs. stored `points` for the
  same window:

  ```sql
  -- Raw per-accept HA (chip report)
  SELECT to_char(fix_timestamp, 'HH24:MI:SS') AS t,
         ROUND(horizontal_accuracy::numeric, 1) AS ha
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<start>' AND '<end>'
     AND decision = 'accept'
   ORDER BY fix_timestamp;
  ```

  If the map still shows a zigzag: confirm the running binary is
  1.2.7, then compute cross-track deviation from the walked line —
  any persisted `points` row farther than ~15 m from the true
  sidewalk centerline on a clear-sky section is a regression. The
  baseline on 1.2.6 is ~±30 m.

### 20. Post-blackout movement is preserved (1.2.7, K3)

Regression for the 2026-04-17 18:45:06 false-stationary bug. A
5-minute GPS blackout that looks identical to "user stood still for
5 min" must not suppress the first minute of real post-recovery
movement.

- Walk outside for ~2 min to warm up the filter (several accepts
  land in `fix_diagnostics`).
- Enter a building and stay ≥ 5 min so GPS dies completely
  (watching Console for `[tracker] discard nonGps ...` confirms the
  blackout is real, not just weak).
- Exit and walk normally for ≥ 2 min.
- Expected: on the frontend, the **first 4–10 points** after
  building-exit are all rendered (not just one every 30–60 s). No
  visible dead-segment of `suppress stationary` at the exit.
- Query for post-exit accepts and cross-check against the persisted
  `points` table (remember that `points` now stores Kalman-smoothed
  coords, so direct `fix_timestamp ↔ created_at` equality still
  holds but the lat/lon differ slightly from the raw row):

  ```sql
  SELECT d.fix_timestamp,
         d.horizontal_accuracy,
         d.decision,
         (SELECT p.id FROM points p
           WHERE p.device_id = d.device_id
             AND p.created_at = d.fix_timestamp) AS points_id
    FROM fix_diagnostics d
   WHERE d.device_id = '<DEV>'
     AND d.fix_timestamp BETWEEN '<exit-utc>'
                             AND '<exit-utc>'::timestamptz + INTERVAL '2 minutes'
     AND d.decision = 'accept'
   ORDER BY d.fix_timestamp;
  ```

  Every `accept` in the first minute after exit must have a
  non-null `points_id`. If any are NULL (i.e. the StationaryDetector
  suppressed them), compare against the pre-gap last accept: if
  that accept's lat/lon is within 20 m of the post-gap accept and
  more than 60 s older, the gap-reset guard is not firing — check
  `Config.resumeGapSeconds` and the `lastSeen`-based branch at the
  top of `StationaryDetector.consume`.

### 21. Sharp turn fidelity (1.2.7, K2)

Verifies the Kalman smoother's constant-velocity motion prior does
not smear a real 90° turn into a rounded curve. σ_a = 2 m/s² was
chosen with this test in mind; if it fails, either σ_a is too low
(over-smoothing) or the process-noise matrix is miscomputed.

- Walk a right-angle city-block corner at a steady pace. Note the
  wall-clock seconds at the corner (screenshot Console.app).
- After the walk, open the frontend and zoom to the corner.
- Expected: the polyline *turns* at the corner. A smooth S-curve
  over 3+ samples is a regression — the turn should be visible
  within 1–2 sample intervals of the corner crossing.
- If wrong, pull the accepted fixes around the corner and compute
  the implied velocity vector:

  ```sql
  SELECT fix_timestamp,
         horizontal_accuracy,
         latitude, longitude
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<corner-utc>'::timestamptz - INTERVAL '30 seconds'
                           AND '<corner-utc>'::timestamptz + INTERVAL '30 seconds'
     AND decision = 'accept'
   ORDER BY fix_timestamp;
  ```

  The raw trajectory should turn; if the *raw* turns but the
  rendered `points` rows don't, the smoother is smearing. Bumping
  `Config.kalmanProcessAccelStdDev` from 2.0 to 2.5 or 3.0 gives
  the filter more velocity-update agility at the cost of slightly
  less smoothing on straight segments.

### 22. Source-gate still bites on network fallback (1.2.7, K4)

Sanity check that the smoother has not weakened any upstream gate.
The Kalman filter sits *after* `LocationFilter.accept`, so a
Wi-Fi-origin "teleport" fix must still be rejected before reaching
the smoother.

- Reproduce the park-canopy or subway-exit Wi-Fi fallback scenario
  that historically produced `discard:nonGpsSource` rows.
- Expected: `fix_diagnostics` still shows the discards; the `points`
  table has no rows at the offending fix timestamps.
- Query:

  ```sql
  SELECT COUNT(*) FILTER (WHERE decision = 'discard:nonGpsSource')  AS wifi_rejects,
         COUNT(*) FILTER (WHERE decision = 'accept')                AS accepts
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<window-start>' AND '<window-end>';
  ```

  If `wifi_rejects` ever drops to zero during a session that
  historically showed them, it means the source gate has been
  accidentally relaxed — the 1.2.7 change should not have touched
  `LocationFilter.consume` at all.

**Out of scope for the 1.2.7 round.** Unchanged and not retested
here: source gate (#22 is a sanity touch, not a re-validation),
spike buffer, sync/backoff, BGTaskScheduler, backend API, frontend
visualization logic, Docker stack. Scenarios #1–14 cover those.

(The 1.2.6 three-tier gap-aware gate regression scenarios were
removed from QA.md in the 1.2.9 round along with the gate itself.)

## 1.2.9 audit-driven simplification regression plan

Targeted field regression for the 1.2.9 subtractions. Verifies:

- **S1** — tightened 25 m accuracy ceiling produces honest gaps on
  iPhone 8 under canopy instead of 30–50 m accepts. iPhone 13 Pro Max
  loses < 1% of fixes (near-lossless).
- **S2** — 250 m pedestrian spike threshold catches multipath jumps
  that the old 750 m blanket let through.
- **S3** — automotive mode widens the spike threshold so legitimate
  high-speed vehicle deltas still pass.
- **S4** — stationary-suppress decisions now appear in
  `fix_diagnostics` as `<base>:stationarySuppress` tags.
- **S5** — the removed `poorResumeAccuracy` gate is well and truly
  gone: no `discard:poorResumeAccuracy` rows appear in the diagnostic
  stream regardless of gap length.

Prereqs: iPhone on 1.2.9 (footer reads `v1.2.9 (14)`),
`docker compose ps` healthy, Device ID copied as `<DEV>`.

### 23. Ceiling tightening, iPhone 8 under canopy (1.2.9, S1)

Primary validation that the ceiling change is doing what the audit
expected: fewer persisted-accept rows on iPhone 8 under tree cover.

- Walk a ~30 min route that includes 5–10 min under continuous tree
  canopy (Turia park in Valencia, Casa de Campo in Madrid).
- Query accepted HA distribution vs the 2026-04-18 baseline:

  ```sql
  SELECT
    COUNT(*) FILTER (WHERE decision = 'accept') AS accepts,
    ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY horizontal_accuracy)
       FILTER (WHERE decision = 'accept')::numeric, 1) AS ha_p50,
    ROUND(percentile_cont(0.9) WITHIN GROUP (ORDER BY horizontal_accuracy)
       FILTER (WHERE decision = 'accept')::numeric, 1) AS ha_p90,
    COUNT(*) FILTER (WHERE decision = 'accept'
                       AND horizontal_accuracy > 25) AS over_ceiling
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<start>' AND '<end>';
  ```

- Expected: `over_ceiling = 0` (the new gate rejects HA > 25 m
  unconditionally), `accepts` count is lower than the pre-1.2.9
  baseline by roughly the fraction of canopy time.
- iPhone 13 Pro Max: same query, `accepts` should be close to
  baseline (p90 = 14 m sits well under the new ceiling).

### 24. Pedestrian spike threshold catches multipath (1.2.9, S2)

Verifies the 250 m walking threshold catches what the old 750 m
missed. Harder to provoke deliberately — rely on post-hoc detection.

- After a session under canopy or in urban canyon, query for buffered
  fixes that would have slipped through the old threshold:

  ```sql
  SELECT fix_timestamp, decision, horizontal_accuracy, latitude, longitude
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND decision IN ('buffered', 'spikeReplaced')
     AND fix_timestamp > '<session_start>'
   ORDER BY fix_timestamp;
  ```

- Expected on a canopy-heavy iPhone 8 session: at least a handful of
  `buffered` rows where the raw jump was in the 250–750 m range.
  Zero on a clean iPhone 13 Pro Max session is fine and expected.
- If a `spikeReplaced` row appears alongside it, the buffer ran its
  full A→B→C cycle — ideal confirmation.

### 25. Automotive widens spike threshold on real trip (1.2.9, S3)

- On a car / bus / tram ride ≥ 20 min, confirm:

  ```sql
  SELECT fix_timestamp, decision, horizontal_accuracy
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<ride_start>' AND '<ride_end>'
     AND decision = 'buffered'
   ORDER BY fix_timestamp;
  ```

- Expected: very few or zero `buffered` rows. Automotive threshold
  (750 m) should easily accommodate any legitimate sample-delta on
  Spanish highways or Metrovalencia track.
- If many `buffered` rows show up during a real ride, either
  `MotionClassifier` isn't reaching `.automotive` in time, or Motion
  & Fitness permission is denied (surfaces as
  `TrackingImpairment.motionPermissionDenied` in the UI banner —
  first thing to check).

### 26. Stationary decisions now visible in diagnostics (1.2.9, S4)

- Sit still with the phone for ≥ 3 min after a walk (coffee stop,
  waiting at a bus shelter).
- Query:

  ```sql
  SELECT decision, COUNT(*)
    FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<stop_start>' AND '<stop_end>'
   GROUP BY decision
   ORDER BY COUNT(*) DESC;
  ```

- Expected: a mix of `accept` (during the first ~150 s as the
  window fills) and `accept:stationarySuppress` (once the detector
  declares stationary and suppresses further fixes). Before 1.2.9
  only `accept` rows existed and the post-150 s suppressions were
  invisible.
- The exact ratio depends on phone cadence but both tags should be
  non-zero.

### 27. No residual `poorResumeAccuracy` ever (1.2.9, S5)

- Walk a route with at least one multi-minute signal blackout
  (indoor shop, parking garage entry and exit).
- Query:

  ```sql
  SELECT COUNT(*) FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND decision = 'discard:poorResumeAccuracy'
     AND fix_timestamp > '<upgrade_time>';
  ```

- Expected: **0**. The gate is gone; a single `discard:poorAccuracy`
  at the 25 m ceiling is the only accuracy-based rejection that
  remains.
- Non-zero would indicate an old build is still uploading (check
  app footer), or the ENUM migration was incomplete.

**Out of scope for the 1.2.9 round.** Kalman smoother (intentionally
kept per the audit — it does real work on clean GNSS even if it can't
repair biased measurements), stationary detector, sync/backoff,
BGTaskScheduler, backend API, frontend visualization, Docker stack.
Scenarios #1–22 cover those.

## 1.2.10 Wi-Fi-only uploads regression plan

Field regression for the 1.2.10 sync-policy changes. All scenarios
assume the iPhone footer reads `v1.2.10 (15)`. Timing uses the foreground
30 s `Timer` — don't background the app while observing.

### 29. Cellular drains nothing (1.2.10)

Primary validation that no HTTP task is issued on cellular, and that the
unsynced counter survives without drift.

- On the iPhone: Settings → Wi-Fi → off. Cellular on.
- Launch the app. Walk ≥ 100 m so the counter ticks up past 10.
- Hold for ≥ 2 min.
- Expected: counter keeps going up, **never decrements**. Console.app
  (attached via Xcode, DEBUG build) shows `[sync] points: not on Wi-Fi,
  skipping` every 30 s; no `URLSession` task, no 15 s timeout, no
  retryable-error log. Battery Instruments shows a flat "Networking"
  row — not the pre-1.2.10 sawtooth pattern of 15 s timeouts.
- Turn Wi-Fi back on (same network as the Mac backend).
- Expected: within ≤ 30 s the counter drains. Console.app shows
  `[sync] Wi-Fi regained → backoff reset to base` (DEBUG only) and no
  futile waiting beyond one tick.

### 30. Personal hotspot blocked (1.2.10)

Verifies `isExpensive` gate. A paired peer's cellular must not be drained.

- Enable the iPhone's personal hotspot. Connect a Mac to the hotspot and
  confirm the Mac is online via LTE/5G routing.
- Walk ≥ 100 m with the iPhone.
- Expected: counter rises, never drains (hotspot connection has
  `usesInterfaceType(.wifi) = true` but `isExpensive = true`, so the
  predicate rejects).

### 31. Low Data Mode blocked (1.2.10)

Verifies `isConstrained` gate.

- Settings → Wi-Fi → (active network) → Low Data Mode = on.
- Walk ≥ 100 m.
- Expected: counter rises, never drains. Turn Low Data Mode off:
  counter drains within one tick.

### 32. Diagnostics flag default (1.2.10)

Verifies new installs don't write or upload `fix_diagnostics` rows.

- Fresh install or delete app + reinstall. Do **not** flip the flag.
- Walk ~5 min on Wi-Fi.
- Expected: `points` rows accumulate and upload normally. In Postgres:

  ```sql
  SELECT COUNT(*) FROM fix_diagnostics
   WHERE device_id = '<DEV>'
     AND fix_timestamp BETWEEN '<start>' AND '<end>';
  -- → 0
  ```

### 33. Diagnostics flag runtime override (1.2.10)

Verifies the UserDefaults override works without a rebuild.

- On the iPhone, via Xcode or SSH to a jailbroken device (not typical),
  or on a development Mac mirroring the device defaults:

  ```
  defaults write com.gpslogger.personal syncDiagnosticsEnabled -bool YES
  ```

- Kill + relaunch the app.
- Walk ~5 min on Wi-Fi.
- Expected: backend `fix_diagnostics` now grows (≈ 1 Hz = ~300 rows per
  5 min). Decisions include the full 1.2.9 tag vocabulary (`accept`,
  `accept:stationarySuppress`, `buffered`, `spikeReplaced`,
  `committedPending`, `discard:poorAccuracy`, etc.).
- Turn flag back off, relaunch. Expected: row count stops growing on
  the next tick.

## Inspecting fix_diagnostics after an anomaly

`fix_diagnostics` records every raw `CLLocation` that entered
`LocationTracker.didUpdateLocations` (fields: `horizontal_accuracy`,
`vertical_accuracy`, `altitude`, `speed`, `speed_accuracy`, `course`,
`course_accuracy`) together with the `LocationFilter` decision for that
fix — **when `Config.syncDiagnosticsEnabled` is `true`** (off by default
since 1.2.10, see the scenarios above for how to flip it on). Rows are
written to the device's local SQLite, uploaded by `SyncService` on the
same 30 s Wi-Fi sync cadence as `/points`, and deleted locally after a
successful 2xx. **The authoritative store is the backend Postgres
`fix_diagnostics` table** — the local SQLite copy is only a staging buffer
with a 3-day safety-net retention.

Workflow after a real-world anomaly:

```bash
# Enter the backend Postgres container and query the window of interest.
# 5434 on the host is mapped to 5432 in the container; inside the db
# container psql is free to connect locally.
docker exec -it gpslogger-db-1 psql -U postgres -d gpslogger
```

```sql
-- Paste inside psql. Replace the device_id and timestamps with yours.
SELECT fix_timestamp,
       horizontal_accuracy,
       vertical_accuracy,
       altitude,
       speed,
       speed_accuracy,
       course,
       decision
  FROM fix_diagnostics
 WHERE device_id = '<your-device-uuid>'
   AND fix_timestamp BETWEEN '2026-04-15T15:44:00Z'
                         AND '2026-04-15T15:53:00Z'
 ORDER BY fix_timestamp ASC;
```

Or one-shot from the host:

```bash
docker exec gpslogger-db-1 psql -U postgres -d gpslogger -c \
  "SELECT fix_timestamp, horizontal_accuracy, vertical_accuracy, speed, decision \
     FROM fix_diagnostics \
    WHERE device_id = '<your-device-uuid>' \
      AND fix_timestamp BETWEEN '2026-04-15T15:44:00Z' AND '2026-04-15T15:53:00Z' \
    ORDER BY fix_timestamp;"
```

### Signatures to classify an anomaly

| `speed` | `vertical_accuracy` | `horizontal_accuracy` during window | Likely source |
|---|---|---|---|
| `-1` | `-1` | 30–65 m, flat plateau | Wi-Fi / cell-tower fallback (network positioning). Filter should have marked rows `discard:nonGpsSource`. |
| `≥ 0` | `> 0` | stuck at 5–15 m while coordinates drift | CoreLocation sensor-fusion drift bug — filter can't catch this, needs a plateau detector. |
| `≥ 0` | `> 0` | growing with distance from real position | Regular GPS degradation — the 50 m `poorAccuracy` gate should have clipped the worst. |
| `≥ 0` | `> 0` | normal | Multipath / transient glitch — spike buffer should have handled it. |
| any | any | any, but `logged_at − fix_timestamp > 10 s` | Cached fix replay — `discard:staleDelivery` gate (1.2.2) should have rejected it. |
| `≥ 0` | `> 0` | 20–50 m, first fix after gap > 60 s and ≤ 120 s | Post-indoor multipath convergence — `discard:poorResumeAccuracy` gate (1.2.2) should have rejected it. |
| `≥ 0` | `> 0` | 20–50 m, first fix after gap > 120 s | **Expected behavior post-1.2.6**: the relaxed tier accepts these. If a long stretch of 20–50 m fixes is rejected instead, the gap-aware bounds in `Config` may have been retightened — review `resumeRelaxSeconds`. |
| `-1` | `> 0` | normal (5–30 m), first 1–3 fixes after a cold boot / airplane-mode toggle / first-ever install | GNSS cold start with Doppler lock still acquiring. The receiver has a valid 3D fix (positive `vertical_accuracy`) but has not yet computed velocity. The source gate correctly rejects these as `discard:nonGpsSource` — not a bug, but it explains why the trace starts 5–15 s later than the tap on "Start". |
| any | any | `logged_at` more than 10 s *ahead* of `fix_timestamp` (wall-clock jumped backward) | System clock skew (NTP correction, manual time change, DST edge). `discard:staleDelivery` (1.2.4 symmetric gate) rejects. |

**Slow cold-start diagnostic workflow.** If a user reports "the trace
took 15 s to appear after I tapped launch" — which is normal behavior,
not a bug — the pattern above is what you expect to see in
`fix_diagnostics`:

```sql
SELECT fix_timestamp, horizontal_accuracy, vertical_accuracy,
       speed, speed_accuracy, decision
  FROM fix_diagnostics
 WHERE device_id = '<your-device-uuid>'
   AND fix_timestamp BETWEEN '<launch-time>'::timestamptz
                         AND '<launch-time>'::timestamptz + INTERVAL '30 seconds'
 ORDER BY fix_timestamp ASC;
```

Expected: 1–3 rows with `speed = -1` and `decision =
'discard:nonGpsSource'`, followed by rows with `speed >= 0` and
`decision = 'accept'`. If *every* row in the first 60 s has `speed =
-1`, the device was indoors and CoreLocation never handed us a GNSS
fix — trace gap is a signal issue, not a filter issue.

If the bad rows show `decision = 'discard:nonGpsSource'` they never made it
into `points`; the fix is already doing its job and the anomaly should not
be visible on the map. If they show `decision = 'accept'` with one of the
other signatures, we need a different defense.

## Regressions to watch for

- **Counter drift**: if the in-memory counter ever disagrees with the DB row count,
  it's usually because an inc/dec was dispatched from a non-main thread or
  because the seed on launch was skipped. Always seed via `initialCount()` once,
  then mutate only from the main queue.
- **Timezones**: backend uses `TIMESTAMPTZ` and Docker containers run UTC.
  The iOS client serializes timestamps as full ISO 8601 with `Z`. Any local
  timezone conversion should happen only in the frontend display, never at the
  transport boundary.
- **Free Apple ID 7-day expiry**: the app will stop launching. Rerun from Xcode.
