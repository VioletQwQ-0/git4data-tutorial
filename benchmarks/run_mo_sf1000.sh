#!/usr/bin/env bash
# Preload bb_seed_sf1000 on the dedicated MatrixOne 4.2.5 instance.
# Four workflows by default; simulation has its own entry point.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "${PYTHON:-$SCRIPT_DIR/.runtime/branchbench/.venv/bin/python}" \
    "$SCRIPT_DIR/run_branchbench.py" --reps 5 --timeout 14400 "$@" --backend MATRIXONE --scale 1000
