#!/usr/bin/env bash
# Use an existing patched MO instance with an SF1000 seed already loaded.
# The historical successful run used the PR #25135 build at 56260bd589fe.
# Cold r1 restarts once; warm reps do not restart. Provisioning/seed load are separate.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/run_mo_sf100.sh" --reps 5 --timeout 57600 "$@" \
    --backend MATRIXONE --scale 1000 --workflows simulation
