#!/usr/bin/env bash
# Dedicated DoltgreSQL endpoint: DOLT_HOST/DOLT_PORT/DOLT_USER/DOLT_PASSWORD.
# Every rep reloads the dump; r1 restarts the dedicated container.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "${PYTHON:-$SCRIPT_DIR/.runtime/branchbench/.venv/bin/python}" \
    "$SCRIPT_DIR/run_branchbench.py" --reps 4 --timeout 14400 --max-runtime-sec 7200 "$@" --backend DOLT --scale 100
