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
curl -fsS 'http://localhost:3001/api/points?from=2000-01-01T00:00:00Z&to=2100-01-01T00:00:00Z'
#                                                  # frontend → nginx → backend → []
```

Then open **http://localhost:3001** in your browser. The UI has a **From**/**To**
datetime pair and a **Visualize** button — no auto-refresh.

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

```
┌──────────────┐    HTTP batches     ┌───────────────┐       ┌──────────────┐
│  iOS app     │ ───────────────────▶│  Express API  │ ────▶ │ Postgres 16  │
│ (SwiftUI +   │   every 30s          │  POST /points │       │    points    │
│ CoreLocation │                      │  GET  /points │◀───── │              │
│ + SQLite)    │                      └───────────────┘       └──────────────┘
└──────────────┘                              ▲
                                              │
                                    (service: backend:3000)
                                              │
                                      ┌───────┴────────┐
                                      │ nginx          │   /api/* → backend
                                      │ (frontend      │   /      → built SPA
                                      │  container)    │
                                      └───────┬────────┘
                                              │
                                              │ browser (localhost:3001)
                                              ▼
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
├── docker-compose.yml       db + db-backup + backend + frontend
├── backend/
│   ├── Dockerfile
│   ├── package.json
│   ├── migrations/001_init.sql
│   ├── src/{index,db,validate}.js
│   ├── src/routes/points.js
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
