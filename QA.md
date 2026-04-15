# QA — GpsLogger

Covers automated tests and manual end-to-end scenarios.

## Automated tests

### iOS LocationFilter unit tests

```
cd ios
xcodegen generate
xcodebuild test -project GpsLogger.xcodeproj -scheme GpsLoggerTests \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

Covers `LocationFilter` end-to-end — every gate in the filter pipeline:

- validity gate (negative `horizontalAccuracy` → discard `.invalidFix`)
- **source gate** (GPS-origin detection via `speed` and `verticalAccuracy`):
  rejects fixes whose `speed < 0` or `verticalAccuracy ≤ 0`, which is the
  documented sentinel for Wi-Fi / cell-tower fallback fixes that lack Doppler
  velocity and altitude. This is the load-bearing defense against the
  "park-canopy teleport" anomaly where CoreLocation falls back to Wi-Fi
  Positioning and a stale BSSID registration delivers a plausible-looking
  fix hundreds of meters to kilometers off the true position
- accuracy value gate (`horizontalAccuracy > 50 m` → discard `.poorAccuracy`)
- chronology gate (`Δt ≤ 0` → discard `.staleTimestamp`)
- implausible-speed gate (500 km/h ceiling)
- minimum-distance gate (`< 10 m` → discard `.tooClose`)
- spike buffer (A → B(far > 750 m) → C(near A) → drop B)
- regression: stationary GPS fix (speed = 0, valid vertical accuracy) must
  still be accepted — the source gate must not confuse a standing-still user
  with a network-derived fix
- regression: a dense burst of Wi-Fi-style fallback fixes leaves `lastAccepted`
  pinned to the last real GPS fix and never corrupts the spike buffer

### Backend validator unit tests

```
cd backend
node --test test/
```

Covers `validate.js` — the pure input-validation layer that sits in front of every
DB write and read:

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
- range: requires `device_id`, parses optional `from`/`to`, rejects invalid dates, rejects `from > to`

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
# → {"inserted":2}

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
```

## Manual E2E scenarios

All scenarios assume:

- `docker-compose up` is running on the Mac
- iPhone has the app installed via Xcode, backend URL set to Mac's LAN IP
- iPhone and Mac share the same Wi-Fi

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

## Extracting the fix_diagnostics table from a device

`fix_diagnostics` is a debug table in `Documents/gpslogger.sqlite` that
records every raw `CLLocation` (fields: `horizontal_accuracy`,
`vertical_accuracy`, `altitude`, `speed`, `speed_accuracy`, `course`,
`course_accuracy`) together with the `LocationFilter` decision for that fix.
Retention: 14 days, pruned on every launch. Not uploaded to the backend.

To inspect it after a real-world anomaly:

1. **Xcode → Window → Devices and Simulators** (or `⇧⌘2`).
2. Select your iPhone in the left sidebar.
3. In the **Installed Apps** list, select `GpsLogger`, click the gear icon,
   pick **Download Container…**, and save the `.xcappdata` bundle locally.
4. Right-click the bundle → **Show Package Contents**, then navigate to
   `AppData/Documents/gpslogger.sqlite`.
5. Open with any SQLite tool:
   ```bash
   sqlite3 /path/to/gpslogger.sqlite
   .mode column
   .headers on
   SELECT logged_at, horizontal_accuracy, vertical_accuracy, speed, decision
     FROM fix_diagnostics
     WHERE fix_timestamp BETWEEN '2026-04-15T15:45:00Z' AND '2026-04-15T15:52:00Z'
     ORDER BY fix_timestamp;
   ```

Signatures to look for when classifying an anomaly:

| `speed` | `vertical_accuracy` | `horizontal_accuracy` | Likely source |
|---|---|---|---|
| `-1` | `-1` | 30–65 m | Wi-Fi / cell-tower fallback (network positioning) |
| `≥ 0` | `> 0` | stuck at 5–15 m while coordinates drift | CoreLocation sensor-fusion drift bug |
| `≥ 0` | `> 0` | growing with distance from real position | Regular GPS degradation |
| `≥ 0` | `> 0` | normal | Multipath / transient glitch |

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
