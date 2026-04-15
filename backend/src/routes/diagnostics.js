import { Router } from 'express';
import { pool } from '../db.js';
import { validateDiagnosticsBatch } from '../validate.js';

// Mirror of routes/points.js: single POST endpoint that validates a batch
// and multi-row inserts into `fix_diagnostics`. There is intentionally no
// GET route — diagnostics are read via psql / a DB browser against the
// authoritative Postgres table, not through the API.
const router = Router();

const COLS = 13;

router.post('/', async (req, res, next) => {
  try {
    const v = validateDiagnosticsBatch(req.body);
    if (!v.ok) return res.status(400).json({ error: v.error });

    const { rows } = v;
    const placeholders = [];
    const values = [];
    for (let i = 0; i < rows.length; i++) {
      const base = i * COLS;
      placeholders.push(
        `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5}, $${base + 6}, $${base + 7}, $${base + 8}, $${base + 9}, $${base + 10}, $${base + 11}, $${base + 12}, $${base + 13})`
      );
      const r = rows[i];
      values.push(
        r.logged_at,
        r.fix_timestamp,
        r.latitude,
        r.longitude,
        r.horizontal_accuracy,
        r.vertical_accuracy,
        r.altitude,
        r.speed,
        r.speed_accuracy,
        r.course,
        r.course_accuracy,
        r.decision,
        r.device_id,
      );
    }
    // ON CONFLICT DO NOTHING idempotency mirrors the `/points` channel.
    // The natural key is (device_id, fix_timestamp) — `fix_timestamp` is
    // `CLLocation.timestamp`, which is stable across retries even if
    // `logged_at` isn't (logged_at is stamped on each call to
    // `logDiagnostic`). See migration 004 and the unique index on
    // `fix_diagnostics`.
    const sql = `
      INSERT INTO fix_diagnostics (
        logged_at, fix_timestamp, latitude, longitude,
        horizontal_accuracy, vertical_accuracy, altitude,
        speed, speed_accuracy, course, course_accuracy,
        decision, device_id
      ) VALUES ${placeholders.join(', ')}
      ON CONFLICT (device_id, fix_timestamp) DO NOTHING
      RETURNING id
    `;
    const result = await pool.query(sql, values);

    res.status(201).json({
      inserted: result.rowCount,
      submitted: rows.length,
    });
  } catch (err) {
    next(err);
  }
});

export default router;
