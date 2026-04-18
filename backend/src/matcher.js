// Map-matching client for the OSRM `/match` endpoint.
//
// Takes a time-sorted array of raw `points` rows and returns a parallel
// array of snapped points where OSRM found a plausible route, falling
// back to the raw coordinate whenever a sample has no confident match.
// The orchestration deliberately never hard-errors: a downed OSRM
// service, a batch with no match, or an unreachable network all collapse
// into "return raw coordinates", so the frontend can render *something*
// for every requested trip.
//
// Pipeline:
//   1. `splitByTimeGap` — break the input into trip segments wherever the
//      gap to the previous point exceeds `TRIP_GAP_SECONDS` (default 5 min,
//      matching the frontend's existing trip-grouping rule). OSRM's HMM
//      assumes a continuous trace; a multi-hour lunch break inside a
//      single request would confuse the motion model.
//   2. `chunkBySize` — within each segment, split further into ≤ BATCH_SIZE
//      requests with a 1-point overlap so the next chunk has an anchor for
//      the HMM initial state. OSRM's internal ceiling is raised to 1000 in
//      the entrypoint, but 100-point batches are the sweet spot for the
//      HMM's computational cost at typical phone-trace densities.
//   3. `buildMatchUrl` + fetch — hit `/match/v1/{profile}/{coords}` with
//      per-point radiuses and timestamps. Radius is Apple's HA ceiling (we
//      use a conservative 25 m default because the `points` table does not
//      carry per-row horizontalAccuracy — adding that is a future
//      optimization via a JOIN on `fix_diagnostics`).
//   4. `parseMatchResponse` — read back snapped coordinates; any `null`
//      tracepoint (OSRM rejected it as an outlier) keeps the raw coord
//      so the rendered polyline is continuous regardless.

export const TRIP_GAP_SECONDS = 300;
export const BATCH_SIZE = 100;
export const DEFAULT_RADIUS_METERS = 25;
/** Per-chunk HTTP timeout. Large traces × HMM cost can stretch, but 15 s
 *  covers any realistic batch on a LAN-local OSRM instance and keeps a
 *  misbehaving service from holding the request line. */
export const OSRM_TIMEOUT_MS = 15_000;

/**
 * Split a time-sorted `points` array into sub-arrays whenever the gap
 * between consecutive rows exceeds `gapSeconds`.
 */
export function splitByTimeGap(points, gapSeconds = TRIP_GAP_SECONDS) {
  if (!Array.isArray(points) || points.length === 0) return [];
  const segments = [];
  let current = [points[0]];
  for (let i = 1; i < points.length; i++) {
    const prev = new Date(points[i - 1].created_at).getTime();
    const now = new Date(points[i].created_at).getTime();
    if ((now - prev) / 1000 > gapSeconds) {
      segments.push(current);
      current = [points[i]];
    } else {
      current.push(points[i]);
    }
  }
  segments.push(current);
  return segments;
}

/**
 * Chunk a segment into arrays of at most `size` points, overlapping by
 * one sample so each batch (after the first) has a seed for OSRM's HMM.
 * Single-point remainders are dropped because `/match` needs ≥ 2 inputs.
 */
export function chunkBySize(segment, size = BATCH_SIZE) {
  if (segment.length <= size) return [segment];
  const step = size - 1; // overlap of 1
  const chunks = [];
  for (let i = 0; i < segment.length; i += step) {
    const slice = segment.slice(i, i + size);
    if (slice.length >= 2) chunks.push(slice);
    if (i + size >= segment.length) break;
  }
  return chunks;
}

/**
 * Build the `/match` URL for a single batch. OSRM coordinates are
 * `lon,lat` (a common footgun) and the query string carries one radius
 * and one timestamp per waypoint so the HMM can weigh temporal ordering
 * against spatial distance.
 */
export function buildMatchUrl(
  baseUrl,
  batch,
  { profile = 'foot', radius = DEFAULT_RADIUS_METERS } = {}
) {
  const coords = batch.map((p) => `${p.longitude},${p.latitude}`).join(';');
  const radiuses = batch.map(() => radius).join(';');
  const timestamps = batch
    .map((p) => Math.floor(new Date(p.created_at).getTime() / 1000))
    .join(';');
  // OSRM expects semicolons in `radiuses` / `timestamps` literally, not
  // URL-encoded. `URLSearchParams` percent-encodes `;` to `%3B`, which
  // OSRM rejects, so we hand-build the query string instead. All values
  // are numeric (and therefore URL-safe) so skipping `encodeURIComponent`
  // is correct, not lazy.
  const qs = [
    'geometries=geojson',
    'overview=full',
    `radiuses=${radiuses}`,
    `timestamps=${timestamps}`,
    'annotations=false',
  ].join('&');
  return `${baseUrl.replace(/\/+$/, '')}/match/v1/${profile}/${coords}?${qs}`;
}

/**
 * Parse an OSRM `/match` JSON response into a parallel array of
 * snapped-or-raw points. Returns an array of the same length as `batch`;
 * unmatched entries keep the raw lat/lon so the caller never has to
 * reason about sparse arrays.
 */
export function parseMatchResponse(json, batch) {
  if (!json || json.code !== 'Ok' || !Array.isArray(json.tracepoints)) {
    return batch.map(toRawEcho);
  }
  return batch.map((p, i) => {
    const tp = json.tracepoints[i];
    if (!tp || !Array.isArray(tp.location) || tp.location.length !== 2) {
      return toRawEcho(p);
    }
    // OSRM `location` is `[longitude, latitude]`.
    return {
      latitude: tp.location[1],
      longitude: tp.location[0],
      matched: true,
    };
  });
}

/**
 * Orchestrate the full flow. Returns
 *   `{ points: [...], matchedCount, totalCount }`
 * where `points` is in input order, one entry per input row, carrying
 * either the snapped coord (`matched: true`) or the raw coord
 * (`matched: false`). Never throws — an unreachable OSRM or malformed
 * response degrades into all-raw so the UI always has something to draw.
 *
 * `fetchImpl` is injectable so tests can exercise success / NoMatch /
 * network-failure paths without a live OSRM container.
 */
export async function matchTrace(osrmUrl, points, options = {}) {
  const {
    profile = 'foot',
    radius = DEFAULT_RADIUS_METERS,
    fetchImpl = fetch,
    log = null,
    timeoutMs = OSRM_TIMEOUT_MS,
  } = options;

  if (!points || points.length === 0) {
    return { points: [], matchedCount: 0, totalCount: 0 };
  }
  // Feature disabled (OSRM_URL unset): echo raw, zero matches. The
  // route handler surfaces this as HTTP 503 so the UI can disable the
  // toggle and stop asking; inside `matchTrace` itself we just behave
  // like a perfectly silent matcher.
  if (!osrmUrl) {
    return {
      points: points.map(toRawEcho),
      matchedCount: 0,
      totalCount: points.length,
    };
  }

  const out = [];
  let matchedCount = 0;

  for (const segment of splitByTimeGap(points)) {
    if (segment.length < 2) {
      // Single-fix trip — `/match` needs ≥ 2 points. Emit raw.
      for (const p of segment) out.push(toRawEcho(p));
      continue;
    }

    const chunks = chunkBySize(segment);
    for (let ci = 0; ci < chunks.length; ci++) {
      const chunk = chunks[ci];
      const url = buildMatchUrl(osrmUrl, chunk, { profile, radius });
      let matchedChunk;
      try {
        const res = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
        const json = res.ok ? await res.json() : null;
        matchedChunk = parseMatchResponse(json, chunk);
      } catch (err) {
        log?.warn?.({ err, chunkSize: chunk.length }, 'osrm match failed — falling back to raw');
        matchedChunk = chunk.map(toRawEcho);
      }

      // Chunks overlap by 1 point; skip the seam entry on every chunk
      // after the first so we don't emit duplicate rows.
      const skipFirst = ci > 0;
      for (let i = skipFirst ? 1 : 0; i < matchedChunk.length; i++) {
        if (matchedChunk[i].matched) matchedCount++;
        out.push({
          id: chunk[i].id,
          created_at: chunk[i].created_at,
          latitude: matchedChunk[i].latitude,
          longitude: matchedChunk[i].longitude,
          matched: matchedChunk[i].matched,
        });
      }
    }
  }

  return { points: out, matchedCount, totalCount: out.length };
}

function toRawEcho(p) {
  return {
    id: p.id,
    created_at: p.created_at,
    latitude: p.latitude,
    longitude: p.longitude,
    matched: false,
  };
}
