// Pure route-processing helpers used by `MapView`.
//
// Extracted into their own module so the rendering path (react-leaflet,
// which requires the DOM) and the logic path (segmentation, downsampling,
// gradient math) can be tested in isolation. Importing this file never
// touches window / document, so it loads cleanly under `vitest`'s default
// Node environment.
//
// Keep this file free of JSX and free of any runtime dependency on
// react-leaflet or `leaflet` itself. Types only, if a Leaflet interop is
// ever needed here.

import type { Point } from './api';

/// Target point budget after downsampling. Not a visual cap — Leaflet can
/// render more — but an empirical sweet spot where interaction stays
/// responsive on modest hardware. Shared via export so the test suite can
/// exercise both the under-budget and over-budget branches without
/// duplicating the constant.
export const MAX_POINTS = 4000;

/// Number of color chunks per polyline group. Leaflet polylines carry a
/// single color; we fake a gradient by splitting each group into up to
/// this many constant-color sub-polylines.
export const GRADIENT_CHUNKS = 64;

/// Break the route whenever consecutive fixes are more than this far apart
/// in time. Bridging such gaps would draw straight "teleport" lines
/// across unrelated locations (car trips, power-off periods, etc.).
export const GAP_MS = 5 * 60 * 1000;

/// Spacing between direction arrows along a rendered polyline, in meters.
/// 150 m is large enough that the map stays uncluttered at city zoom
/// levels and small enough that the *direction of travel* is immediately
/// obvious on any non-trivial route — if you can see three consecutive
/// arrows, the polyline is directed.
export const ARROW_INTERVAL_METERS = 150;

export type Segment = { positions: [number, number][]; color: string };
export type Singleton = { point: Point; color: string };
export type RenderData = { segments: Segment[]; singletons: Singleton[] };

export type DirectionArrow = {
  /// Lat/lon where the arrow sits on the polyline. Computed by linear
  /// interpolation along the segment that contains the target distance.
  latitude: number;
  longitude: number;
  /// Forward bearing in degrees (0° = north, 90° = east). Matches the
  /// direction of travel along the segment the arrow was placed on.
  bearing: number;
};

/// Split a time-sorted list of points into groups, starting a new group
/// whenever the time delta to the previous point exceeds `GAP_MS`.
/// Assumes the input is already sorted ascending by `created_at`; if it
/// isn't, "gaps" are computed against whatever order the caller passed,
/// which usually produces degenerate output. Non-finite deltas (both
/// timestamps parse to NaN) are treated as non-gaps and keep the fix in
/// the current group, so one malformed row doesn't shatter the trace.
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

/// Downsample each group independently while sharing a global point budget
/// proportional to group size. Preserves segment boundaries (no merging)
/// and always keeps the first/last fix of each group so endpoints stay
/// anchored. If the total is already within budget, returns the input
/// unchanged.
export function downsampleGroups(groups: Point[][]): Point[][] {
  const total = groups.reduce((s, g) => s + g.length, 0);
  if (total <= MAX_POINTS) return groups;
  return groups.map((g) => {
    if (g.length <= 2) return g;
    const target = Math.max(2, Math.floor((g.length * MAX_POINTS) / total));
    const step = Math.ceil(g.length / target);
    const out: Point[] = [];
    for (let i = 0; i < g.length; i += step) out.push(g[i]);
    const last = g[g.length - 1];
    if (out[out.length - 1] !== last) out.push(last);
    return out;
  });
}

/// Blue (240°) → Purple (285°) → Red (360°) with purple exactly at
/// `t = 0.5`. Deliberately non-linear across the full hue range so the
/// perceptual midpoint stays where the user expects it (a dataset halved
/// by time shows purple at the half-way mark, not at some arbitrary hue).
export function gradientColor(t: number): string {
  const h =
    t < 0.5
      ? 240 + (285 - 240) * (t / 0.5)
      : 285 + (360 - 285) * ((t - 0.5) / 0.5);
  return `hsl(${h.toFixed(1)}, 78%, 58%)`;
}

/// Haversine distance in meters between two geographic points. Pure
/// function, kept local to this module so `route.ts` has no runtime
/// dependency on Leaflet (tests run in a DOM-free Node environment).
function haversineMeters(
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

/// Forward bearing from `a` to `b`, in degrees where 0° is north and
/// 90° is east. Matches the standard great-circle initial-bearing
/// formula; for the short polyline segments typical in a phone trace
/// (< 50 m), the bearing is effectively the same as a flat-Earth
/// heading, so this formulation stays correct at any zoom level.
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

/// Place direction-of-travel arrows at fixed metric intervals along a
/// polyline. The first arrow is offset by half the interval so it does
/// not visually collide with the Start marker, and the last usable
/// position stops a half-interval short of the end so the End marker
/// stays clear too. Bearing is taken from the polyline segment the
/// arrow was placed on, so turns are reflected automatically.
///
/// Returns an empty array for inputs shorter than a single interval —
/// a ~50 m trace with one arrow halfway along does not add clarity,
/// it just clutters the map.
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
    // One segment can host multiple arrows on a long straightaway.
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

/// Build render primitives for every time-gap group.
///   - Groups with `n >= 2` become gradient polyline chunks.
///   - Groups with `n === 1` become standalone `Singleton` markers.
/// Gradient `t` is computed against the global sampled-point index so
/// colors convey chronological progression across the whole query window,
/// not just within one group.
export function buildSegments(groups: Point[][]): RenderData {
  const total = groups.reduce((s, g) => s + g.length, 0);
  if (total < 1) return { segments: [], singletons: [] };
  const segments: Segment[] = [];
  const singletons: Singleton[] = [];
  let globalIdx = 0;
  for (const group of groups) {
    const n = group.length;
    if (n >= 2) {
      const chunks = Math.min(GRADIENT_CHUNKS, n - 1);
      for (let c = 0; c < chunks; c++) {
        const start = Math.floor((c * (n - 1)) / chunks);
        const end = Math.floor(((c + 1) * (n - 1)) / chunks) + 1;
        const positions = group
          .slice(start, end)
          .map((p) => [p.latitude, p.longitude] as [number, number]);
        const mid = globalIdx + (start + end - 1) / 2;
        const t = total <= 1 ? 0 : mid / (total - 1);
        segments.push({ positions, color: gradientColor(t) });
      }
    } else if (n === 1) {
      const t = total <= 1 ? 0 : globalIdx / (total - 1);
      singletons.push({ point: group[0], color: gradientColor(t) });
    }
    globalIdx += n;
  }
  return { segments, singletons };
}
