#!/usr/bin/env bash
# MatrixOne 4.2.5: four workflows, one cold plus four warm reps.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "${PYTHON:-$SCRIPT_DIR/.runtime/branchbench/.venv/bin/python}" \
    "$SCRIPT_DIR/run_branchbench.py" --reps 5 "$@" --backend MATRIXONE --scale 100
