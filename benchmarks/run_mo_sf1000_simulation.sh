#!/usr/bin/env bash
# Use a dedicated MatrixOne 4.2.5 instance with an SF1000 seed already loaded.
# Cold r1 restarts once; warm reps do not restart. Provisioning/seed load are separate.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "${PYTHON:-$SCRIPT_DIR/.runtime/branchbench/.venv/bin/python}" \
    "$SCRIPT_DIR/run_branchbench.py" --reps 5 --timeout 57600 "$@" \
    --backend MATRIXONE --scale 1000 --workflows simulation
