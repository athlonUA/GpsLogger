#!/bin/sh
# OSRM data preparation — idempotent. Downloads a regional OSM extract
# from Geofabrik (default: Spain) and runs the MLD pipeline so
# `osrm-routed` can serve the `/match` endpoint.
#
# The whole thing is a one-time ~15–30 min CPU burn on cold start, hence
# the careful idempotency guard — every subsequent container restart is
# a no-op until the extract is replaced.
set -e

# ------------------------------------------------------------------
# Configuration — everything is overridable at `docker compose up`
# time via environment variables so switching regions or profiles
# doesn't require an image rebuild.
# ------------------------------------------------------------------
DATA_DIR=${OSRM_DATA_DIR:-/data}
REGION_URL=${OSRM_REGION_URL:-https://download.geofabrik.de/europe/spain-latest.osm.pbf}
# `foot.lua` ships with the osrm/osrm-backend image. It is the safe
# default for map-matching a phone trace: routes traversable by a
# pedestrian (sidewalks, footpaths, residential streets) are a strict
# superset of everything we actually want to snap to. Bicycle / car
# profiles can be added by running a second preparation into a
# differently-named .osrm and pointing a second `osrm-routed` at it.
PROFILE=${OSRM_PROFILE:-/opt/foot.lua}

REGION_FILE=$(basename "$REGION_URL")            # e.g. spain-latest.osm.pbf
REGION_NAME=${REGION_FILE%.osm.pbf}              # e.g. spain-latest
PBF_PATH="$DATA_DIR/$REGION_FILE"
OSRM_BASE="$DATA_DIR/$REGION_NAME.osrm"

mkdir -p "$DATA_DIR"

# ------------------------------------------------------------------
# Idempotency guard. `.mldgr` is the last artifact written by
# `osrm-customize`; its presence is a reliable signal that the
# previous preparation ran end-to-end without a crash midway. If a
# build was interrupted, the guard misses and we re-run the whole
# pipeline — which is correct, since a half-prepared dataset would
# cause `osrm-routed` to fail at startup with a less-obvious error.
# ------------------------------------------------------------------
if [ -f "$OSRM_BASE.mldgr" ]; then
    echo "[osrm-prepare] Already prepared at $OSRM_BASE — skipping."
    exit 0
fi

# ------------------------------------------------------------------
# Download the extract if missing. Geofabrik is rate-limited but
# generous; a single Spain-latest (~800 MB) fetch per container
# lifetime is well within any fair-use ceiling. The `-c` flag makes
# the download resumable if the container is killed mid-transfer.
# ------------------------------------------------------------------
if [ ! -f "$PBF_PATH" ]; then
    echo "[osrm-prepare] Downloading $REGION_URL..."
    wget -c -O "$PBF_PATH" "$REGION_URL"
fi

# ------------------------------------------------------------------
# The three-step MLD pipeline. MLD (Multi-Level Dijkstra) is the
# algorithm OSRM recommends for map-matching because it supports
# dynamic edge-weight updates and has better memory behavior than
# CH (Contraction Hierarchies) for trace-replay workloads. The CH
# alternative would be `osrm-contract` instead of partition+customize.
# ------------------------------------------------------------------
echo "[osrm-prepare] osrm-extract..."
osrm-extract -p "$PROFILE" "$PBF_PATH"

echo "[osrm-prepare] osrm-partition..."
osrm-partition "$OSRM_BASE"

echo "[osrm-prepare] osrm-customize..."
osrm-customize "$OSRM_BASE"

echo "[osrm-prepare] Complete. Ready to serve from $OSRM_BASE"
