#!/usr/bin/env bash
# Prepare one pinned runner for both MatrixOne and DoltgreSQL.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=${1:-"$SCRIPT_DIR/.runtime/branchbench"}
PYTHON_BIN=${PYTHON:-python3}
COMMIT=95c18b7bf7a51029e3344a65e807df07aa28a2ea
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
if [[ -e "$REPO" ]]; then
    echo "FAIL: destination already exists; choose a new runner directory" >&2
    exit 1
fi
mkdir -p "$(dirname "$REPO")"
LOG="${REPO}.prepare.log"
exec 3>&2
trap 'echo "FAIL: preparation incomplete; see $LOG" >&3' ERR
{
    git clone --quiet https://github.com/dengn/matrixone-branchbench.git "$REPO"
    git -C "$REPO" checkout --quiet --detach "$COMMIT"
    git -C "$REPO" apply --index --unidiff-zero "$SCRIPT_DIR/branchbench.patch"
    "$PYTHON_BIN" -m venv "$REPO/.venv"
    "$REPO/.venv/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"
    "$REPO/.venv/bin/python" -m grpc_tools.protoc -I "$REPO" --python_out="$REPO" \
        "$REPO/dblib/result.proto" "$REPO/microbench/task.proto" \
        "$REPO/microbench/task2.proto" "$REPO/macrobench/task.proto"
    # The caller may itself contain old dblib/macrobench packages.
    (
        cd "$REPO"
        PYTHONPATH="$PWD" "$PWD/.venv/bin/python" -c \
            'from macrobench import runner; from dblib.dolt import DoltToolSuite; from dblib.matrixone import MoToolSuite'
    )
} > "$LOG" 2>&1
trap - ERR
echo "PASS: pinned runner prepared at $REPO"
echo "PYTHON=$REPO/.venv/bin/python"
