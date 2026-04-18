import { Router } from 'express';
import { pool } from '../db.js';
import { validateBatch, validateRange } from '../validate.js';
import { matchTrace } from '../matcher.js';

const router = Router();

// Map-matching is an opt-in service. When `OSRM_URL` is unset the
// `/matched` endpoint returns 503 so the client can disable the toggle
// instead of silently falling back to raw coordinates. Reading the env
// at module load is safe because we never mutate it at runtime.
const OSRM_URL = process.env.OSRM_URL || '';

router.post('/', async (req, res, next) => {
  try {
    const v = validateBatch(req.body);
    if (!v.ok) return res.status(400).json({ error: v.error });

    const { points } = v;
    const placeholders = [];
    const values = [];
    for (let i = 0; i < points.length; i++) {
      const base = i * 4;
      placeholders.push(`($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4})`);
      values.push(
        points[i].latitude,
        points[i].longitude,
        points[i].created_at,
        points[i].device_id,
      );
    }
    // ON CONFLICT DO NOTHING idempotency: if the client retries a batch
    // because a previous response was lost in flight, the duplicate
    // (device_id, created_at) rows are silently skipped. `RETURNING id`
    // lets us count how many actually landed so the response reflects the
    // real state, not the submitted size.
    const sql =
      `INSERT INTO points (latitude, longitude, created_at, device_id) ` +
      `VALUES ${placeholders.join(', ')} ` +
      `ON CONFLICT (device_id, created_at) DO NOTHING ` +
      `RETURNING id`;
    const result = await pool.query(sql, values);

    res.status(201).json({
      inserted: result.rowCount,
      submitted: points.length,
    });
  } catch (err) {
    next(err);
  }
});

router.get('/', async (req, res, next) => {
  try {
    const v = validateRange(req.query);
    if (!v.ok) return res.status(400).json({ error: v.error });

    const { rows, truncated } = await queryPointsInRange(v);
    res.json({ data: rows, truncated });
  } catch (err) {
    next(err);
  }
});

// GET /points/matched — same range-scan as GET /points, but each row is
// snapped to the OSRM road/path graph before it's returned. When OSRM is
// unreachable or disabled at deploy time we return 503 so the frontend
// can disable its Raw/Matched toggle; unmatched individual rows inside a
// successful response keep the raw coordinates so the rendered polyline
// is continuous regardless.
router.get('/matched', async (req, res, next) => {
  try {
    if (!OSRM_URL) {
      return res.status(503).json({ error: 'map_matching_disabled' });
    }
    const v = validateRange(req.query);
    if (!v.ok) return res.status(400).json({ error: v.error });

    const { rows, truncated } = await queryPointsInRange(v);
    const result = await matchTrace(OSRM_URL, rows, { log: req.log });
    res.json({
      data: result.points,
      truncated,
      matched_count: result.matchedCount,
      total_count: result.totalCount,
    });
  } catch (err) {
    next(err);
  }
});

// Shared range-query helper. Mirrors the `/points` GET handler so the
// matched endpoint reads the same slice of data the raw endpoint would
// have returned — any future cap/index change only has to be made once.
async function queryPointsInRange(v) {
  const clauses = ['device_id = $1'];
  const values = [v.device_id];
  if (v.from) {
    values.push(v.from);
    clauses.push(`created_at >= $${values.length}`);
  }
  if (v.to) {
    values.push(v.to);
    clauses.push(`created_at <= $${values.length}`);
  }
  const LIMIT = 10_000;
  const sql =
    `SELECT id, latitude, longitude, created_at FROM points ` +
    `WHERE ${clauses.join(' AND ')} ORDER BY created_at ASC LIMIT ${LIMIT + 1}`;
  const { rows } = await pool.query(sql, values);
  const truncated = rows.length > LIMIT;
  if (truncated) rows.length = LIMIT;
  return { rows, truncated };
}

export default router;
