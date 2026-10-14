#!/usr/bin/env bash
# Preload bb_seed_sf1000 on the dedicated patched MO instance.
# --repo, --configs, --container and MO_* select the actual environment.
# Four workflows by default; simulation has its own entry point.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/run_mo_sf100.sh" --reps 5 --timeout 14400 "$@" --backend MATRIXONE --scale 1000
