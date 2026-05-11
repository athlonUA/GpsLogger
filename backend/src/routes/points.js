import { Router } from 'express';
import { pool } from '../db.js';
import { validateBatch, validateRange } from '../validate.js';

const router = Router();

// Target number of points returned by GET /points. Larger than the previous
// hard cap (10k) so multi-month windows still render the whole trace, but
// bounded so the response stays in the ~5 MB range. When the matching row
// count exceeds the target, the server returns an evenly-spaced sample of
// the trace (stride = ceil(total / TARGET)) with the first and last fixes
// always preserved — the shape of the route is intact, just at lower
// fidelity. The client's own downsampling continues to apply on top.
export const SAMPLE_TARGET = 50_000;

// Compute the stride that maps `total` rows to at most `target` evenly-spaced
// samples. Returns 1 when no sampling is needed. Pure helper exported so
// the policy can be unit-tested independent of the DB.
export function computeStride(total, target = SAMPLE_TARGET) {
  if (!Number.isFinite(total) || total <= 0) return 1;
  if (!Number.isFinite(target) || target <= 0) return 1;
  if (total <= target) return 1;
  return Math.ceil(total / target);
}

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
    const where = clauses.join(' AND ');

    // Two-step pattern: first cheap COUNT(*) over the (device_id, created_at)
    // index to size the response, then a strided SELECT. Splitting avoids
    // forcing PostgreSQL to materialize the full result set inside a single
    // window function (COUNT(*) OVER ()), which would defeat the index for
    // multi-million-row scans.
    const countSql = `SELECT COUNT(*)::bigint AS n FROM points WHERE ${where}`;
    const { rows: countRows } = await pool.query(countSql, values);
    const total = Number(countRows[0].n);

    if (total === 0) {
      return res.json({ data: [], sampled: false, total: 0 });
    }

    const stride = computeStride(total, SAMPLE_TARGET);
    const sampled = stride > 1;

    let dataSql;
    if (!sampled) {
      dataSql = `SELECT id, latitude, longitude, created_at FROM points WHERE ${where} ORDER BY created_at ASC`;
    } else {
      // ROW_NUMBER picks every `stride`-th fix; the explicit `rn = $last`
      // disjunction guarantees the End marker lands on the true final fix
      // regardless of whether `total - 1` is divisible by stride.
      // Parameters are appended to the existing positional list so the
      // strided variant cannot be tripped by an attacker-controlled WHERE.
      const strideIdx = values.length + 1;
      const lastIdx = values.length + 2;
      values.push(stride, total - 1);
      dataSql = `
        SELECT id, latitude, longitude, created_at FROM (
          SELECT id, latitude, longitude, created_at,
                 ROW_NUMBER() OVER (ORDER BY created_at ASC) - 1 AS rn
          FROM points WHERE ${where}
        ) t
        WHERE rn % $${strideIdx} = 0 OR rn = $${lastIdx}
        ORDER BY created_at ASC`;
    }

    const { rows: data } = await pool.query(dataSql, values);
    res.json({ data, sampled, total });
  } catch (err) {
    next(err);
  }
});

export default router;
