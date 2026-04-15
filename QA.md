# QA — GpsLogger

Covers automated tests and manual end-to-end scenarios.

## Automated tests

### iOS unit tests (41 cases across 4 test files)

```
cd ios
xcodegen generate
xcodebuild test -project GpsLogger.xcodeproj -scheme GpsLoggerTests \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

**`LocationFilterTests` (15 cases)** — every gate in the filter
pipeline end-to-end:

- validity gate (negative `horizontalAccuracy` → discard `.invalidFix`)
- **source gate** (GPS-origin detection via `speed` and `verticalAccuracy`):
  rejects fixes whose `speed < 0` or `verticalAccuracy ≤ 0`, which is the
  documented sentinel for Wi-Fi / cell-tower fallback fixes that lack Doppler
  velocity and altitude. Load-bearing defense against the "park-canopy
  teleport" anomaly.
- source gate runs before the accuracy value gate (so a pristine
  `horizontalAccuracy = 5 m` but `speed = -1` fix is still rejected)
- accuracy value gate (`horizontalAccuracy > 50 m` → discard `.poorAccuracy`)
- chronology gate (`Δt ≤ 0` → discard `.staleTimestamp`)
- implausible-speed gate (500 km/h ceiling)
- minimum-distance gate (`< 10 m` → discard `.tooClose`)
- spike buffer (A → B(far > 750 m) → C(near A) → drop B)
- **pending timeout** (1.2.1): a buffered spike older than
  `Config.pendingTimeoutSeconds` is dropped silently before the next
  fix is evaluated, so an app-backgrounding event cannot leave stale
  spike state across sessions
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

**`StationaryDetectorTests` (9 cases)** — Phase-A/B state machine
plus the 1.2.1 clock-skew guard:

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
- `reset()` clears both candidate and stationaryCenter

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

- `docker-compose up --build` has run on the Mac (migrations 001–004 applied)
- iPhone has the app installed with `API_BASE_URL` in
  `ios/GpsLogger.xcconfig` pointing to the Mac's current LAN IP
- iPhone and Mac share the same Wi-Fi network
- Location permission is **Always**; Motion & Fitness permission is
  allowed (both prompts appear on first launch)

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

## Inspecting fix_diagnostics after an anomaly

`fix_diagnostics` records every raw `CLLocation` that entered
`LocationTracker.didUpdateLocations` (fields: `horizontal_accuracy`,
`vertical_accuracy`, `altitude`, `speed`, `speed_accuracy`, `course`,
`course_accuracy`) together with the `LocationFilter` decision for that
fix. Rows are written to the device's local SQLite, uploaded by
`SyncService` on the same 30 s cadence as `/points`, and deleted locally
after a successful 2xx. **The authoritative store is the backend Postgres
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
