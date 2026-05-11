import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeStride, SAMPLE_TARGET } from '../src/routes/points.js';

test('computeStride: returns 1 when total is at or under target', () => {
  assert.equal(computeStride(0), 1);
  assert.equal(computeStride(1), 1);
  assert.equal(computeStride(SAMPLE_TARGET - 1), 1);
  assert.equal(computeStride(SAMPLE_TARGET), 1);
});

test('computeStride: stride grows with total beyond target', () => {
  // 100k rows with a 50k target → every other row.
  assert.equal(computeStride(SAMPLE_TARGET * 2), 2);
  // 250k rows → stride 5 (ceil).
  assert.equal(computeStride(SAMPLE_TARGET * 5), 5);
  // Non-divisible totals round up.
  assert.equal(computeStride(SAMPLE_TARGET * 2 + 1), 3);
});

test('computeStride: custom target overrides default', () => {
  assert.equal(computeStride(1000, 100), 10);
  assert.equal(computeStride(99, 100), 1);
});

test('computeStride: defensive returns 1 for invalid input', () => {
  assert.equal(computeStride(-1), 1);
  assert.equal(computeStride(NaN), 1);
  assert.equal(computeStride(Infinity), 1);
  assert.equal(computeStride(100, 0), 1);
  assert.equal(computeStride(100, -1), 1);
});

test('computeStride: a sampled response never exceeds the target', () => {
  // The endpoint emits floor((total - 1) / stride) + 1 strided rows plus
  // at most one extra "last" row when total - 1 is not a multiple of stride.
  // Verify that the resulting count is always within target + 1 for a
  // range of totals.
  for (const total of [50_001, 100_000, 250_000, 999_999, 1_000_000]) {
    const stride = computeStride(total);
    const strided = Math.floor((total - 1) / stride) + 1;
    const lastExtra = (total - 1) % stride === 0 ? 0 : 1;
    const count = strided + lastExtra;
    assert.ok(
      count <= SAMPLE_TARGET + 1,
      `total=${total} stride=${stride} count=${count}`,
    );
  }
});
