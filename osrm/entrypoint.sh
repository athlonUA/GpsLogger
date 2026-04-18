#!/bin/sh
# OSRM container entrypoint. Runs the (idempotent) preparation once,
# then exec's `osrm-routed` to serve the match API.
#
# Rationale for the combined entrypoint rather than two sidecar
# containers: the prepared `.osrm.*` fileset is the only state passed
# from build to runtime. Keeping them in the same container image +
# shared volume avoids a second orchestration layer (init container
# that must finish before the serving container boots) and keeps
# `docker compose up` self-contained.
set -e

DATA_DIR=${OSRM_DATA_DIR:-/data}
REGION_URL=${OSRM_REGION_URL:-https://download.geofabrik.de/europe/spain-latest.osm.pbf}
REGION_FILE=$(basename "$REGION_URL")
REGION_NAME=${REGION_FILE%.osm.pbf}
OSRM_BASE="$DATA_DIR/$REGION_NAME.osrm"

sh /usr/local/bin/osrm-prepare.sh

echo "[osrm] starting osrm-routed on $OSRM_BASE (algorithm=mld)"
# `--max-matching-size` raises the per-request waypoint ceiling from
# the default 100 to 1000. We still batch on the backend by time-gap
# (≥ 5 min → new batch) so a long day of tracking fans out into
# per-trip OSRM calls, but inside one trip we want to send the whole
# sequence so the HMM can pick the globally most-likely path rather
# than stitching short windows with stale state at the seams.
exec osrm-routed --algorithm mld --max-matching-size 1000 --ip 0.0.0.0 --port 5000 "$OSRM_BASE"
