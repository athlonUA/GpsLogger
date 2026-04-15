import { Router } from 'express';
import { pool } from '../db.js';
import { validateBatch, validateRange } from '../validate.js';

const router = Router();

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
    const sql = `SELECT id, latitude, longitude, created_at FROM points WHERE ${clauses.join(' AND ')} ORDER BY created_at ASC`;
    const { rows } = await pool.query(sql, values);

    res.json(rows);
  } catch (err) {
    next(err);
  }
});

export default router;
