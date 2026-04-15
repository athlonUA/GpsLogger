-- Attach a stable device identifier to every point.
--
-- ADD COLUMN with a NOT NULL DEFAULT '' lets us run this against a populated
-- table without a rewrite pause: existing rows pick up the default, new rows
-- must supply a value (enforced at the API layer). The composite index
-- covers the primary access pattern `WHERE device_id = ? AND created_at
-- BETWEEN ? AND ? ORDER BY created_at ASC`.
ALTER TABLE points ADD COLUMN IF NOT EXISTS device_id TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_points_device_id_created_at
    ON points (device_id, created_at);
