#!/usr/bin/env bash
# Consolidated reproduction driver; reconstructed, not the lost original.
# MO SF1000 and Dolt SF100 wrappers reuse this file's lifecycle and validity checks.
# PYTHON=/path/to/venv/bin/python ./run_mo_sf100.sh --repo /path/to/branchbench \
#   --configs /path/to/sf100/configs --container mo-benchmark --check
set -euo pipefail
exec "${PYTHON:-python3}" - "$@" <<'PY'
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

parser = argparse.ArgumentParser(description="BranchBench: first rep cold, subsequent reps warm within each workflow")
parser.add_argument("--backend", choices=["MATRIXONE", "DOLT"], default="MATRIXONE")
parser.add_argument("--scale", type=int, choices=[100, 1000], default=100)
parser.add_argument("--repo", type=Path, required=True)
parser.add_argument("--configs", type=Path, required=True)
parser.add_argument("--container", help="Existing dedicated MO container, restarted once per workflow")
parser.add_argument("--seed-db")
parser.add_argument("--sql-dump", type=Path, help="Dolt SF100 dump; runner reloads it for every rep")
parser.add_argument("--output", type=Path)
parser.add_argument("--reps", type=int, default=5)
parser.add_argument("--timeout", type=int, default=14400)
parser.add_argument("--max-runtime-sec", type=int, help="Runner-only runtime cap; defaults to --timeout")
parser.add_argument("--expected-version", default="4.0.0-rc2")
parser.add_argument("--workflows", nargs="+", choices=["software_dev", "failure_repro", "data_cleaning", "mcts", "simulation"],
                    default=["software_dev", "failure_repro", "data_cleaning", "mcts"])
parser.add_argument("--check", action="store_true", help="Generate and validate configs without contacting MO")
args = parser.parse_args()
if args.max_runtime_sec is None:
    args.max_runtime_sec = args.timeout
is_mo = args.backend == "MATRIXONE"
if is_mo and not args.container:
    parser.error("MO requires --container")
if is_mo and args.sql_dump is not None:
    parser.error("MO reuses --seed-db; --sql-dump is for Dolt")
if not is_mo and args.scale != 100:
    parser.error("this Dolt recipe is SF100 only")
args.seed_db = args.seed_db or f"bb_seed_sf{args.scale}"
if args.reps < 1 or args.timeout < 1 or args.max_runtime_sec < 1 or len(set(args.workflows)) != len(args.workflows):
    parser.error("reps/timeout must be positive and workflows must be unique")
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.seed_db):
    parser.error("seed-db must be a SQL identifier")
args.repo = args.repo.resolve()
args.configs = args.configs.resolve()
sys.path.insert(0, str(args.repo))
os.environ["PYTHONPATH"] = str(args.repo) + os.pathsep + os.environ.get("PYTHONPATH", "")
os.environ["PYTHONUNBUFFERED"] = "1"
from google.protobuf import text_format
from macrobench import task_pb2 as tp

system = "mo" if is_mo else "dolt"
token = uuid.uuid4().hex[:12]
tag = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "_" + token
root = (args.output or Path.cwd() / (f"{system}_sf{args.scale}_" + tag)).resolve()
if root.exists() and any(root.iterdir()):
    parser.error("output must be empty; existing results are never overwritten")
configs = []
for workflow in args.workflows:
    template = args.configs / (workflow + "_r1.textproto")
    config = text_format.Parse(template.read_text(), tp.MacroBenchConfig())
    if (config.backend != getattr(tp, args.backend) or tp.WorkflowType.Name(config.workflow).lower() != workflow
            or config.setup.db_scale != args.scale
            or config.setup.workers < 1 or config.setup.total_steps < 1):
        parser.error("invalid backend/scale template: " + str(template))
    if is_mo and config.database_setup.WhichOneof("source") != "existing_db":
        parser.error("MO requires an existing_db template")
    if not is_mo:
        if args.sql_dump is None and config.database_setup.WhichOneof("source") != "sql_dump":
            parser.error("Dolt requires sql_dump, not existing_db")
        dump = args.sql_dump or Path(config.database_setup.sql_dump.sql_dump_path)
        dump = (dump if dump.is_absolute() else args.repo / dump).resolve()
        if not dump.is_file():
            parser.error("Dolt SQL dump does not exist")
        config.database_setup.sql_dump.sql_dump_path = str(dump)
    if workflow == "software_dev" and config.step.schema_changes < 2:
        config.step.schema_changes = 2
    for rep in range(1, args.reps + 1):
        item = tp.MacroBenchConfig()
        item.CopyFrom(config)
        item.run_id = f"{system}_sf{args.scale}_{workflow}_{tag}_r{rep}"
        # Leave space for the backend's branch-name suffix within SQL identifier limits.
        item.database_setup.db_name = f"bb_sf{args.scale}_{workflow}_{token}_r{rep}"
        item.database_setup.cleanup = True
        configs.append((workflow, rep, item))
root.mkdir(parents=True, exist_ok=True)
(root / "configs").mkdir(exist_ok=True)
for workflow, rep, config in configs:
    (root / "configs" / f"{workflow}_r{rep}.textproto").write_text(text_format.MessageToString(config))
if args.check:
    print(f"PASS: {len(configs)} configs validated; no database actions")
    sys.exit(0)

prefix = "MO" if is_mo else "DOLT"
defaults = ("127.0.0.1", "6001", "root") if is_mo else ("127.0.0.1", "5432", "postgres")
host, port, user = [os.environ.setdefault(prefix + "_" + name, value)
                    for name, value in zip(("HOST", "PORT", "USER"), defaults)]
if prefix + "_PASSWORD" not in os.environ:
    parser.error("set " + prefix + "_PASSWORD to the benchmark instance's password")
sql_env = dict(os.environ)
if is_mo:
    sql_client = ["mysql", "--connect-timeout=5", "--batch", "--skip-column-names",
                  "-h", host, "-P", port, "-u", user]
    sql_env["MYSQL_PWD"] = os.environ["MO_PASSWORD"]
else:
    sql_client = ["psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                  "-h", host, "-p", port, "-U", user, "-d", "postgres"]
    sql_env["PGPASSWORD"] = os.environ["DOLT_PASSWORD"]
    sql_env["PGCONNECT_TIMEOUT"] = "5"
driver_log = (root / "driver.log").open("a")

def sql(statement, timeout=300):
    result = subprocess.run(sql_client + ["-e" if is_mo else "-c", statement],
                            env=sql_env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        driver_log.write(result.stderr)
        driver_log.flush()
        raise RuntimeError("SQL failed; see driver.log")
    return result.stdout.strip()

def ready():
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            if sql("SELECT 1", timeout=min(10, max(0.01, deadline - time.monotonic()))) == "1":
                return
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(2)
    raise RuntimeError("SQL endpoint did not become ready")

def stop_child(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()

def cancelled(signum, frame):
    raise KeyboardInterrupt

def records_valid(out, run_id):
    from pyarrow import parquet
    paths = list(out.glob("*.parquet"))
    if len(paths) != 1:
        return False
    try:
        table = parquet.read_table(paths[0], columns=["run_id"])
        return table.num_rows > 0 and set(table.column("run_id").to_pylist()) == {run_id}
    except Exception:
        return False

def log_failed(path):
    with path.open(errors="replace") as stream:
        return any(errors.search(line) for line in stream)

signal.signal(signal.SIGTERM, cancelled)
errors = re.compile(r"(?:Branch create|DDL|DML|Eval|Compare query|Connect|Prune) failed|Worker failed|Cleanup failed after retry|ERROR in flush_record|Traceback \(most recent call last\)")
try:
    ready()
    if is_mo:
        if args.expected_version not in sql("SELECT VERSION()"):
            raise RuntimeError("MO version differs from the requested experiment version")
        counts = sql(f"SELECT (SELECT COUNT(*) FROM `{args.seed_db}`.warehouse), "
                     f"(SELECT COUNT(*) FROM `{args.seed_db}`.order_line)").split()
        if counts != [str(args.scale), str(args.scale * 300000)]:
            raise RuntimeError("seed row counts do not match the requested scale")
    for workflow, rep, config in configs:
        if is_mo and rep == 1:
            subprocess.run(["docker", "restart", args.container], stdout=driver_log, stderr=driver_log, check=True, timeout=180)
            ready()
        db = config.database_setup.db_name
        ready()
        if is_mo:
            if sql(f"SELECT COUNT(*) FROM `{args.seed_db}`.warehouse") != str(args.scale):
                raise RuntimeError("seed warehouse gate failed")
            snap = "bb_snap_" + tag + "_" + workflow + "_r" + str(rep)
            sql(f"CREATE SNAPSHOT `{snap}` FOR DATABASE `{args.seed_db}`; "
                f"CREATE DATABASE `{db}` CLONE `{args.seed_db}` {{SNAPSHOT='{snap}'}}; "
                f"DROP SNAPSHOT `{snap}`;")
        out = root / "results" / f"{workflow}_r{rep}"
        out.mkdir(parents=True)
        logfile = root / f"{workflow}_r{rep}.log"
        command = [sys.executable, "-m", "macrobench.runner", "--config",
                   str(root / "configs" / f"{workflow}_r{rep}.textproto"),
                   "--outdir", str(out), "--max-runtime-sec", str(args.max_runtime_sec)]
        started = time.monotonic()
        timed_out = False
        with logfile.open("w") as log:
            child = subprocess.Popen(command, cwd=args.repo, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
            try:
                rc = child.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                rc = 124
            finally:
                stop_child(child)
        wall = time.monotonic() - started
        files = list(out.glob("*_e2e_stats.json"))
        try:
            stats = json.loads(files[0].read_text()) if len(files) == 1 else {}
        except (OSError, ValueError):
            stats = {}
        if not isinstance(stats, dict):
            stats = {}
        workers = {str(i) for i in range(config.setup.workers)}
        completed = stats.get("completed_steps", {})
        statuses = stats.get("worker_status", {})
        elapsed = stats.get("elapsed_sec")
        valid = (rc == 0 and not timed_out and stats.get("timed_out") is False
                 and stats.get("run_id") == config.run_id and set(completed) == workers
                 and all(completed[i] == config.setup.total_steps for i in workers)
                 and set(statuses) == workers and all(statuses[i] == "completed" for i in workers)
                 and type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed > 0
                 and records_valid(out, config.run_id) and not log_failed(logfile))
        cleanup_ok = None
        if is_mo and valid:
            # Clean only databases owned by this unique run, never another run or the seed.
            try:
                for name in sql("SHOW DATABASES").splitlines():
                    if name == db or name.startswith(db + "_br_"):
                        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                            raise RuntimeError("unexpected database identifier in cleanup")
                        sql(f"DROP DATABASE IF EXISTS `{name}`")
                cleanup_ok = True
            except Exception as error:
                driver_log.write(f"Cleanup failed: {type(error).__name__}: {error}\n")
                driver_log.flush()
                cleanup_ok = False
                valid = False
        row = dict(workflow=workflow, rep=rep, phase="cold" if rep == 1 else "warm",
                   backend=args.backend, scale=args.scale, rc=rc, elapsed_sec=elapsed,
                   wall_sec=wall, valid=valid, cleanup_ok=cleanup_ok)
        with (root / "summary.jsonl").open("a") as summary:
            summary.write(json.dumps(row) + "\n")
        print(f"{'PASS' if valid else 'FAIL'}: {workflow} r{rep}", flush=True)
        if not valid:
            raise RuntimeError("invalid sample; result and remaining run objects are retained for inspection")
except KeyboardInterrupt:
    print("FAIL: interrupted; evidence retained", file=sys.stderr)
    sys.exit(130)
except Exception as error:
    driver_log.write(f"{type(error).__name__}: {error}\n")
    driver_log.flush()
    print("FAIL: see driver.log and per-run evidence", file=sys.stderr)
    sys.exit(1)
finally:
    driver_log.close()
PY
