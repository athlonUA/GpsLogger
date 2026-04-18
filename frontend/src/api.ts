export interface Point {
  id: number;
  latitude: number;
  longitude: number;
  created_at: string;
  /** True when the point was snapped to the OSM graph by the backend's
   *  map-matching pass. Absent on the raw `/points` response. */
  matched?: boolean;
}

// API base URL. Accepts either an absolute origin ("http://localhost:3000")
// or a same-origin prefix ("/api"). The trailing slash is normalized away
// so we can always concatenate "/points" cleanly.
//
// - `npm run dev` on the host → falls back to http://localhost:3000 where the
//   dockerized backend is exposed.
// - `docker compose up` → Dockerfile sets VITE_API_URL=/api, so requests hit
//   the frontend container's own nginx, which proxies to the backend service.
const BASE = (import.meta.env.VITE_API_URL ?? 'http://localhost:3000').replace(/\/+$/, '');

export interface FetchResult {
  data: Point[];
  truncated: boolean;
  /** Populated only by `fetchMatchedPoints`. Number of rows the backend
   *  could snap to the OSM graph; the rest are echoed with raw coords. */
  matched_count?: number;
  /** Populated only by `fetchMatchedPoints`. Equal to `data.length` on
   *  success; included explicitly so the UI can compute the snap ratio
   *  without depending on the array length invariant. */
  total_count?: number;
}

/** Thrown when the backend reports that map-matching is not configured on
 *  the server side (HTTP 503 `map_matching_disabled`). Callers can check
 *  `err instanceof MatchingDisabledError` to silently fall back to raw. */
export class MatchingDisabledError extends Error {
  constructor() {
    super('map matching is not enabled on the backend');
    this.name = 'MatchingDisabledError';
  }
}

export async function fetchPoints(
  deviceId: string,
  from: Date,
  to: Date,
  signal?: AbortSignal,
): Promise<FetchResult> {
  const qs = new URLSearchParams({
    device_id: deviceId,
    from: from.toISOString(),
    to: to.toISOString(),
  });
  const res = await fetch(`${BASE}/points?${qs.toString()}`, { signal });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`GET /points failed: ${res.status} ${body}`);
  }
  return res.json();
}

/** Fetch the same time-range as `fetchPoints`, but with each row snapped
 *  to the OSM graph via the backend's OSRM matcher. Individual rows that
 *  OSRM could not match carry the raw coords with `matched: false`, so
 *  the rendered polyline is always continuous. Throws
 *  `MatchingDisabledError` when the backend reports 503 (`OSRM_URL`
 *  unset) so the caller can degrade the UI intelligently. */
export async function fetchMatchedPoints(
  deviceId: string,
  from: Date,
  to: Date,
  signal?: AbortSignal,
): Promise<FetchResult> {
  const qs = new URLSearchParams({
    device_id: deviceId,
    from: from.toISOString(),
    to: to.toISOString(),
  });
  const res = await fetch(`${BASE}/points/matched?${qs.toString()}`, { signal });
  if (res.status === 503) {
    throw new MatchingDisabledError();
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`GET /points/matched failed: ${res.status} ${body}`);
  }
  return res.json();
}
