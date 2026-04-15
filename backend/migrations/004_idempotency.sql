-- Idempotency constraints for the two write endpoints.
--
-- Scenario this fixes: iOS posts a batch, the backend successfully inserts
-- the rows, but the HTTP response is lost between the cellular/WiFi hand-off
-- and the phone. The iOS client treats this as a network failure, retains
-- the rows locally, and retries on the next 30 s sync tick. Without a
-- uniqueness constraint, the backend inserts the same rows again, producing
-- duplicates in the trace.
--
-- The (device_id, created_at) tuple is natural: the iOS client stamps
-- `created_at` from `CLLocation.timestamp`, which is monotonic per device
-- and precise to the millisecond. Two rows from the same device with the
-- exact same timestamp must be the same row — duplicate insertion is a
-- bug, never legitimate. Same reasoning for `(device_id, fix_timestamp)`
-- on `fix_diagnostics`.
--
-- Migration ordering: we first dedupe any duplicates that may already
-- exist in the DB from the pre-1.2.1 retry behavior (keeping the row
-- with the lowest `id`, which is chronologically the first insertion),
-- then create the unique index, which would otherwise fail on pre-existing
-- duplicates. Both DELETE and CREATE INDEX are idempotent on clean DBs.

-- --- points ---

DELETE FROM points a
    USING points b
 WHERE a.ctid < b.ctid
   AND a.device_id = b.device_id
   AND a.created_at = b.created_at;

CREATE UNIQUE INDEX IF NOT EXISTS idx_points_unique_device_created
    ON points (device_id, created_at);

-- --- fix_diagnostics ---
--
-- Note: we use `fix_timestamp` (CLLocation.timestamp), not `logged_at`
-- (the wall-clock moment the iOS tracker captured the fix), because
-- `logged_at` differs across retries even for the same fix — it's stamped
-- at `logDiagnostic()` call time. `fix_timestamp` is stable per fix.

DELETE FROM fix_diagnostics a
    USING fix_diagnostics b
 WHERE a.ctid < b.ctid
   AND a.device_id = b.device_id
   AND a.fix_timestamp = b.fix_timestamp;

CREATE UNIQUE INDEX IF NOT EXISTS idx_fix_diagnostics_unique_device_fix
    ON fix_diagnostics (device_id, fix_timestamp);
