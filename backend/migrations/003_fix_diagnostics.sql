-- Debug/observability table: every raw CLLocation that enters the tracker
-- pipeline on an iPhone is uploaded here together with the filter decision.
-- Used for post-hoc classification of GPS anomalies (GNSS vs network
-- fallback vs sensor-fusion drift) — the iOS `points` table cannot answer
-- "what did CoreLocation actually hand us" because it only stores lat/lng.
--
-- Schema notes:
--   - `logged_at` is the wall-clock moment the iOS tracker captured the fix
--     (so retention and "what was the device doing at time T" queries use
--     a monotonic client clock, independent of CLLocation.timestamp quirks).
--   - `fix_timestamp` is `CLLocation.timestamp` — the authoritative sample
--     time CoreLocation reports, which can lag wall-clock during cached-fix
--     replays and is the right field to correlate with a user-reported
--     incident window.
--   - Raw CLLocation fields are stored verbatim. Negative values are
--     legitimate and meaningful here: Apple's sentinel for "no data"
--     (e.g. `speed = -1`, `verticalAccuracy = -1`) is exactly what we need
--     to see when classifying network-origin fixes.
--   - `decision` is the LocationFilter verdict tag
--     (accept / buffered / spikeReplaced / committedPending /
--      discard:invalidFix / discard:nonGpsSource / …).
--   - Primary query pattern: `WHERE device_id = ? AND fix_timestamp BETWEEN
--     ? AND ? ORDER BY fix_timestamp ASC`. The composite index covers it.

CREATE TABLE IF NOT EXISTS fix_diagnostics (
    id                  SERIAL PRIMARY KEY,
    logged_at           TIMESTAMPTZ      NOT NULL,
    fix_timestamp       TIMESTAMPTZ      NOT NULL,
    latitude            DOUBLE PRECISION NOT NULL,
    longitude           DOUBLE PRECISION NOT NULL,
    horizontal_accuracy DOUBLE PRECISION NOT NULL,
    vertical_accuracy   DOUBLE PRECISION NOT NULL,
    altitude            DOUBLE PRECISION NOT NULL,
    speed               DOUBLE PRECISION NOT NULL,
    speed_accuracy      DOUBLE PRECISION NOT NULL,
    course              DOUBLE PRECISION NOT NULL,
    course_accuracy     DOUBLE PRECISION NOT NULL,
    decision            TEXT             NOT NULL,
    device_id           TEXT             NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_fix_diagnostics_device_fix_timestamp
    ON fix_diagnostics (device_id, fix_timestamp);
