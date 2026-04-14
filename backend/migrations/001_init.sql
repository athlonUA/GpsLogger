CREATE TABLE IF NOT EXISTS points (
    id          SERIAL PRIMARY KEY,
    latitude    DOUBLE PRECISION NOT NULL,
    longitude   DOUBLE PRECISION NOT NULL,
    created_at  TIMESTAMPTZ      NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_points_created_at ON points (created_at);
