export const MAX_BATCH = 1000;

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
    const { latitude, longitude, created_at } = raw;

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

    points[i] = { latitude, longitude, created_at: ts };
  }
  return { ok: true, points };
}

export function validateRange(query) {
  const out = {};
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
