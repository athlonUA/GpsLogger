import { describe, expect, it } from 'vitest';
import type { Point } from './api';
import {
  buildSegments,
  downsampleGroups,
  GAP_MS,
  gradientColor,
  MAX_POINTS,
  splitByTimeGaps,
} from './route';

// Construct a fake Point. ISO timestamps are UTC so the tests are
// timezone-independent; `id` is derived from the second offset for unique,
// stable-across-runs identifiers.
function mk(offsetSeconds: number, lat = 0, lng = 0): Point {
  const base = Date.UTC(2026, 0, 1, 0, 0, 0);
  return {
    id: offsetSeconds,
    latitude: lat,
    longitude: lng,
    created_at: new Date(base + offsetSeconds * 1000).toISOString(),
  };
}

describe('splitByTimeGaps', () => {
  it('returns empty for empty input', () => {
    expect(splitByTimeGaps([])).toEqual([]);
  });

  it('returns a single one-point group for one point', () => {
    const points = [mk(0)];
    const groups = splitByTimeGaps(points);
    expect(groups).toHaveLength(1);
    expect(groups[0]).toHaveLength(1);
    expect(groups[0][0]).toBe(points[0]);
  });

  it('keeps close points in the same group', () => {
    const points = [mk(0), mk(30), mk(60), mk(90)];
    const groups = splitByTimeGaps(points);
    expect(groups).toHaveLength(1);
    expect(groups[0]).toHaveLength(4);
  });

  it('splits when dt exceeds GAP_MS', () => {
    // 5 min gap exactly is NOT a split (the check is `> GAP_MS`, not `>=`).
    // 5 min + 1 s is.
    const justInside = [mk(0), mk(GAP_MS / 1000)];
    const justOver = [mk(0), mk(GAP_MS / 1000 + 1)];
    expect(splitByTimeGaps(justInside)).toHaveLength(1);
    expect(splitByTimeGaps(justOver)).toHaveLength(2);
  });

  it('handles many gaps', () => {
    // Three clusters of two points each, 10 min apart. Expect 3 groups.
    const ten = 10 * 60;
    const points = [
      mk(0), mk(10),
      mk(ten), mk(ten + 10),
      mk(2 * ten), mk(2 * ten + 10),
    ];
    const groups = splitByTimeGaps(points);
    expect(groups).toHaveLength(3);
    expect(groups.map((g) => g.length)).toEqual([2, 2, 2]);
  });

  it('produces singleton groups when a lone fix is surrounded by gaps', () => {
    // Cluster A, 10-min gap, lone fix, 10-min gap, cluster B.
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
    expect(out).toBe(groups); // identity
  });

  it('downsamples when over budget while preserving endpoints', () => {
    const n = MAX_POINTS * 3;
    const g = Array.from({ length: n }, (_, i) => mk(i));
    const out = downsampleGroups([g]);
    expect(out).toHaveLength(1);
    const outG = out[0];
    // Compressed below the total, not below the cap per group (per-group
    // budget is proportional — a single group gets ~MAX_POINTS).
    expect(outG.length).toBeLessThanOrEqual(MAX_POINTS + 1);
    expect(outG.length).toBeGreaterThan(2);
    // First and last fix must survive so the polyline's endpoints stay
    // anchored to the real trace, not to arbitrary sampled points.
    expect(outG[0]).toBe(g[0]);
    expect(outG[outG.length - 1]).toBe(g[n - 1]);
  });

  it('preserves a 2-point group as-is (below the per-group short-circuit)', () => {
    const big = Array.from({ length: MAX_POINTS + 100 }, (_, i) => mk(i));
    const tiny = [mk(1_000_000), mk(1_000_001)];
    const out = downsampleGroups([big, tiny]);
    expect(out[1]).toBe(tiny);
  });

  it('preserves singletons across downsampling', () => {
    const big = Array.from({ length: MAX_POINTS + 100 }, (_, i) => mk(i));
    const singleton = [mk(1_000_000)];
    const out = downsampleGroups([big, singleton]);
    expect(out[1]).toEqual(singleton);
    expect(out[1][0]).toBe(singleton[0]);
  });

  it('splits budget proportionally between groups', () => {
    const bigN = MAX_POINTS * 2;
    const smallN = MAX_POINTS / 2;
    const big = Array.from({ length: bigN }, (_, i) => mk(i));
    const small = Array.from({ length: smallN }, (_, i) => mk(1_000_000 + i));
    const out = downsampleGroups([big, small]);
    // Big group should have roughly 4x as many sampled points as small.
    expect(out[0].length).toBeGreaterThan(out[1].length);
  });
});

describe('gradientColor', () => {
  it('returns a valid hsl string at every sampled t', () => {
    for (const t of [0, 0.1, 0.25, 0.5, 0.75, 1]) {
      expect(gradientColor(t)).toMatch(/^hsl\(\d+(\.\d+)?, 78%, 58%\)$/);
    }
  });

  it('maps t=0 to 240°, t=0.5 to 285°, t=1 to 360°', () => {
    expect(gradientColor(0)).toBe('hsl(240.0, 78%, 58%)');
    expect(gradientColor(0.5)).toBe('hsl(285.0, 78%, 58%)');
    expect(gradientColor(1)).toBe('hsl(360.0, 78%, 58%)');
  });

  it('is monotonic in hue across [0, 1]', () => {
    const hues: number[] = [];
    for (let i = 0; i <= 20; i++) {
      const t = i / 20;
      const match = /^hsl\((\d+(?:\.\d+)?),/.exec(gradientColor(t));
      expect(match).not.toBeNull();
      hues.push(Number(match![1]));
    }
    for (let i = 1; i < hues.length; i++) {
      expect(hues[i]).toBeGreaterThanOrEqual(hues[i - 1]);
    }
  });
});

describe('buildSegments', () => {
  it('returns empty render for empty input', () => {
    expect(buildSegments([])).toEqual({ segments: [], singletons: [] });
  });

  it('emits a singleton for a 1-point group (audit fix C3)', () => {
    // Before the fix, a lone fix in its own time-gap group was silently
    // dropped from rendering — the on-map count diverged from the status
    // bar. This test locks in that singletons are always surfaced.
    const p = mk(0, 10, 20);
    const { segments, singletons } = buildSegments([[p]]);
    expect(segments).toHaveLength(0);
    expect(singletons).toHaveLength(1);
    expect(singletons[0].point).toBe(p);
  });

  it('emits polyline segments but no singletons for a multi-point group', () => {
    const group = Array.from({ length: 50 }, (_, i) => mk(i));
    const { segments, singletons } = buildSegments([group]);
    expect(singletons).toHaveLength(0);
    expect(segments.length).toBeGreaterThan(0);
    // Every segment should have at least two positions (start + end).
    for (const s of segments) {
      expect(s.positions.length).toBeGreaterThanOrEqual(2);
    }
  });

  it('emits both segments and singletons for mixed groups', () => {
    const a = Array.from({ length: 10 }, (_, i) => mk(i));
    const lone = [mk(10_000)];
    const b = Array.from({ length: 10 }, (_, i) => mk(20_000 + i));
    const { segments, singletons } = buildSegments([a, lone, b]);
    expect(singletons).toHaveLength(1);
    expect(segments.length).toBeGreaterThan(0);
  });

  it('assigns the chronological middle a purple-ish hue', () => {
    // A singleton at the dead centre of the global index should pick up
    // t ≈ 0.5, i.e. hue 285°. This locks in that the gradient stays
    // global across groups rather than restarting per group.
    const a = Array.from({ length: 5 }, (_, i) => mk(i));
    const centre = [mk(10_000)];
    const b = Array.from({ length: 5 }, (_, i) => mk(20_000 + i));
    const { singletons } = buildSegments([a, centre, b]);
    // globalIdx for the singleton is 5 (after a), total is 11, so
    // t = 5 / 10 = 0.5 exactly.
    expect(singletons[0].color).toBe('hsl(285.0, 78%, 58%)');
  });

  it('bookends the gradient at blue and red across the whole window', () => {
    // Bigger groups so the first/last chunk midpoints land close to the
    // absolute endpoints (t≈0 and t≈1). With only 2 points per group, the
    // single chunk's midpoint sits at the group's centre, which smears
    // the bookend hues toward the middle of the gradient.
    const a = Array.from({ length: 50 }, (_, i) => mk(i));
    const b = Array.from({ length: 50 }, (_, i) => mk(10_000 + i));
    const { segments } = buildSegments([a, b]);
    const parseHue = (color: string) => {
      const m = /^hsl\((\d+(?:\.\d+)?),/.exec(color);
      expect(m).not.toBeNull();
      return Number(m![1]);
    };
    const firstHue = parseHue(segments[0].color);
    const lastHue = parseHue(segments[segments.length - 1].color);
    // First chunk: t ≈ 0 → near 240°. Last chunk: t ≈ 1 → near 360°.
    expect(firstHue).toBeLessThan(245);
    expect(lastHue).toBeGreaterThan(355);
  });
});
