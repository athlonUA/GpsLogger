import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  validateBatch,
  validateRange,
  validateDiagnosticsBatch,
  MAX_BATCH,
  MAX_DEVICE_ID_LEN,
  MAX_DECISION_LEN,
} from '../src/validate.js';

const DEV = 'device-abc-123';

test('validateBatch: accepts a valid single-point batch', () => {
  const r = validateBatch([
    { latitude: 37.7749, longitude: -122.4194, created_at: '2024-01-01T12:00:00.000Z', device_id: DEV },
  ]);
  assert.equal(r.ok, true);
  assert.equal(r.points.length, 1);
  assert.equal(r.points[0].latitude, 37.7749);
  assert.equal(r.points[0].longitude, -122.4194);
  assert.ok(r.points[0].created_at instanceof Date);
  assert.equal(r.points[0].device_id, DEV);
});

test('validateBatch: accepts a valid multi-point batch', () => {
  const r = validateBatch([
    { latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV },
    { latitude: 89, longitude: 179, created_at: '2024-01-01T00:00:01Z', device_id: DEV },
    { latitude: -89, longitude: -179, created_at: '2024-01-01T00:00:02Z', device_id: DEV },
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
  const big = new Array(MAX_BATCH + 1).fill({ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV });
  const r = validateBatch(big);
  assert.equal(r.ok, false);
  assert.match(r.error, /too large/);
});

test('validateBatch: rejects out-of-range latitude', () => {
  assert.equal(validateBatch([{ latitude: 91, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: -91, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: NaN, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: 'x', longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
});

test('validateBatch: rejects out-of-range longitude', () => {
  assert.equal(validateBatch([{ latitude: 0, longitude: 181, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: -181, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: Infinity, created_at: '2024-01-01T00:00:00Z', device_id: DEV }]).ok, false);
});

test('validateBatch: rejects invalid created_at', () => {
  assert.equal(validateBatch([{ latitude: 0, longitude: 0, created_at: 'not a date', device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: 0, created_at: 123, device_id: DEV }]).ok, false);
  assert.equal(validateBatch([{ latitude: 0, longitude: 0, device_id: DEV }]).ok, false);
});

test('validateBatch: rejects null element', () => {
  assert.equal(validateBatch([null]).ok, false);
});

test('validateBatch: rejects missing device_id', () => {
  const r = validateBatch([{ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z' }]);
  assert.equal(r.ok, false);
  assert.match(r.error, /device_id/);
});

test('validateBatch: rejects empty device_id', () => {
  const r = validateBatch([{ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: '' }]);
  assert.equal(r.ok, false);
  assert.match(r.error, /device_id/);
});

test('validateBatch: rejects non-string device_id', () => {
  const r = validateBatch([{ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: 42 }]);
  assert.equal(r.ok, false);
  assert.match(r.error, /device_id/);
});

test('validateBatch: rejects oversized device_id', () => {
  const huge = 'x'.repeat(MAX_DEVICE_ID_LEN + 1);
  const r = validateBatch([{ latitude: 0, longitude: 0, created_at: '2024-01-01T00:00:00Z', device_id: huge }]);
  assert.equal(r.ok, false);
  assert.match(r.error, /device_id/);
});

test('validateRange: accepts device_id only (no dates)', () => {
  const r = validateRange({ device_id: DEV });
  assert.equal(r.ok, true);
  assert.equal(r.device_id, DEV);
  assert.equal(r.from, undefined);
  assert.equal(r.to, undefined);
});

test('validateRange: parses device_id + from/to', () => {
  const r = validateRange({ device_id: DEV, from: '2024-01-01T00:00:00Z', to: '2024-01-02T00:00:00Z' });
  assert.equal(r.ok, true);
  assert.equal(r.device_id, DEV);
  assert.ok(r.from instanceof Date);
  assert.ok(r.to instanceof Date);
});

test('validateRange: rejects missing device_id', () => {
  assert.equal(validateRange({}).ok, false);
  assert.equal(validateRange({ from: '2024-01-01T00:00:00Z' }).ok, false);
});

test('validateRange: rejects empty device_id', () => {
  assert.equal(validateRange({ device_id: '' }).ok, false);
});

test('validateRange: rejects invalid dates', () => {
  assert.equal(validateRange({ device_id: DEV, from: 'xyz' }).ok, false);
  assert.equal(validateRange({ device_id: DEV, to: 'xyz' }).ok, false);
});

test('validateRange: rejects from > to', () => {
  const r = validateRange({ device_id: DEV, from: '2024-02-01T00:00:00Z', to: '2024-01-01T00:00:00Z' });
  assert.equal(r.ok, false);
});

// ----- validateDiagnosticsBatch -----

// A row that represents a healthy GNSS fix (all fields populated, positive
// accuracies). Individual tests override whichever fields they exercise.
const VALID_DIAG = Object.freeze({
  logged_at: '2026-04-15T15:45:00.000Z',
  fix_timestamp: '2026-04-15T15:45:00.000Z',
  latitude: 50.45,
  longitude: 30.52,
  horizontal_accuracy: 10,
  vertical_accuracy: 10,
  altitude: 100,
  speed: 1.2,
  speed_accuracy: 0.5,
  course: 45,
  course_accuracy: 5,
  decision: 'accept',
  device_id: DEV,
});

test('validateDiagnosticsBatch: accepts a valid single row', () => {
  const r = validateDiagnosticsBatch([{ ...VALID_DIAG }]);
  assert.equal(r.ok, true);
  assert.equal(r.rows.length, 1);
  assert.ok(r.rows[0].logged_at instanceof Date);
  assert.ok(r.rows[0].fix_timestamp instanceof Date);
  assert.equal(r.rows[0].decision, 'accept');
  assert.equal(r.rows[0].device_id, DEV);
});

test('validateDiagnosticsBatch: accepts a valid multi-row batch', () => {
  const r = validateDiagnosticsBatch([
    { ...VALID_DIAG },
    { ...VALID_DIAG, fix_timestamp: '2026-04-15T15:45:01.000Z' },
    { ...VALID_DIAG, fix_timestamp: '2026-04-15T15:45:02.000Z' },
  ]);
  assert.equal(r.ok, true);
  assert.equal(r.rows.length, 3);
});

test('validateDiagnosticsBatch: accepts Wi-Fi fallback sentinels (negative speed / vAcc)', () => {
  // This is the WHOLE POINT of the table — we need to accept these rows so
  // that post-hoc analysis can classify the source. Rejecting negatives
  // would defeat the diagnostic purpose.
  const r = validateDiagnosticsBatch([{
    ...VALID_DIAG,
    speed: -1,
    speed_accuracy: -1,
    vertical_accuracy: -1,
    course: -1,
    course_accuracy: -1,
    altitude: 0,
    decision: 'discard:nonGpsSource',
  }]);
  assert.equal(r.ok, true);
  assert.equal(r.rows[0].speed, -1);
  assert.equal(r.rows[0].vertical_accuracy, -1);
});

test('validateDiagnosticsBatch: rejects non-array body', () => {
  assert.equal(validateDiagnosticsBatch({}).ok, false);
  assert.equal(validateDiagnosticsBatch(null).ok, false);
  assert.equal(validateDiagnosticsBatch('foo').ok, false);
  assert.equal(validateDiagnosticsBatch(42).ok, false);
});

test('validateDiagnosticsBatch: rejects empty batch', () => {
  const r = validateDiagnosticsBatch([]);
  assert.equal(r.ok, false);
  assert.match(r.error, /empty/);
});

test('validateDiagnosticsBatch: rejects oversized batch', () => {
  const big = new Array(MAX_BATCH + 1).fill({ ...VALID_DIAG });
  const r = validateDiagnosticsBatch(big);
  assert.equal(r.ok, false);
  assert.match(r.error, /too large/);
});

test('validateDiagnosticsBatch: rejects null element', () => {
  assert.equal(validateDiagnosticsBatch([null]).ok, false);
});

test('validateDiagnosticsBatch: rejects out-of-range latitude', () => {
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, latitude: 91 }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, latitude: -91 }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, latitude: NaN }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, latitude: 'x' }]).ok, false);
});

test('validateDiagnosticsBatch: rejects out-of-range longitude', () => {
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, longitude: 181 }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, longitude: -181 }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, longitude: Infinity }]).ok, false);
});

test('validateDiagnosticsBatch: rejects invalid logged_at', () => {
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, logged_at: 'not a date' }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, logged_at: 123 }]).ok, false);
  const noLogged = { ...VALID_DIAG };
  delete noLogged.logged_at;
  assert.equal(validateDiagnosticsBatch([noLogged]).ok, false);
});

test('validateDiagnosticsBatch: rejects invalid fix_timestamp', () => {
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, fix_timestamp: 'not a date' }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, fix_timestamp: 0 }]).ok, false);
});

test('validateDiagnosticsBatch: rejects non-finite numeric fields', () => {
  for (const key of ['horizontal_accuracy', 'vertical_accuracy', 'altitude', 'speed', 'speed_accuracy', 'course', 'course_accuracy']) {
    assert.equal(
      validateDiagnosticsBatch([{ ...VALID_DIAG, [key]: NaN }]).ok,
      false,
      `${key}=NaN should be rejected`,
    );
    assert.equal(
      validateDiagnosticsBatch([{ ...VALID_DIAG, [key]: Infinity }]).ok,
      false,
      `${key}=Infinity should be rejected`,
    );
    assert.equal(
      validateDiagnosticsBatch([{ ...VALID_DIAG, [key]: 'x' }]).ok,
      false,
      `${key}=string should be rejected`,
    );
  }
});

test('validateDiagnosticsBatch: rejects missing numeric fields', () => {
  for (const key of ['horizontal_accuracy', 'vertical_accuracy', 'altitude', 'speed', 'speed_accuracy', 'course', 'course_accuracy']) {
    const row = { ...VALID_DIAG };
    delete row[key];
    const r = validateDiagnosticsBatch([row]);
    assert.equal(r.ok, false, `missing ${key} should be rejected`);
    assert.match(r.error, new RegExp(key));
  }
});

test('validateDiagnosticsBatch: rejects missing/invalid decision', () => {
  const missing = { ...VALID_DIAG };
  delete missing.decision;
  assert.equal(validateDiagnosticsBatch([missing]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, decision: '' }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, decision: 42 }]).ok, false);
});

test('validateDiagnosticsBatch: rejects oversized decision', () => {
  const huge = 'x'.repeat(MAX_DECISION_LEN + 1);
  const r = validateDiagnosticsBatch([{ ...VALID_DIAG, decision: huge }]);
  assert.equal(r.ok, false);
  assert.match(r.error, /decision/);
});

test('validateDiagnosticsBatch: rejects missing/invalid device_id', () => {
  const missing = { ...VALID_DIAG };
  delete missing.device_id;
  assert.equal(validateDiagnosticsBatch([missing]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, device_id: '' }]).ok, false);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, device_id: 42 }]).ok, false);
  const huge = 'x'.repeat(MAX_DEVICE_ID_LEN + 1);
  assert.equal(validateDiagnosticsBatch([{ ...VALID_DIAG, device_id: huge }]).ok, false);
});
