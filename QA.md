# QA — GpsLogger

Covers automated tests and manual end-to-end scenarios.

## Automated tests

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
- rejects `null` element
- range: accepts empty query, parses `from`/`to`, rejects invalid dates, rejects `from > to`

The DB layer itself is intentionally thin (parameterized inserts and a single
filter+sort select) and is exercised end-to-end via the smoke tests below.

### Smoke tests (after `docker-compose up`)

```bash
# health
curl -fsS http://localhost:3000/health

# insert
curl -fsS -X POST http://localhost:3000/points \
    -H 'Content-Type: application/json' \
    -d '[
      {"latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00Z"},
      {"latitude": 37.7750, "longitude": -122.4180, "created_at": "2024-01-01T12:00:05Z"}
    ]'
# → {"inserted":2}

# read back
curl -fsS 'http://localhost:3000/points?from=2024-01-01T00:00:00Z&to=2024-01-02T00:00:00Z'
# → [{"id":1,"latitude":37.7749, ...}, ...]

# bad request
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/points \
    -H 'Content-Type: application/json' \
    -d '[{"latitude":999,"longitude":0,"created_at":"2024-01-01T00:00:00Z"}]'
# → 400
```

## Manual E2E scenarios

All scenarios assume:

- `docker-compose up` is running on the Mac
- iPhone has the app installed via Xcode, backend URL set to Mac's LAN IP
- iPhone and Mac share the same Wi-Fi

### 1. Long drive (30+ min)

- Start app → press **Start** → begin driving.
- Expected: counter ticks up as ~10 m+ movements accumulate.
  Every ~30 s it drops by the batch size (up to 100) after a successful sync.
- Park, press **Stop**.
- On the web UI pick the drive's time range → click **Visualize**.
- Expected: a gradient polyline traces the actual route, blue at the start,
  red at the end. Route fits the viewport.

### 2. Stops / stationary periods

- Start app, sit stationary for 10 minutes, then walk around.
- Expected: while stationary, **no new points** accumulate (distance filter).
  The blue status bar stays visible; CoreLocation is active but the 10 m
  filter suppresses inserts.
- After walking, new points start flowing again.

### 3. No internet (offline queue)

- Start app, begin walking.
- Toggle the Mac backend off (`docker-compose stop backend`).
- Expected: counter keeps growing — upload fails silently, points stay in the
  local SQLite.
- Bring the backend back up (`docker-compose start backend`).
- Expected: counter drains within a few sync cycles as queued batches flush.

### 4. Background tracking

- Start app, press **Start**, lock the iPhone.
- Put it in a pocket and walk for a few minutes.
- Expected: blue location indicator remains visible on unlock. Counter has
  increased. Visualizing the range in the web UI shows the walked route.

### 5. App restart mid-session

- Start app, press **Start**, accumulate a few dozen points.
- Swipe-kill the app.
- Relaunch. Press **Start** again.
- Expected:
  - Counter reloads from the DB (seed via `initialCount()`) showing the
    still-unsynced points from before the kill.
  - Sync drains them whether or not you press Start again
    (`SyncService.start()` runs in `AppContainer.init`).
  - Collection resumes once Start is pressed again.

### 6. Backend restart (data durability)

- Insert points via the iPhone.
- `docker-compose restart db`
- Query `/points` again with the same range.
- Expected: all previously-inserted points are still there — Postgres volume
  `pgdata` persists across container restarts.

### 7. Frontend downsampling

- Insert 10k+ synthetic points via `curl`.
- Visualize the range.
- Expected: the polyline renders smoothly in <1 s. The status bar shows the
  full count ("10,247 points"). Internally, the map only renders ≤ 4000
  after downsampling, across 64 colored segments.

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
