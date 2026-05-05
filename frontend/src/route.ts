// Pure route-processing helpers used by `MapView`.
//
// Extracted into their own module so the rendering path (react-leaflet,
// which requires the DOM) and the logic path (segmentation, downsampling,
// distance math) can be tested in isolation. Importing this file never
// touches window / document, so it loads cleanly under `vitest`'s default
// Node environment.
//
// Keep this file free of JSX and free of any runtime dependency on
// react-leaflet or `leaflet` itself.

import type { Point } from './api';

/// Target point budget after downsampling. Not a visual cap — Leaflet can
/// render more — but an empirical sweet spot where interaction stays
/// responsive on modest hardware.
export const MAX_POINTS = 4000;

/// Break the route whenever consecutive fixes are more than this far apart
/// in time. Bridging such gaps would draw straight "teleport" lines
/// across unrelated locations (car trips, power-off periods, etc.).
export const GAP_MS = 5 * 60 * 1000;

/// Spacing between direction arrows along a rendered polyline, in meters.
export const ARROW_INTERVAL_METERS = 150;

/// Single uniform color for the whole route — indigo-violet between
/// pure blue (240°) and pure purple (285°). The map deliberately does
/// not vary color by time, speed, or inferred movement mode; a uniform
/// line reads cleanly at all zoom levels and avoids misleading the
/// reader with classifier output that cannot be fully trusted.
export const ROUTE_COLOR = 'hsl(260, 78%, 58%)';

// --------------------------------------------------------------------------
// Types
// --------------------------------------------------------------------------

export type Segment = { positions: [number, number][] };
export type Singleton = { point: Point };

export type RenderData = {
  /// Sampled groups (gap-split, then downsampled). Halo polylines and
  /// direction arrows iterate this shape directly.
  groups: Point[][];
  /// Flattened `groups` — convenience for click-snap and fit-bounds.
  sampled: Point[];
  /// Cumulative distance from route start, meters, aligned to `sampled`.
  /// Continuous across time-gap groups: the gap itself contributes zero
  /// (no polyline spans it), but the running total carries over so the
  /// last sampled point reports the true total traced distance.
  distancesMeters: number[];
  /// Cumulative elapsed time from the first point, seconds, aligned to
  /// `sampled`. Includes time-gap durations so "time from start" reflects
  /// the total wall-clock duration since the route began.
  timesFromStartSeconds: number[];
  /// One polyline per gap-group.
  segments: Segment[];
  /// Isolated fixes (groups of exactly one point after gap-splitting).
  singletons: Singleton[];
};

export type DirectionArrow = {
  latitude: number;
  longitude: number;
  /// Forward bearing in degrees (0° = north, 90° = east).
  bearing: number;
};

// --------------------------------------------------------------------------
// Geo primitives
// --------------------------------------------------------------------------

/// Haversine distance in meters between two geographic points.
export function haversineMeters(
  a: { latitude: number; longitude: number },
  b: { latitude: number; longitude: number },
): number {
  const R = 6_371_000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.latitude - a.latitude);
  const dLon = toRad(b.longitude - a.longitude);
  const la1 = toRad(a.latitude);
  const la2 = toRad(b.latitude);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(la1) * Math.cos(la2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/// Forward bearing from `a` to `b`, in degrees (0° north, 90° east).
function bearingDeg(
  a: { latitude: number; longitude: number },
  b: { latitude: number; longitude: number },
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const toDeg = (r: number) => (r * 180) / Math.PI;
  const la1 = toRad(a.latitude);
  const la2 = toRad(b.latitude);
  const dLon = toRad(b.longitude - a.longitude);
  const y = Math.sin(dLon) * Math.cos(la2);
  const x =
    Math.cos(la1) * Math.sin(la2) -
    Math.sin(la1) * Math.cos(la2) * Math.cos(dLon);
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

// --------------------------------------------------------------------------
// Gap-split
// --------------------------------------------------------------------------

/// Split a time-sorted list of points into groups, starting a new group
/// whenever the time delta to the previous point exceeds `GAP_MS`.
/// Non-finite deltas (parse failure) are treated as non-gaps so one
/// malformed row does not shatter the trace.
export function splitByTimeGaps(points: Point[]): Point[][] {
  if (points.length === 0) return [];
  const groups: Point[][] = [[points[0]]];
  let prevTime = new Date(points[0].created_at).getTime();
  for (let i = 1; i < points.length; i++) {
    const cur = points[i];
    const curTime = new Date(cur.created_at).getTime();
    const dt = curTime - prevTime;
    if (Number.isFinite(dt) && dt > GAP_MS) {
      groups.push([cur]);
    } else {
      groups[groups.length - 1].push(cur);
    }
    prevTime = curTime;
  }
  return groups;
}

// --------------------------------------------------------------------------
// Distances
// --------------------------------------------------------------------------

/// Per-segment lengths within a single group; returned length is
/// `group.length - 1`. Empty for groups shorter than 2.
export function segmentLengths(group: Point[]): number[] {
  const out: number[] = [];
  for (let i = 1; i < group.length; i++) {
    out.push(haversineMeters(group[i - 1], group[i]));
  }
  return out;
}

/// Cumulative distance per raw point, grouped. Continuous across time
/// gaps — the gap itself contributes nothing (no polyline spans it), but
/// the running total is preserved so "distance from the start of the
/// entire query window" remains well-defined across multiple sessions.
export function cumulativeDistances(groups: Point[][]): number[][] {
  const result: number[][] = [];
  let running = 0;
  for (const g of groups) {
    const cum: number[] = [running];
    for (let i = 1; i < g.length; i++) {
      running += haversineMeters(g[i - 1], g[i]);
      cum.push(running);
    }
    result.push(cum);
  }
  return result;
}

/// Cumulative elapsed time from the first point in the query window,
/// per raw point, grouped, in seconds. Continuous across time gaps —
/// the gap time is included so "time from start" reflects the total
/// duration since the route began, not just active movement.
export function cumulativeTimesSeconds(groups: Point[][]): number[][] {
  if (groups.length === 0 || groups[0].length === 0) return [];
  const t0 = new Date(groups[0][0].created_at).getTime();
  const result: number[][] = [];
  for (const g of groups) {
    const cum: number[] = [];
    for (const p of g) {
      cum.push((new Date(p.created_at).getTime() - t0) / 1000);
    }
    result.push(cum);
  }
  return result;
}

// --------------------------------------------------------------------------
// Downsampling
// --------------------------------------------------------------------------

/// Per-group indices into the original groups after downsampling. Useful
/// for callers that need to downsample parallel arrays (e.g. distance)
/// using the same index set, guaranteeing alignment.
export function downsampleIndices(groups: Point[][]): number[][] {
  const total = groups.reduce((s, g) => s + g.length, 0);
  if (total <= MAX_POINTS) {
    return groups.map((g) => g.map((_, i) => i));
  }
  return groups.map((g) => {
    if (g.length <= 2) return g.map((_, i) => i);
    const target = Math.max(2, Math.floor((g.length * MAX_POINTS) / total));
    const step = Math.ceil(g.length / target);
    const idx: number[] = [];
    for (let i = 0; i < g.length; i += step) idx.push(i);
    if (idx[idx.length - 1] !== g.length - 1) idx.push(g.length - 1);
    return idx;
  });
}

/// Downsample each group proportionally to its share of the global
/// point budget. Endpoints are preserved; under-budget input is returned
/// unchanged (same reference — upstream memoization relies on this).
export function downsampleGroups(groups: Point[][]): Point[][] {
  const total = groups.reduce((s, g) => s + g.length, 0);
  if (total <= MAX_POINTS) return groups;
  const idx = downsampleIndices(groups);
  return groups.map((g, i) =>
    idx[i].length === g.length ? g : idx[i].map((ii) => g[ii]),
  );
}

// --------------------------------------------------------------------------
// Render data — the MapView entry point
// --------------------------------------------------------------------------

/// End-to-end pipeline: raw points → gap-split → cumulative distance →
/// downsample. One Segment per group; the map renders every segment
/// in `ROUTE_COLOR`, and isolated-fix singletons the same.
export function buildRenderData(points: Point[]): RenderData {
  if (points.length === 0) {
    return {
      groups: [],
      sampled: [],
      distancesMeters: [],
      timesFromStartSeconds: [],
      segments: [],
      singletons: [],
    };
  }

  const rawGroups = splitByTimeGaps(points);
  const rawCumDist = cumulativeDistances(rawGroups);
  const rawCumTime = cumulativeTimesSeconds(rawGroups);
  const idx = downsampleIndices(rawGroups);

  const sampledGroups: Point[][] = rawGroups.map((g, gi) =>
    idx[gi].length === g.length ? g : idx[gi].map((ii) => g[ii]),
  );
  // Mirror the identity short-circuit on the distance side — under-budget
  // inputs are the common case and there's no reason to allocate a new
  // array when every index maps to itself.
  const sampledCumDist: number[][] = rawCumDist.map((cum, gi) =>
    idx[gi].length === cum.length ? cum : idx[gi].map((ii) => cum[ii]),
  );
  const sampledCumTime: number[][] = rawCumTime.map((cum, gi) =>
    idx[gi].length === cum.length ? cum : idx[gi].map((ii) => cum[ii]),
  );

  const segments: Segment[] = [];
  const singletons: Singleton[] = [];

  sampledGroups.forEach((sg) => {
    if (sg.length === 0) return;
    if (sg.length === 1) {
      singletons.push({ point: sg[0] });
      return;
    }
    segments.push({
      positions: sg.map((p) => [p.latitude, p.longitude] as [number, number]),
    });
  });

  return {
    groups: sampledGroups,
    sampled: sampledGroups.flat(),
    distancesMeters: sampledCumDist.flat(),
    timesFromStartSeconds: sampledCumTime.flat(),
    segments,
    singletons,
  };
}

// --------------------------------------------------------------------------
// Direction arrows
// --------------------------------------------------------------------------

/// Place direction-of-travel arrows at fixed metric intervals along a
/// polyline. Half-interval padding at both ends keeps them clear of the
/// Start / End markers. Returns empty for traces shorter than one
/// interval — a 50 m trace with one arrow halfway along just clutters
/// the map.
export function arrowsAlong(
  positions: { latitude: number; longitude: number }[],
  intervalMeters: number = ARROW_INTERVAL_METERS,
): DirectionArrow[] {
  if (positions.length < 2 || intervalMeters <= 0) return [];

  let total = 0;
  for (let i = 1; i < positions.length; i++) {
    total += haversineMeters(positions[i - 1], positions[i]);
  }
  if (total < intervalMeters) return [];

  const arrows: DirectionArrow[] = [];
  const halfInterval = intervalMeters / 2;
  const lastPos = total - halfInterval;
  let covered = 0;
  let next = halfInterval;

  for (let i = 1; i < positions.length && next <= lastPos; i++) {
    const a = positions[i - 1];
    const b = positions[i];
    const seg = haversineMeters(a, b);
    if (seg === 0) continue;
    while (next <= covered + seg && next <= lastPos) {
      const t = (next - covered) / seg;
      arrows.push({
        latitude: a.latitude + (b.latitude - a.latitude) * t,
        longitude: a.longitude + (b.longitude - a.longitude) * t,
        bearing: bearingDeg(a, b),
      });
      next += intervalMeters;
    }
    covered += seg;
  }
  return arrows;
}
