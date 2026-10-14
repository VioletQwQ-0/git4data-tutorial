#!/usr/bin/env bash
# Dedicated Doltgres endpoint: DOLT_HOST/DOLT_PORT/DOLT_USER/DOLT_PASSWORD.
# --repo, --configs and --sql-dump select the runner, templates and SF100 dump.
# Every rep reloads the dump; r1 is cold, later reps reuse the running server.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/run_mo_sf100.sh" --reps 4 --timeout 14400 --max-runtime-sec 7200 "$@" --backend DOLT --scale 100
