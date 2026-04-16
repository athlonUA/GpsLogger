-- Redundant index cleanup.
--
-- Migration 001 created `idx_points_created_at` (single-column), before
-- 002 introduced `device_id` and the composite
-- `idx_points_device_id_created_at`. Every read query at the API layer
-- (`GET /points?device_id=...`) filters by `device_id` first, so Postgres
-- plans them against the composite index; the single-column index is
-- never chosen and only pays the per-insert maintenance cost. Dropping
-- it reduces hot-path write amplification and costs nothing operationally.
--
-- `IF EXISTS` keeps the migration idempotent on fresh databases and on
-- environments where this cleanup has already been applied manually.

DROP INDEX IF EXISTS idx_points_created_at;
