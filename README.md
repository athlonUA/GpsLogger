# GpsLogger

Minimal end-to-end GPS tracking system.

> **Design rule:** collect raw location data with **zero interpretation**.
> No trip detection, no movement classification, no behavior analysis —
> just `collect → store → visualize`.

## Parts

| Component | Tech | Purpose |
|---|---|---|
| **iOS app** (`ios/`) | SwiftUI + CoreLocation + raw sqlite3 | record GPS points, store locally, sync in batches |
| **Backend** (`backend/`) | Node.js 20 + Express 4 + pg | accept batches, query by time range |
| **DB** | PostgreSQL 16 | single `points` table with `created_at` index |
| **Frontend** (`frontend/`) | Vite + React 18 + TypeScript + react-leaflet | visualize a route as a gradient polyline |
| **Docker** (`docker-compose.yml`) | docker-compose | one-command backend + DB bring-up |

## Data contract

All three tiers agree on a single shape.

### `POST /points`

Body: **raw JSON array** (not an envelope object):

```json
[
  { "latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00.000Z" },
  { "latitude": 37.7750, "longitude": -122.4180, "created_at": "2024-01-01T12:00:05.000Z" }
]
```

Rules:

- `latitude` ∈ `[-90, 90]`, finite number
- `longitude` ∈ `[-180, 180]`, finite number
- `created_at` is an ISO 8601 string in **UTC**
- batch size ≤ 1000 (iOS app uses ≤ 100)

Response:

```json
{ "inserted": 2 }
```

Errors:

```json
{ "error": "points[3].latitude: must be a finite number in [-90, 90]" }
```

### `GET /points?from=<ISO>&to=<ISO>`

Both params optional. Returns an array **sorted ASC by `created_at`**:

```json
[
  { "id": 1, "latitude": 37.7749, "longitude": -122.4194, "created_at": "2024-01-01T12:00:00.000Z" },
  ...
]
```

### Schema

```sql
CREATE TABLE points (
    id          SERIAL PRIMARY KEY,
    latitude    DOUBLE PRECISION NOT NULL,
    longitude   DOUBLE PRECISION NOT NULL,
    created_at  TIMESTAMPTZ      NOT NULL
);
CREATE INDEX idx_points_created_at ON points (created_at);
```

Note: spec says `TIMESTAMP`. We use `TIMESTAMPTZ` because it round-trips correctly
through `pg` regardless of container timezone — strictly more correct, same wire
format on input and output.

## Running it

### 1. Backend + DB

```bash
docker compose up --build
```

Wait for:

```
[migrate] applied 001_init.sql
[api] listening on :3000
```

Sanity check:

```bash
curl -fsS http://localhost:3000/health
# {"ok":true}
```

### 2. Frontend

```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:5173. The UI has a **From**/**To** datetime pair and a
**Visualize** button — no auto-refresh.

Override the backend URL via `frontend/.env`:

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

```
┌──────────────┐   HTTP batches    ┌───────────────┐      ┌──────────────┐
│  iOS app     │ ─────────────────▶│  Express API  │ ───▶ │ Postgres 16  │
│ (SwiftUI +   │  every 30s         │  /points POST │      │  points      │
│ CoreLocation │                    │  /points GET  │◀──── │              │
│ + SQLite)    │                    └───────────────┘      └──────────────┘
└──────────────┘                            ▲
                                            │ GET /points?from&to
                                            │
                                   ┌────────────────┐
                                   │  React app     │
                                   │ (Leaflet +     │
                                   │  gradient line)│
                                   └────────────────┘
```

### iOS — collection rules

- **Only** `CLLocationManager` drives point collection — the app uses **no timers
  for location**. Points are inserted exclusively in the
  `didUpdateLocations` callback.
- A `Timer` exists, but only inside `SyncService`, to schedule HTTP uploads.
- Two layers of distance filtering ensure no points land closer than 10 m:
  `CLLocationManager.distanceFilter = 10` and a defensive per-insert check.
- The unsynced counter lives in memory: seeded once at launch via
  `SELECT COUNT(*)`, then incremented/decremented only. No further count queries.

### Backend — minimalism

- Two routes + health endpoint. No auth, no envelopes, no extra layers.
- Parameterized multi-row `INSERT` for O(1) round-trips per batch.
- Range query is a single `SELECT … WHERE created_at BETWEEN` against the
  `created_at` index.
- Pure-function input validator with a dedicated unit-test suite.

### Frontend — visualization

- User-driven fetch only. **No auto-refresh, no clustering, no segmentation,
  no heatmap.**
- Downsamples to ≤ 4000 points before rendering (`ceil(total / 4000)` stride).
- Splits the downsampled polyline into 64 chunks to fake a gradient under
  Leaflet's single-color-per-polyline limitation.
- `fitBounds` on every successful fetch.

## Tests

```bash
# backend unit tests
cd backend && node --test test/
```

Full QA plan (smoke tests + manual E2E scenarios): see [`QA.md`](QA.md).

## Layout

```
GpsLogger/
├── README.md                this file
├── QA.md                    test plan
├── docker-compose.yml       backend + postgres
├── backend/
│   ├── Dockerfile
│   ├── package.json
│   ├── migrations/001_init.sql
│   ├── src/{index,db,validate}.js
│   ├── src/routes/points.js
│   └── test/validate.test.js
├── frontend/
│   ├── package.json
│   ├── vite.config.ts
│   ├── index.html
│   └── src/{main,App,Map,api,styles,vite-env.d}.{tsx,ts,css}
└── ios/
    ├── README.md            Xcode setup guide
    └── GpsLogger/
        ├── GpsLoggerApp.swift
        ├── AppContainer.swift
        ├── AppState.swift
        ├── ContentView.swift
        ├── LocationTracker.swift
        ├── SyncService.swift
        ├── Database.swift
        ├── Config.swift
        └── Info.plist
```
