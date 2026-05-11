export interface Point {
  id: number;
  latitude: number;
  longitude: number;
  created_at: string;
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
  /// True when the server returned an evenly-spaced sample of the full
  /// route rather than every fix. The route shape is preserved at lower
  /// fidelity; narrow the time range to recover full detail.
  sampled: boolean;
  /// Total number of fixes the server has stored for the requested range,
  /// regardless of whether `data` was downsampled.
  total: number;
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
