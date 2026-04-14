import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateBatch, validateRange, MAX_BATCH } from '../src/validate.js';

test('validateBatch: accepts a valid single-point batch', () => {
  const r = validateBatch([
    { latitude: 37.7749, longitude: -122.4194, created_at: '2024-01-01T12:00:00.000Z' },
  ]);
  assert.equal(r.ok, true);
  assert.equal(r.points.length, 1);
  assert.equal(r.points[0].latitude, 37.7749);
  assert.equal(r.points[0].longitude, -122.4194);
  assert.ok(r.points[0].created_at instanceof Date);
});

test('validateBatch: accepts a valid multi-point batch', () => {
  const r = validateBatch([
    { latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z' },
    { latitude: 89, longitude: 179, created_at: '2024-01-01T00:00:01Z' },
    { latitude: -89, longitude: -179, created_at: '2024-01-01T00:00:02Z' },
  ]);
  assert.equal(r.ok, true);
  assert.equal(r.points.length, 3);
});

test('validateBatch: rejects non-array body', () => {
  assert.equal(validateBatch({}).ok, false);
  assert.equal(validateBatch(null).ok, false);
  assert.equal(validateBatch('foo').ok, false);
  assert.equal(validateBatch(42).ok, false);
});

test('validateBatch: rejects empty batch', () => {
  const r = validateBatch([]);
  assert.equal(r.ok, false);
  assert.match(r.error, /empty/);
});

test('validateBatch: rejects oversized batch', () => {
  const big = new Array(MAX_BATCH + 1).fill({ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z' });
  const r = validateBatch(big);
  assert.equal(r.ok, false);
  assert.match(r.error, /too large/);
});

test('validateBatch: rejects out-of-range latitude', () => {
  assert.equal(validateBatch([{ latitude: 91, longitude: 0, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
  assert.equal(validateBatch([{ latitude: -91, longitude: 0, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
  assert.equal(validateBatch([{ latitude: NaN, longitude: 0, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
  assert.equal(validateBatch([{ latitude: 'x', longitude: 0, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
});

test('validateBatch: rejects out-of-range longitude', () => {
  assert.equal(validateBatch([{ latitude: 0, longitude: 181, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: -181, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: Infinity, created_at: '2024-01-01T00:00:00Z' }]).ok, false);
});

test('validateBatch: rejects invalid created_at', () => {
  assert.equal(validateBatch([{ latitude: 0, longitude: 0, created_at: 'not a date' }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: 0, created_at: 123 }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: 0 }]).ok, false);
});

test('validateBatch: rejects null element', () => {
  assert.equal(validateBatch([null]).ok, false);
});

test('validateRange: accepts empty query', () => {
  const r = validateRange({});
  assert.equal(r.ok, true);
  assert.equal(r.from, undefined);
  assert.equal(r.to, undefined);
});

test('validateRange: parses from/to', () => {
  const r = validateRange({ from: '2024-01-01T00:00:00Z', to: '2024-01-02T00:00:00Z' });
  assert.equal(r.ok, true);
  assert.ok(r.from instanceof Date);
  assert.ok(r.to instanceof Date);
});

test('validateRange: rejects invalid dates', () => {
  assert.equal(validateRange({ from: 'xyz' }).ok, false);
  assert.equal(validateRange({ to: 'xyz' }).ok, false);
});

test('validateRange: rejects from > to', () => {
  const r = validateRange({ from: '2024-02-01T00:00:00Z', to: '2024-01-01T00:00:00Z' });
  assert.equal(r.ok, false);
});
