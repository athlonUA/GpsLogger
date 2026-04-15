# GpsLogger

Minimal end-to-end GPS tracking system.

> **Design rule:** collect raw location data with **zero interpretation**.
> No trip detection, no movement classification, no behavior analysis —
> just `collect → store → visualize`.

## Parts

| Component | Tech | Purpose |
|---|---|---|
| **iOS app** (`ios/`) | SwiftUI + CoreLocation + raw sqlite3 | record GPS points, store locally, sync in batches; second channel uploads raw CLLocation diagnostics for post-hoc anomaly analysis |
| **Backend** (`backend/`) | Node.js 20 + Express 4 + pg | accept point batches and diagnostic batches, query points by time range |
| **DB** | PostgreSQL 16 | two tables: `points` (the visible trace) and `fix_diagnostics` (raw CLLocation fields + filter decision, for debugging) |
| **Frontend** (`frontend/`) | Vite + React 18 + TypeScript + react-leaflet | visualize a route as a gradient polyline |
| **Docker** (`docker-compose.yml`) | docker-compose | one-command backend + DB bring-up |

## Data contract

All three tiers agree on a single shape.

### `POST /points`

Body: **raw JSON array** (not an envelope object):

```json
[
  { "latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00.000Z", "device_id": "B1F2…" },
  { "latitude": 37.7750, "longitude": -122.4180, "created_at": "2024-01-01T12:00:05.000Z", "device_id": "B1F2…" }
]
```

Rules:

- `latitude` ∈ `[-90, 90]`, finite number
- `longitude` ∈ `[-180, 180]`, finite number
- `created_at` is an ISO 8601 string in **UTC**
- `device_id` is a non-empty string ≤ 128 chars (stable per install, see iOS `DeviceIdentity`). The iOS app stamps it on the upload payload from a single cached source — it is **not** duplicated into every row of the local SQLite queue.
- batch size ≤ 1000 (iOS app uses ≤ 100)

Response:

```json
{ "inserted": 2 }
```

Errors:

```json
{ "error": "points[3].latitude: must be a finite number in [-90, 90]" }
```

### `POST /diagnostics`

Debug/observability channel. Every raw `CLLocation` that enters the iOS
tracker pipeline is uploaded here together with the `LocationFilter`
verdict, for post-hoc classification of GPS anomalies (GNSS vs Wi-Fi /
cell-tower fallback vs sensor-fusion drift). Never read by the main
frontend — queried directly via psql after an incident. See
[`QA.md`](QA.md) for the extraction workflow.

Body: raw JSON array, same envelope shape as `/points`:

```json
[
  {
    "logged_at":         "2026-04-15T17:45:00.000Z",
    "fix_timestamp":     "2026-04-15T17:45:00.000Z",
    "latitude":          39.46975,
    "longitude":         -0.37739,
    "horizontal_accuracy": 8.2,
    "vertical_accuracy":   4.5,
    "altitude":           15.3,
    "speed":               1.3,
    "speed_accuracy":      0.4,
    "course":             92.0,
    "course_accuracy":     5.0,
    "decision":           "accept",
    "device_id":          "B1F2…"
  }
]
```

Rules:

- `latitude` / `longitude` same ranges as `/points`.
- `logged_at` is the wall-clock moment the iOS tracker captured the fix;
  `fix_timestamp` is `CLLocation.timestamp`. Both are ISO 8601 UTC.
- All seven raw CLLocation numeric fields (`horizontal_accuracy`,
  `vertical_accuracy`, `altitude`, `speed`, `speed_accuracy`, `course`,
  `course_accuracy`) must be finite numbers. **Negative values are
  preserved** — they are Apple's documented sentinels for "no data" and
  are the load-bearing signal for classifying network-origin fixes.
- `decision` is the `LocationFilter` verdict tag (e.g. `accept`,
  `discard:nonGpsSource`, `discard:poorAccuracy`, `spikeReplaced`,
  `buffered`), non-empty string ≤ 64 chars.
- `device_id` same rules as `/points`.
- batch size ≤ 1000 (iOS app uses ≤ 100).

Response: `{ "inserted": N }`. No GET — reads go straight to Postgres.

### `GET /points?device_id=<id>&from=<ISO>&to=<ISO>`

`device_id` is **required** — the endpoint is always scoped to one device so an
unauthenticated caller cannot enumerate the full dataset. `from` and `to` are
optional. Returns an array **sorted ASC by `created_at`**:

```json
[
  { "id": 1, "latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00.000Z" },
  ...
]
```

### Schema

```sql
-- 001_init.sql
CREATE TABLE points (
    id          SERIAL PRIMARY KEY,
    latitude    DOUBLE PRECISION NOT NULL,
    longitude   DOUBLE PRECISION NOT NULL,
    created_at  TIMESTAMPTZ      NOT NULL
);
CREATE INDEX idx_points_created_at ON points (created_at);

-- 002_device_id.sql
ALTER TABLE points
    ADD COLUMN IF NOT EXISTS device_id TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_points_device_id_created_at
    ON points (device_id, created_at);

-- 003_fix_diagnostics.sql
CREATE TABLE fix_diagnostics (
    id                  SERIAL PRIMARY KEY,
    logged_at           TIMESTAMPTZ      NOT NULL,
    fix_timestamp       TIMESTAMPTZ      NOT NULL,
    latitude            DOUBLE PRECISION NOT NULL,
    longitude           DOUBLE PRECISION NOT NULL,
    horizontal_accuracy DOUBLE PRECISION NOT NULL,
    vertical_accuracy   DOUBLE PRECISION NOT NULL,
    altitude            DOUBLE PRECISION NOT NULL,
    speed               DOUBLE PRECISION NOT NULL,
    speed_accuracy      DOUBLE PRECISION NOT NULL,
    course              DOUBLE PRECISION NOT NULL,
    course_accuracy     DOUBLE PRECISION NOT NULL,
    decision            TEXT             NOT NULL,
    device_id           TEXT             NOT NULL
);
CREATE INDEX idx_fix_diagnostics_device_fix_timestamp
    ON fix_diagnostics (device_id, fix_timestamp);
```

Notes:
- `TIMESTAMPTZ` (not `TIMESTAMP`) so values round-trip correctly through `pg`
  regardless of container timezone.
- The composite `(device_id, created_at)` index covers the primary read
  pattern for points: `WHERE device_id = ? AND created_at BETWEEN ? AND ? ORDER BY created_at ASC`.
- The `(device_id, fix_timestamp)` index on `fix_diagnostics` covers the
  incident-investigation read: `WHERE device_id = ? AND fix_timestamp
  BETWEEN ? AND ? ORDER BY fix_timestamp`.
- `device_id` on `points` ships with `DEFAULT ''` so the `002` migration is
  non-blocking on a populated table; new rows must supply a non-empty value
  (enforced at the API layer).
- `fix_diagnostics` has no default on `device_id` because the iOS client
  always supplies it. Raw CLLocation columns are `DOUBLE PRECISION NOT NULL`
  without range constraints — negative values are Apple's sentinels for
  "no data" and are exactly what we need to preserve.

## Running it

### 1. Full stack via Docker Compose (recommended)

```bash
docker compose up --build
```

Brings up four services:

| Service | Host port | Purpose |
|---|---|---|
| **db** | `5434` (→ container `5432`) | Postgres 16, data in the `db` named volume |
| **db-backup** | — | Sidecar that runs `pg_dump -Fc` into the `db-backup` named volume once every 24 h with 7-day retention (`find -mtime +7 -delete`). `tmpfs` mounted over `/var/lib/postgresql/data` to avoid Docker creating an anonymous volume for the postgres image's declared VOLUME |
| **backend** | `3000` | Express API |
| **frontend** | `3001` | nginx serving the built SPA + `/api/*` reverse proxy to `backend:3000` |

Wait for:

```
[migrate] applied 001_init.sql
[api] listening on :3000
```

Sanity checks:

```bash
curl -fsS http://localhost:3000/health            # backend direct  → {"ok":true}
curl -fsS http://localhost:3001/                  # frontend index  → HTML
curl -fsS 'http://localhost:3001/api/points?device_id=demo&from=2000-01-01T00:00:00Z&to=2100-01-01T00:00:00Z'
#                                                  # frontend → nginx → backend → []
```

Then open **http://localhost:3001** in your browser. The UI has a **Device ID**
field (persisted in `localStorage`), a **From**/**To** datetime pair, a
**Visualize** button, and a **Logout** button that clears the stored device ID
and resets the view. No auto-refresh.

### 2. Frontend in dev mode (optional)

For hot-reload while working on the frontend, run the Vite dev server directly
against the dockerized backend:

```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:5173. The dev server defaults to `http://localhost:3000`
for the API; override via `frontend/.env` if needed:

```
VITE_API_URL=http://localhost:3000
```

### 3. iOS app

See [`ios/README.md`](ios/README.md) for full Xcode setup steps (project creation,
Info.plist keys, background-mode capability, free Apple ID signing).

Short version:

1. Create an iOS **App** project in Xcode named `GpsLogger`.
2. Drag all files from `ios/GpsLogger/` into the project target.
3. Add `NSLocationAlwaysAndWhenInUseUsageDescription`,
   `NSLocationWhenInUseUsageDescription`, and
   `NSAppTransportSecurity → NSAllowsArbitraryLoads = YES` to Info.
4. Enable **Background Modes → Location updates**.
5. Edit `Config.swift` and set `apiBaseURL` to your Mac's LAN IP.
6. Sign with your personal team, run on device, trust the dev profile.

## Architecture summary

```mermaid
flowchart LR
    iOS(["iOS app<br/>SwiftUI · CoreLocation · sqlite3"])
    browser(["Browser<br/>localhost:3001"])

    subgraph compose["docker-compose stack"]
        direction LR
        nginx["nginx<br/>frontend container"]
        backend["Express API<br/>POST /points<br/>GET /points<br/>POST /diagnostics"]
        db[("Postgres 16<br/>points<br/>fix_diagnostics")]
        dbbackup["db-backup<br/>pg_dump -Fc daily<br/>7-day retention"]
    end

    iOS -->|HTTP batches every 30s<br/>(points + diagnostics)| backend
    browser -->|static SPA request| nginx
    nginx -->|built files| browser
    browser -->|"GET /api/*"| nginx
    nginx -->|"reverse proxy /api/*"| backend
    backend --> db
    db --> backend
    dbbackup -->|nightly dump| db
```

### iOS — collection rules

- **Always-on tracker.** There is no Start/Stop button — `LocationTracker`
  starts in `AppContainer.init` and runs for the lifetime of the app. The UI
  shows a pulsing green dot when active and an unsynced-points counter.
- **Only** `CLLocationManager` drives point collection — the app uses **no
  timers for location**. Points are inserted exclusively in the
  `didUpdateLocations` callback. A `Timer` exists, but only inside
  `SyncService`, to schedule HTTP uploads.
- **Pedestrian `activityType`.** `manager.activityType = .fitness` — semantic
  match for a walking/running tracker, avoids biasing CoreLocation's fusion
  engine toward vehicle motion models and road-snapping in degraded-signal
  environments.
- **Distance filter (first gate).** Two layers ensure no points land closer
  than 10 m: `CLLocationManager.distanceFilter = 10` and a defensive
  per-insert check.
- **`LocationFilter` (second gate, GPS noise).** Rules applied in order:
  1. Validity — `horizontalAccuracy ≥ 0`.
  2. **Source discrimination** — `speed ≥ 0` AND `verticalAccuracy > 0`.
     GNSS fixes populate both (Doppler velocity + 3D solution); Wi-Fi /
     cell-tower fallback fixes leave them at the documented sentinel
     negatives because network positioning has neither velocity nor
     altitude. This is the load-bearing defense against the "park-canopy
     teleport" anomaly where CoreLocation falls back to Wi-Fi Positioning
     and a stale BSSID registration delivers a plausible-looking fix
     hundreds of meters to kilometers off the true position. Accuracy
     gating alone cannot catch it.
  3. Accuracy value — drops fixes with `horizontalAccuracy > 50 m`.
  4. Chronology — `Δt > 0` vs. the last accepted fix (rejects replayed /
     cached fixes).
  5. Speed ceiling — rejects implied speeds > 500 km/h (teleport-class
     glitches only; every real surface transport mode passes).
  6. Spike buffer — a fix > 750 m from the last accepted point is held one
     tick. If the next fix returns within 100 m of the last accepted point,
     the buffered point is confirmed as a spike and dropped
     (A → B(far) → C(near A)).
  7. Minimum distance — ≥ 10 m from the last accepted fix.
- **`StationaryDetector` (third gate, jitter clusters).** After accepted
  fixes stay within 20 m of a candidate anchor for 150 s, the user is
  declared stationary and subsequent fixes are dropped until one lands more
  than 30 m from the cluster center (10 m of hysteresis). Coordinates are
  never smoothed or averaged — only accept/suppress decisions are made, and
  `LocationFilter.lastAccepted` keeps advancing so the spike/speed gates
  stay sane across long stationary windows.
- **Diagnostic channel.** Every raw `CLLocation` that enters
  `didUpdateLocations` — *before* the filter, not just accepted ones — is
  written to a local `fix_diagnostics` table with the filter verdict, then
  uploaded on the same 30 s sync tick to `POST /diagnostics`. The local
  copy is deleted on successful 2xx and a 3-day retention window covers
  backend outages. Used for post-hoc anomaly classification; the
  authoritative store is the backend Postgres table. See
  [`QA.md`](QA.md) for the query workflow.
- **Persistent device identity.** `DeviceIdentity` mints a UUID on first
  launch and stores it in the Keychain (UserDefaults fallback), so the
  same ID survives reinstalls. The ID is owned by `SyncService` and
  stamped on every upload payload from a single cached source — it is
  **not** written into individual rows of the local SQLite. Shown in the
  UI with a copy button.
- **Unsynced counter** lives in memory: seeded once at launch via
  `SELECT COUNT(*)`, then incremented/decremented only. No further count queries.

### Backend — minimalism

- Three routes + health endpoint: `POST /points`, `GET /points`,
  `POST /diagnostics`. No auth, no envelopes, no extra layers.
- Parameterized multi-row `INSERT` for O(1) round-trips per batch on both
  write endpoints.
- Range query is a single `SELECT … WHERE device_id = ? AND created_at
  BETWEEN` against the composite `(device_id, created_at)` index.
- No `GET /diagnostics` — diagnostics are read via psql / a DB browser
  against Postgres directly, not through the API, because they're a
  debug/observability channel and the frontend never displays them.
- Pure-function input validators with a dedicated unit-test suite
  (35 tests covering both `validateBatch` and `validateDiagnosticsBatch`).

### Frontend — visualization

- User-driven fetch only. **No auto-refresh, no clustering, no heatmap.**
- Splits the time-sorted points into groups whenever consecutive fixes are
  more than **5 minutes** apart, so unrelated trips (or power-off periods)
  never get bridged by a straight "teleport" line.
- Downsamples each group with a shared global budget of ≤ 4000 points total.
- Renders one halo + gradient polyline per group; gradient `t` stays global
  across groups so colors track progression across the full query window
  (blue early → red late).
- Each polyline is split into up to 64 colored chunks to fake a gradient
  under Leaflet's single-color-per-polyline limitation.
- `fitBounds` on every successful fetch.

## Tests

```bash
# backend unit tests (35 cases: validateBatch + validateDiagnosticsBatch + validateRange)
cd backend && node --test test/

# iOS unit tests (LocationFilter + Database drain cycle, 20 cases)
cd ios && xcodegen generate && xcodebuild test \
    -project GpsLogger.xcodeproj \
    -scheme GpsLoggerTests \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

Full QA plan (smoke tests + manual E2E scenarios + `fix_diagnostics`
query workflow after an anomaly): see [`QA.md`](QA.md).

## Layout

```
GpsLogger/
├── README.md                this file
├── QA.md                    test plan + fix_diagnostics query workflow
├── docker-compose.yml       db + db-backup + backend + frontend
├── backend/
│   ├── Dockerfile
│   ├── package.json
│   ├── migrations/
│   │   ├── 001_init.sql
│   │   ├── 002_device_id.sql
│   │   └── 003_fix_diagnostics.sql
│   ├── src/{index,db,validate}.js
│   ├── src/routes/{points,diagnostics}.js
│   └── test/validate.test.js
├── frontend/
│   ├── Dockerfile           multi-stage: Node build → nginx serve
│   ├── nginx.conf           static files + /api/* proxy to backend
│   ├── .dockerignore
│   ├── package.json
│   ├── vite.config.ts
│   ├── index.html
│   └── src/{main,App,Map,api,styles,vite-env.d}.{tsx,ts,css}
└── ios/
    ├── README.md                     Xcode setup guide
    ├── project.yml                   xcodegen spec (main + test target)
    ├── GpsLogger.xcconfig.example    template for local signing config
    ├── GpsLogger/
    │   ├── GpsLoggerApp.swift
    │   ├── AppContainer.swift
    │   ├── AppState.swift
    │   ├── ContentView.swift
    │   ├── LocationTracker.swift     delegate, pipeline, diagnostic logging
    │   ├── LocationFilter.swift      validity → source → accuracy → speed → spike
    │   ├── StationaryDetector.swift  jitter-cluster suppression
    │   ├── DeviceIdentity.swift      Keychain-backed UUID
    │   ├── SyncService.swift         points + diagnostics drains
    │   ├── Database.swift            points + fix_diagnostics store
    │   ├── Config.swift
    │   ├── GpsLogger.entitlements
    │   └── Info.plist
    └── GpsLoggerTests/
        ├── LocationFilterTests.swift 13 cases covering every filter gate
        └── DatabaseTests.swift       7 cases locking in the drain/retention invariants
```
