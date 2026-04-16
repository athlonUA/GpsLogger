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

export type Segment = { positions: [number, number][]; color: string };
export type Singleton = { point: Point; color: string };
export type RenderData = { segments: Segment[]; singletons: Singleton[] };

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
