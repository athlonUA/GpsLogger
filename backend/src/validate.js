export const MAX_BATCH = 1000;
export const MAX_DEVICE_ID_LEN = 128;
export const MAX_DECISION_LEN = 64;

function isValidDeviceId(v) {
  return typeof v === 'string' && v.length > 0 && v.length <= MAX_DEVICE_ID_LEN;
}

function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

export function validateBatch(body) {
  if (!Array.isArray(body)) {
    return { ok: false, error: 'body must be a JSON array of points' };
  }
  if (body.length === 0) {
    return { ok: false, error: 'empty batch' };
  }
  if (body.length > MAX_BATCH) {
    return { ok: false, error: `batch too large (max ${MAX_BATCH})` };
  }

  const points = new Array(body.length);
  for (let i = 0; i < body.length; i++) {
    const raw = body[i];
    if (!raw || typeof raw !== 'object') {
      return { ok: false, error: `points[${i}]: must be an object` };
    }
    const { latitude, longitude, created_at, device_id } = raw;

    if (typeof latitude !== 'number' || !Number.isFinite(latitude) || latitude < -90 || latitude > 90) {
      return { ok: false, error: `points[${i}].latitude: must be a finite number in [-90, 90]` };
    }
    if (typeof longitude !== 'number' || !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
      return { ok: false, error: `points[${i}].longitude: must be a finite number in [-180, 180]` };
    }
    if (typeof created_at !== 'string') {
      return { ok: false, error: `points[${i}].created_at: must be an ISO 8601 string` };
    }
    const ts = new Date(created_at);
    if (Number.isNaN(ts.getTime())) {
      return { ok: false, error: `points[${i}].created_at: invalid date` };
    }
    if (!isValidDeviceId(device_id)) {
      return { ok: false, error: `points[${i}].device_id: must be a non-empty string up to ${MAX_DEVICE_ID_LEN} chars` };
    }

    points[i] = { latitude, longitude, created_at: ts, device_id };
  }
  return { ok: true, points };
}

// Raw CLLocation fields uploaded alongside each point's filter verdict.
// Negative values are legitimate and meaningful here — they are CoreLocation's
// documented sentinels for "no data", and are the exact signal used to
// classify network-origin fixes. So the validator only rejects *non-finite*
// numbers (NaN, Infinity) and type mismatches, never negatives.
const DIAGNOSTIC_NUMERIC_FIELDS = [
  'horizontal_accuracy',
  'vertical_accuracy',
  'altitude',
  'speed',
  'speed_accuracy',
  'course',
  'course_accuracy',
];

export function validateDiagnosticsBatch(body) {
  if (!Array.isArray(body)) {
    return { ok: false, error: 'body must be a JSON array of diagnostics' };
  }
  if (body.length === 0) {
    return { ok: false, error: 'empty batch' };
  }
  if (body.length > MAX_BATCH) {
    return { ok: false, error: `batch too large (max ${MAX_BATCH})` };
  }

  const rows = new Array(body.length);
  for (let i = 0; i < body.length; i++) {
    const raw = body[i];
    if (!raw || typeof raw !== 'object') {
      return { ok: false, error: `diagnostics[${i}]: must be an object` };
    }

    // Coordinates get the same range checks as /points — they're the
    // lat/lon of the CLLocation that triggered the row, so nonsense values
    // are never legitimate.
    const { latitude, longitude } = raw;
    if (typeof latitude !== 'number' || !Number.isFinite(latitude) || latitude < -90 || latitude > 90) {
      return { ok: false, error: `diagnostics[${i}].latitude: must be a finite number in [-90, 90]` };
    }
    if (typeof longitude !== 'number' || !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
      return { ok: false, error: `diagnostics[${i}].longitude: must be a finite number in [-180, 180]` };
    }

    const { logged_at, fix_timestamp } = raw;
    if (typeof logged_at !== 'string') {
      return { ok: false, error: `diagnostics[${i}].logged_at: must be an ISO 8601 string` };
    }
    const loggedDate = new Date(logged_at);
    if (Number.isNaN(loggedDate.getTime())) {
      return { ok: false, error: `diagnostics[${i}].logged_at: invalid date` };
    }
    if (typeof fix_timestamp !== 'string') {
      return { ok: false, error: `diagnostics[${i}].fix_timestamp: must be an ISO 8601 string` };
    }
    const fixDate = new Date(fix_timestamp);
    if (Number.isNaN(fixDate.getTime())) {
      return { ok: false, error: `diagnostics[${i}].fix_timestamp: invalid date` };
    }

    for (const key of DIAGNOSTIC_NUMERIC_FIELDS) {
      if (!isFiniteNumber(raw[key])) {
        return { ok: false, error: `diagnostics[${i}].${key}: must be a finite number` };
      }
    }

    const { decision } = raw;
    if (typeof decision !== 'string' || decision.length === 0 || decision.length > MAX_DECISION_LEN) {
      return { ok: false, error: `diagnostics[${i}].decision: must be a non-empty string up to ${MAX_DECISION_LEN} chars` };
    }

    if (!isValidDeviceId(raw.device_id)) {
      return { ok: false, error: `diagnostics[${i}].device_id: must be a non-empty string up to ${MAX_DEVICE_ID_LEN} chars` };
    }

    rows[i] = {
      logged_at: loggedDate,
      fix_timestamp: fixDate,
      latitude,
      longitude,
      horizontal_accuracy: raw.horizontal_accuracy,
      vertical_accuracy: raw.vertical_accuracy,
      altitude: raw.altitude,
      speed: raw.speed,
      speed_accuracy: raw.speed_accuracy,
      course: raw.course,
      course_accuracy: raw.course_accuracy,
      decision,
      device_id: raw.device_id,
    };
  }
  return { ok: true, rows };
}

export function validateRange(query) {
  const out = {};

  // device_id is required: GET /points is always scoped to a specific device
  // so an unauthenticated caller cannot enumerate the full dataset by
  // omitting filters.
  if (!isValidDeviceId(query.device_id)) {
    return { ok: false, error: 'device_id: required, non-empty string' };
  }
  out.device_id = query.device_id;

  if (query.from !== undefined) {
    if (typeof query.from !== 'string') return { ok: false, error: 'from: must be an ISO string' };
    const d = new Date(query.from);
    if (Number.isNaN(d.getTime())) return { ok: false, error: 'from: invalid date' };
    out.from = d;
  }
  if (query.to !== undefined) {
    if (typeof query.to !== 'string') return { ok: false, error: 'to: must be an ISO string' };
    const d = new Date(query.to);
    if (Number.isNaN(d.getTime())) return { ok: false, error: 'to: invalid date' };
    out.to = d;
  }
  if (out.from && out.to && out.from > out.to) {
    return { ok: false, error: 'from must be <= to' };
  }
  return { ok: true, ...out };
}
