import { describe, expect, it } from 'vitest';
import type { Point } from './api';
import {
  ARROW_INTERVAL_METERS,
  ARROW_MIN_METERS,
  ARROW_TARGET_PIXELS,
  arrowIntervalForZoom,
  arrowsAlong,
  buildRenderData,
  cumulativeDistances,
  cumulativeTimesSeconds,
  downsampleGroups,
  downsampleIndices,
  EARTH_CIRCUMFERENCE_M,
  GAP_MS,
  haversineMeters,
  MAX_ARROWS_PER_GROUP,
  MAX_POINTS,
  MAX_TOTAL_ARROWS,
  metersPerPixel,
  segmentLengths,
  splitByTimeGaps,
} from './route';

// 1° north at the equator ≈ 111_195 m.
const METERS_PER_DEG = (6_371_000 * Math.PI) / 180;

function mk(offsetSeconds: number, lat = 0, lng = 0): Point {
  const base = Date.UTC(2026, 0, 1, 0, 0, 0);
  return {
    id: offsetSeconds,
    latitude: lat,
    longitude: lng,
    created_at: new Date(base + offsetSeconds * 1000).toISOString(),
  };
}

function northwardTrace(
  count: number,
  speedMps: number,
  dtSeconds = 1,
  startSeconds = 0,
  startLat = 0,
): Point[] {
  const out: Point[] = [];
  for (let i = 0; i < count; i++) {
    const secs = startSeconds + i * dtSeconds;
    const lat = startLat + (i * speedMps * dtSeconds) / METERS_PER_DEG;
    out.push(mk(secs, lat, 0));
  }
  return out;
}

describe('splitByTimeGaps', () => {
  it('returns empty for empty input', () => {
    expect(splitByTimeGaps([])).toEqual([]);
  });

  it('returns a single one-point group for one point', () => {
    const points = [mk(0)];
    const groups = splitByTimeGaps(points);
    expect(groups).toHaveLength(1);
    expect(groups[0][0]).toBe(points[0]);
  });

  it('keeps close points in the same group', () => {
    const points = [mk(0), mk(30), mk(60), mk(90)];
    expect(splitByTimeGaps(points)).toHaveLength(1);
  });

  it('splits when dt exceeds GAP_MS', () => {
    // 5 min gap exactly is NOT a split (`> GAP_MS`, not `>=`).
    const justInside = [mk(0), mk(GAP_MS / 1000)];
    const justOver = [mk(0), mk(GAP_MS / 1000 + 1)];
    expect(splitByTimeGaps(justInside)).toHaveLength(1);
    expect(splitByTimeGaps(justOver)).toHaveLength(2);
  });

  it('produces singleton groups when a lone fix is surrounded by gaps', () => {
    const ten = 10 * 60;
    const points = [
      mk(0), mk(30),
      mk(ten),
      mk(2 * ten), mk(2 * ten + 30),
    ];
    const groups = splitByTimeGaps(points);
    expect(groups).toHaveLength(3);
    expect(groups[1]).toHaveLength(1);
  });
});

describe('downsampleGroups', () => {
  it('returns input unchanged when under budget', () => {
    const g = Array.from({ length: 100 }, (_, i) => mk(i));
    const groups = [g];
    const out = downsampleGroups(groups);
    expect(out).toBe(groups);
  });

  it('downsamples when over budget while preserving endpoints', () => {
    const n = MAX_POINTS * 3;
    const g = Array.from({ length: n }, (_, i) => mk(i));
    const [outG] = downsampleGroups([g]);
    expect(outG.length).toBeLessThanOrEqual(MAX_POINTS + 1);
    expect(outG[0]).toBe(g[0]);
    expect(outG[outG.length - 1]).toBe(g[n - 1]);
  });

  it('preserves singletons across downsampling', () => {
    const big = Array.from({ length: MAX_POINTS + 100 }, (_, i) => mk(i));
    const singleton = [mk(1_000_000)];
    const out = downsampleGroups([big, singleton]);
    expect(out[1][0]).toBe(singleton[0]);
  });
});

describe('downsampleIndices', () => {
  it('returns identity indices when under budget', () => {
    const g = Array.from({ length: 10 }, (_, i) => mk(i));
    expect(downsampleIndices([g])).toEqual([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]);
  });

  it('includes first and last indices when downsampling', () => {
    const n = MAX_POINTS * 3;
    const g = Array.from({ length: n }, (_, i) => mk(i));
    const [idx] = downsampleIndices([g]);
    expect(idx[0]).toBe(0);
    expect(idx[idx.length - 1]).toBe(n - 1);
  });
});

describe('haversineMeters', () => {
  it('returns ~0 for identical points', () => {
    const a = { latitude: 45.5, longitude: 13.7 };
    expect(haversineMeters(a, a)).toBeLessThan(1e-6);
  });

  it('returns ~111 km for 1° of latitude', () => {
    const d = haversineMeters({ latitude: 0, longitude: 0 }, { latitude: 1, longitude: 0 });
    expect(d).toBeGreaterThan(111_000);
    expect(d).toBeLessThan(111_400);
  });
});

describe('segmentLengths', () => {
  it('returns empty for groups shorter than 2', () => {
    expect(segmentLengths([])).toEqual([]);
    expect(segmentLengths([mk(0)])).toEqual([]);
  });

  it('returns n-1 lengths summing close to the end-to-end distance', () => {
    const trace = northwardTrace(5, 2, 1);
    const lens = segmentLengths(trace);
    expect(lens).toHaveLength(4);
    const total = lens.reduce((s, x) => s + x, 0);
    const endToEnd = haversineMeters(trace[0], trace[trace.length - 1]);
    expect(Math.abs(total - endToEnd)).toBeLessThan(0.1);
  });
});

describe('cumulativeDistances', () => {
  it('starts at 0 and is monotonically non-decreasing within a group', () => {
    const trace = northwardTrace(10, 3, 1);
    const [cum] = cumulativeDistances([trace]);
    expect(cum[0]).toBe(0);
    for (let i = 1; i < cum.length; i++) {
      expect(cum[i]).toBeGreaterThanOrEqual(cum[i - 1]);
    }
  });

  it('continues the running total across gaps without adding gap distance', () => {
    // Two groups separated by a large time gap AND a large spatial jump.
    // The gap itself must contribute zero; the total should equal the
    // sum of intra-group distances.
    const g1 = northwardTrace(5, 2, 1, 0, 0);
    const g2 = northwardTrace(5, 2, 1, 10_000, 10);
    const cum = cumulativeDistances([g1, g2]);
    const intraG1 = cum[0][cum[0].length - 1];
    const intraG2Delta = cum[1][cum[1].length - 1] - cum[1][0];

    expect(cum[1][0]).toBeCloseTo(intraG1, 5);
    expect(cum[1][cum[1].length - 1]).toBeCloseTo(intraG1 + intraG2Delta, 5);
  });
});

describe('cumulativeTimesSeconds', () => {
  it('returns empty for empty input', () => {
    expect(cumulativeTimesSeconds([])).toEqual([]);
  });

  it('returns empty for a group whose first element has no points', () => {
    // defensive — groups with zero-length inner arrays can't happen
    // from splitByTimeGaps but the function handles it.
    expect(cumulativeTimesSeconds([[]])).toEqual([]);
  });

  it('starts at 0 and is monotonically increasing within a group', () => {
    const trace = northwardTrace(10, 3, 1);
    const [cum] = cumulativeTimesSeconds([trace]);
    expect(cum[0]).toBe(0);
    for (let i = 1; i < cum.length; i++) {
      expect(cum[i]).toBeGreaterThan(cum[i - 1]);
    }
  });

  it('includes gap time between groups', () => {
    const g1 = northwardTrace(3, 2, 1, 0, 0);
    // 10_000 s later
    const g2 = northwardTrace(3, 2, 1, 10_000, 0);
    const cum = cumulativeTimesSeconds([g1, g2]);
    // g1 times: 0, 1, 2
    // g2 times: 10_000, 10_001, 10_002
    expect(cum[0]).toEqual([0, 1, 2]);
    expect(cum[1]).toEqual([10_000, 10_001, 10_002]);
  });
});

describe('buildRenderData', () => {
  it('returns empty render for empty input', () => {
    const out = buildRenderData([]);
    expect(out).toEqual({
      groups: [],
      sampled: [],
      distancesMeters: [],
      timesFromStartSeconds: [],
      segments: [],
      singletons: [],
    });
  });

  it('emits a singleton for a single point', () => {
    const p = mk(0, 10, 20);
    const out = buildRenderData([p]);
    expect(out.groups).toHaveLength(1);
    expect(out.groups[0]).toHaveLength(1);
    expect(out.segments).toHaveLength(0);
    expect(out.singletons).toHaveLength(1);
    expect(out.singletons[0].point).toBe(p);
    expect(out.distancesMeters).toEqual([0]);
    expect(out.timesFromStartSeconds).toEqual([0]);
  });

  it('emits a segment for a two-point trace', () => {
    const pts = [mk(0, 10, 20), mk(1, 10.001, 20)];
    const out = buildRenderData(pts);
    expect(out.groups).toHaveLength(1);
    expect(out.groups[0]).toHaveLength(2);
    expect(out.segments).toHaveLength(1);
    expect(out.singletons).toHaveLength(0);
    expect(out.segments[0].positions).toHaveLength(2);
  });

  it('produces stable shapes across 0/1/2/multi-point inputs', () => {
    const cases: Point[][] = [
      [],
      [mk(0, 1, 1)],
      [mk(0, 1, 1), mk(1, 1.001, 1)],
      northwardTrace(20, 1.5, 1),
    ];
    for (const input of cases) {
      const out = buildRenderData(input);
      expect(Array.isArray(out.groups)).toBe(true);
      expect(Array.isArray(out.segments)).toBe(true);
      expect(Array.isArray(out.singletons)).toBe(true);
      expect(Array.isArray(out.sampled)).toBe(true);
      expect(Array.isArray(out.distancesMeters)).toBe(true);
      expect(out.distancesMeters).toHaveLength(out.sampled.length);
      expect(Array.isArray(out.timesFromStartSeconds)).toBe(true);
      expect(out.timesFromStartSeconds).toHaveLength(out.sampled.length);
      const totalGroupPoints = out.groups.reduce((s, g) => s + g.length, 0);
      expect(totalGroupPoints).toBe(out.sampled.length);
      const singletonGroups = out.groups.filter((g) => g.length === 1).length;
      const segmentGroups = out.groups.filter((g) => g.length >= 2).length;
      expect(out.singletons).toHaveLength(singletonGroups);
      expect(out.segments).toHaveLength(segmentGroups);
    }
  });

  it('emits one polyline per group', () => {
    // Two gap-split groups → two polyline segments.
    const g1 = northwardTrace(5, 1.3, 1, 0, 0);
    const g2 = northwardTrace(5, 1.3, 1, 10 * 60 + 1, 1);
    const out = buildRenderData([...g1, ...g2]);
    expect(out.groups).toHaveLength(2);
    expect(out.segments).toHaveLength(2);
    expect(out.segments[0].positions).toHaveLength(5);
    expect(out.segments[1].positions).toHaveLength(5);
  });

  it('exposes cumulative distances aligned with sampled', () => {
    const trace = northwardTrace(20, 2, 1);
    const out = buildRenderData(trace);
    expect(out.distancesMeters.length).toBe(out.sampled.length);
    expect(out.distancesMeters[0]).toBe(0);
    for (let i = 1; i < out.distancesMeters.length; i++) {
      expect(out.distancesMeters[i]).toBeGreaterThanOrEqual(
        out.distancesMeters[i - 1],
      );
    }
    // (n-1) segments × dt × speed ≈ 19 × 1 × 2 = 38 m.
    const last = out.distancesMeters[out.distancesMeters.length - 1];
    expect(last).toBeGreaterThan(35);
    expect(last).toBeLessThan(40);
  });

  it('carries cumulative distance across a time-gap boundary', () => {
    // Two 10-point walks separated by a 10-min gap with a ~111 km
    // spatial jump. The gap must NOT add distance.
    const g1 = northwardTrace(10, 1.3, 1, 0, 0);
    const g1EndLat = g1[g1.length - 1].latitude;
    const g2 = northwardTrace(10, 1.3, 1, 10 * 60 + 1, g1EndLat + 1);
    const out = buildRenderData([...g1, ...g2]);
    const g1LastDist = out.distancesMeters[out.groups[0].length - 1];
    const g2FirstDist = out.distancesMeters[out.groups[0].length];
    expect(g2FirstDist).toBeCloseTo(g1LastDist, 3);
  });

  it('keeps distancesMeters aligned with sampled after downsampling', () => {
    // Over-budget input: the raw→sampled index mapping must be mirrored
    // on the distance arrays so the click-to-distance lookup in Map.tsx
    // remains correct.
    const n = MAX_POINTS * 3;
    const trace = northwardTrace(n, 2, 1);
    const out = buildRenderData(trace);
    expect(out.distancesMeters.length).toBe(out.sampled.length);
    expect(out.timesFromStartSeconds.length).toBe(out.sampled.length);
    // Endpoints survive downsampling — their distances must too.
    expect(out.distancesMeters[0]).toBe(0);
    expect(out.timesFromStartSeconds[0]).toBe(0);
    const lastSampled = out.sampled[out.sampled.length - 1];
    const lastDist = out.distancesMeters[out.distancesMeters.length - 1];
    const lastTime = out.timesFromStartSeconds[out.timesFromStartSeconds.length - 1];
    // Full raw distance ≈ (n-1) segments × 2 m = (MAX_POINTS*3 - 1) * 2.
    // The sampled endpoint is the raw endpoint, so its cumulative matches.
    const rawTotal = (n - 1) * haversineMeters(trace[0], trace[1]);
    expect(lastDist).toBeCloseTo(rawTotal, 0);
    expect(lastTime).toBe(n - 1);
    expect(lastSampled).toBe(trace[n - 1]);
  });

  it('aligns singleton flat indices with their distances in a mixed trace', () => {
    // Map.tsx indexes distancesMeters by a flat position derived from
    // walking groups in order — including singleton groups. This test
    // locks that contract: sampled.indexOf(singleton) === flat index
    // matching distancesMeters.
    const walkA = northwardTrace(5, 1.3, 1, 0, 0);
    const endLatA = walkA[walkA.length - 1].latitude;
    // Lone fix 10 min later, then another walk 10 min after that.
    const lone = mk(10 * 60 + 1, endLatA, 0);
    const walkB = northwardTrace(5, 1.3, 1, 20 * 60 + 2, endLatA);

    const out = buildRenderData([...walkA, lone, ...walkB]);
    expect(out.groups).toHaveLength(3);
    expect(out.singletons).toHaveLength(1);

    // The singleton sits at flat index = walkA.length (= 5).
    const singletonFlatIdx = walkA.length;
    expect(out.sampled[singletonFlatIdx]).toBe(lone);

    // Its cumulative distance equals walkA's end-of-group distance —
    // the time gap contributes zero.
    const walkAEndDist = out.distancesMeters[walkA.length - 1];
    expect(out.distancesMeters[singletonFlatIdx]).toBeCloseTo(walkAEndDist, 5);

    // Its cumulative time includes the gap — the lone fix sits 10 min
    // after the start (walkA has 5 points at 1 s intervals = 4 s).
    expect(out.timesFromStartSeconds[singletonFlatIdx]).toBe(10 * 60 + 1);
  });
});

describe('arrowsAlong', () => {
  const step = (fromLat: number, metersNorth: number) => ({
    latitude: fromLat + metersNorth / METERS_PER_DEG,
    longitude: 0,
  });

  it('returns empty for fewer than two positions', () => {
    expect(arrowsAlong([])).toEqual([]);
    expect(arrowsAlong([{ latitude: 0, longitude: 0 }])).toEqual([]);
  });

  it('returns empty for a polyline shorter than one interval', () => {
    expect(arrowsAlong([step(0, 0), step(0, 50)])).toEqual([]);
  });

  it('places arrows at the expected count along a long straight segment', () => {
    const arrows = arrowsAlong([step(0, 0), step(0, 1000)], 150);
    expect(arrows.length).toBeGreaterThanOrEqual(5);
    expect(arrows.length).toBeLessThanOrEqual(7);
  });

  it('bearing of due-north polyline is ≈ 0°', () => {
    const arrows = arrowsAlong([step(0, 0), step(0, 500)], 150);
    expect(arrows.length).toBeGreaterThan(0);
    for (const a of arrows) {
      const delta = Math.min(a.bearing, 360 - a.bearing);
      expect(delta).toBeLessThan(1);
    }
  });

  it('bearing of due-east polyline is ≈ 90°', () => {
    const positions = [
      { latitude: 0, longitude: 0 },
      { latitude: 0, longitude: 500 / METERS_PER_DEG },
    ];
    const arrows = arrowsAlong(positions, 150);
    for (const a of arrows) {
      expect(Math.abs(a.bearing - 90)).toBeLessThan(1);
    }
  });

  it('bearing follows a right-angle turn across the polyline', () => {
    const positions = [
      { latitude: 0, longitude: 0 },
      step(0, 500),
      { latitude: 500 / METERS_PER_DEG, longitude: 500 / METERS_PER_DEG },
    ];
    const arrows = arrowsAlong(positions, 150);
    const northArrows = arrows.filter((a) => a.latitude * METERS_PER_DEG < 450);
    const eastArrows = arrows.filter((a) => a.longitude * METERS_PER_DEG > 50);
    expect(northArrows.length).toBeGreaterThan(0);
    expect(eastArrows.length).toBeGreaterThan(0);
    for (const a of northArrows) {
      const d = Math.min(a.bearing, 360 - a.bearing);
      expect(d).toBeLessThan(2);
    }
    for (const a of eastArrows) {
      expect(Math.abs(a.bearing - 90)).toBeLessThan(2);
    }
  });

  it('caps arrow count for long routes via maxArrows', () => {
    const arrows = arrowsAlong([step(0, 0), step(0, 10_000)]);
    expect(arrows.length).toBeGreaterThan(0);
    expect(arrows.length).toBeLessThanOrEqual(MAX_ARROWS_PER_GROUP);
    // Effective interval is raised above the default because the route is long.
    const spacing = 10_000 / arrows.length;
    expect(spacing).toBeGreaterThan(ARROW_INTERVAL_METERS + 30);
  });

  it('uses default interval for short routes where maxArrows does not cap', () => {
    const arrows = arrowsAlong([step(0, 0), step(0, 1_000)]);
    expect(arrows.length).toBeGreaterThanOrEqual(5);
    expect(arrows.length).toBeLessThanOrEqual(7);
  });
});

describe('metersPerPixel', () => {
  it('at zoom 0 equator returns the full world width per 256 px tile', () => {
    // 1 px at zoom 0 ≈ EARTH_CIRCUMFERENCE / 256 ≈ 156_543 m.
    const mpp = metersPerPixel(0, 0);
    expect(mpp).toBeCloseTo(EARTH_CIRCUMFERENCE_M / 256, 0);
  });

  it('halves with each zoom step at the same latitude', () => {
    const a = metersPerPixel(10, 0);
    const b = metersPerPixel(11, 0);
    expect(b).toBeCloseTo(a / 2, 5);
  });

  it('shrinks with latitude (Mercator stretch) at fixed zoom', () => {
    const eq = metersPerPixel(14, 0);
    const mid = metersPerPixel(14, 39.5);
    const high = metersPerPixel(14, 60);
    expect(mid).toBeLessThan(eq);
    expect(high).toBeLessThan(mid);
    // At 60° N cos(60°) = 0.5, so mpp should be half the equator value.
    expect(high).toBeCloseTo(eq * 0.5, 4);
  });

  it('returns NaN for non-finite inputs', () => {
    expect(Number.isNaN(metersPerPixel(NaN, 0))).toBe(true);
    expect(Number.isNaN(metersPerPixel(14, NaN))).toBe(true);
    expect(Number.isNaN(metersPerPixel(14, Infinity))).toBe(true);
  });
});

describe('arrowIntervalForZoom', () => {
  it('interval grows as zoom decreases (wider screen-space gap covers more ground)', () => {
    const z18 = arrowIntervalForZoom(18, 39.5);
    const z14 = arrowIntervalForZoom(14, 39.5);
    const z11 = arrowIntervalForZoom(11, 39.5);
    expect(z14).toBeGreaterThan(z18);
    expect(z11).toBeGreaterThan(z14);
  });

  it('matches the target pixel gap × meters/pixel at moderate zoom', () => {
    const mpp = metersPerPixel(14, 39.5);
    expect(arrowIntervalForZoom(14, 39.5)).toBeCloseTo(
      ARROW_TARGET_PIXELS * mpp,
      4,
    );
  });

  it('clamps to the minimum metric floor at very high zoom', () => {
    // Zoom 24 at any latitude resolves to sub-meter pixels; the target
    // pixel gap × mpp is well below the floor.
    expect(arrowIntervalForZoom(24, 39.5)).toBe(ARROW_MIN_METERS);
  });

  it('falls back to the default interval for invalid input', () => {
    expect(arrowIntervalForZoom(NaN, 39.5)).toBe(ARROW_INTERVAL_METERS);
    expect(arrowIntervalForZoom(14, NaN)).toBe(ARROW_INTERVAL_METERS);
  });

  it('respects custom target pixels and floor', () => {
    // Doubling the target pixel gap doubles the metric interval (until
    // the floor kicks in).
    const a = arrowIntervalForZoom(14, 39.5, 100);
    const b = arrowIntervalForZoom(14, 39.5, 200);
    expect(b).toBeCloseTo(a * 2, 4);
    // High floor wins when target * mpp would fall below it.
    expect(arrowIntervalForZoom(20, 39.5, 1, 500)).toBe(500);
  });
});

describe('arrowsAlong + arrowIntervalForZoom integration', () => {
  // Reuses the `step` helper from the suite above by re-declaring it
  // locally (separate describe block scope).
  const step = (fromLat: number, metersNorth: number) => ({
    latitude: fromLat + metersNorth / METERS_PER_DEG,
    longitude: 0,
  });

  it('produces sparse arrows when zoomed out', () => {
    // A ~10 km north-south trace viewed at z=11 should yield only a
    // handful of arrows (interval ≈ km).
    const interval = arrowIntervalForZoom(11, 39.5);
    const arrows = arrowsAlong([step(0, 0), step(0, 10_000)], interval);
    expect(arrows.length).toBeLessThanOrEqual(5);
  });

  it('produces denser arrows when zoomed in', () => {
    // The same trace at z=15 should have noticeably more arrows.
    const intervalZoomedOut = arrowIntervalForZoom(11, 39.5);
    const intervalZoomedIn = arrowIntervalForZoom(15, 39.5);
    const sparse = arrowsAlong([step(0, 0), step(0, 10_000)], intervalZoomedOut);
    const dense = arrowsAlong([step(0, 0), step(0, 10_000)], intervalZoomedIn);
    expect(dense.length).toBeGreaterThan(sparse.length);
    // Per-group cap still binds when the screen-space target would
    // otherwise emit more than MAX_ARROWS_PER_GROUP markers.
    expect(dense.length).toBeLessThanOrEqual(MAX_ARROWS_PER_GROUP);
  });
});

describe('MAX_TOTAL_ARROWS global cap (Map.tsx logic)', () => {
  // Simulate the Map.tsx arrow-placement logic: compute a shared minimum
  // interval from the total route length, then call arrowsAlong per group.
  // This is a white-box test of the invariant, not of Map.tsx itself (which
  // touches React/Leaflet and cannot run in the Node test env).
  const step = (fromLat: number, metersNorth: number) => ({
    latitude: fromLat + metersNorth / METERS_PER_DEG,
    longitude: 0,
  });

  function simulateArrows(
    groups: { latitude: number; longitude: number }[][],
    zoom: number,
    lat: number,
  ) {
    const zoomInterval = arrowIntervalForZoom(zoom, lat);
    let totalLength = 0;
    groups.forEach((g) => {
      for (let i = 1; i < g.length; i++) {
        totalLength += haversineMeters(g[i - 1], g[i]);
      }
    });
    const globalMinInterval =
      totalLength > 0 ? totalLength / MAX_TOTAL_ARROWS : zoomInterval;
    const intervalMeters = Math.max(zoomInterval, globalMinInterval);

    let count = 0;
    groups.forEach((g) => {
      count += arrowsAlong(g, intervalMeters).length;
    });
    return count;
  }

  it('never exceeds MAX_TOTAL_ARROWS across many short groups', () => {
    // 20 groups of 1 km each (total 20 km), zoomed in to z=14 where the
    // per-group zoom interval would otherwise allow many arrows per group.
    const groups = Array.from({ length: 20 }, (_, gi) => [
      step(gi * 0.01, 0),
      step(gi * 0.01, 1_000),
    ]);
    const count = simulateArrows(groups, 14, 39.5);
    expect(count).toBeLessThanOrEqual(MAX_TOTAL_ARROWS);
  });

  it('never exceeds MAX_TOTAL_ARROWS for a single long group', () => {
    const group = [step(0, 0), step(0, 60_000)];
    const count = simulateArrows([group], 12, 39.5);
    expect(count).toBeLessThanOrEqual(MAX_TOTAL_ARROWS);
  });
});
