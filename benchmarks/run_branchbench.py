#!/usr/bin/env python3
"""Run the pinned BranchBench implementation on a dedicated database container."""

import argparse
import hashlib
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


HERE = Path(__file__).resolve().parent
SOURCE_COMMIT = "95c18b7bf7a51029e3344a65e807df07aa28a2ea"
MO_RELEASE = "4.2.5"
WORKFLOWS = ("software_dev", "failure_repro", "data_cleaning", "mcts", "simulation")
SCALES = {"smoke": (10, 10), "100": (100, 30_000_000), "1000": (1000, 300_000_000)}
TABLES = ("warehouse", "district", "customer", "item", "stock", "orders", "new_order", "order_line")


def identifier(value):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise argparse.ArgumentTypeError("expected a SQL identifier")
    return value


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_source(repo):
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    patch = subprocess.check_output(["git", "-C", str(repo), "diff", "--cached", "--binary", "--unified=0"])
    dirty = subprocess.check_output(["git", "-C", str(repo), "diff", "--name-only"])
    if head != SOURCE_COMMIT or patch != (HERE / "branchbench.patch").read_bytes() or dirty:
        raise RuntimeError("runner differs from the pinned source; run prepare_branchbench.sh in a new directory")


def version_matches(actual, expected):
    return re.search(r"(?<![\d.])" + re.escape(expected) + r"(?![\d.])", actual) is not None


def connection(backend, timeout=300, database=None):
    prefix = "MO" if backend == "MATRIXONE" else "DOLT"
    defaults = ("127.0.0.1", "6001", "root") if prefix == "MO" else ("127.0.0.1", "5432", "postgres")
    host, port, user = [os.environ.setdefault(prefix + "_" + key, value)
                        for key, value in zip(("HOST", "PORT", "USER"), defaults)]
    password = os.environ.get(prefix + "_PASSWORD")
    if password is None:
        raise RuntimeError("set " + prefix + "_PASSWORD for the dedicated instance")
    if backend == "MATRIXONE":
        import pymysql
        return pymysql.connect(host=host, port=int(port), user=user, password=password,
                               database=database, autocommit=True, connect_timeout=5,
                               read_timeout=timeout, write_timeout=timeout)
    import psycopg2
    conn = psycopg2.connect(host=host, port=int(port), user=user, password=password,
                            dbname=database or "postgres", connect_timeout=5)
    conn.autocommit = True
    return conn


def query(backend, statement, timeout=300):
    conn = connection(backend, timeout)
    try:
        with conn.cursor() as cur:
            cur.execute(statement)
            return cur.fetchall() if cur.description else []
    finally:
        conn.close()


def inspect_container(name):
    result = subprocess.run(["docker", "inspect", name], capture_output=True, text=True,
                            check=True, timeout=15)
    items = json.loads(result.stdout)
    if len(items) != 1:
        raise RuntimeError("expected exactly one dedicated container")
    return items[0]


def check_container_endpoint(info, backend):
    prefix = "MO" if backend == "MATRIXONE" else "DOLT"
    host = os.environ.get(prefix + "_HOST", "127.0.0.1")
    port = os.environ.get(prefix + "_PORT", "6001" if prefix == "MO" else "5432")
    if host not in ("127.0.0.1", "localhost"):
        raise RuntimeError("run this driver on the database host with a local endpoint")
    if info["HostConfig"]["NetworkMode"] == "host":
        return
    key = "6001/tcp" if prefix == "MO" else "5432/tcp"
    bindings = info["NetworkSettings"]["Ports"].get(key) or []
    if not any(item["HostPort"] == port for item in bindings):
        raise RuntimeError("container port does not match the selected SQL endpoint")


def ready(backend, max_wait=300):
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        try:
            result = query(backend, "SELECT 1", timeout=5)
            if result and result[0] == (1,):
                return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("SQL endpoint did not become ready")


def stop_child(child):
    # The runner may have a psql child; terminate the entire owned process group.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()


def run_process(command, repo, log_path, timeout):
    started = time.monotonic()
    timed_out = False
    with log_path.open("w") as log:
        child = subprocess.Popen(command, cwd=repo, stdout=log, stderr=log,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out, code = True, 124
        finally:
            if child.poll() is None or timed_out:
                stop_child(child)
    return code, timed_out, time.monotonic() - started


def render_configs(args, tp, text_format, tag):
    configs = []
    for workflow in args.workflows:
        source = args.configs / (workflow + ".textproto")
        config = text_format.Parse(source.read_text(), tp.MacroBenchConfig())
        if tp.WorkflowType.Name(config.workflow).lower() != workflow:
            raise RuntimeError("workflow differs from its template")
        config.backend = getattr(tp, args.backend)
        config.setup.db_scale = 0 if args.scale == "smoke" else int(args.scale)
        if args.scale == "smoke":
            config.setup.workers = 2 if workflow in ("data_cleaning", "simulation") else 1
            config.setup.total_steps = 1
            config.setup.root_fanout = config.setup.workers
        if args.workers is not None:
            config.setup.workers = args.workers
            if workflow == "simulation":
                config.setup.root_fanout = args.workers
        if args.steps is not None:
            config.setup.total_steps = args.steps
        if min(config.setup.workers, config.setup.total_steps) < 1:
            raise RuntimeError("workers and steps must be positive")
        if workflow == "software_dev":
            config.step.schema_changes = max(2, config.step.schema_changes)
        for rep in range(1, args.reps + 1):
            item = tp.MacroBenchConfig()
            item.CopyFrom(config)
            item.run_id = f"{args.backend.lower()}_{args.scale}_{workflow}_{tag}_r{rep}"
            item.database_setup.db_name = f"bb_{workflow}_{tag[-12:]}_r{rep}"
            item.database_setup.cleanup = True
            item.database_setup.ClearField("source")
            if args.backend == "MATRIXONE":
                item.database_setup.existing_db.branch_id = "main"
            else:
                item.database_setup.sql_dump.sql_dump_path = str(args.sql_dump)
            configs.append((workflow, rep, item))
    return configs


def validate_result(out, config):
    from pyarrow import parquet
    files = list(out.glob("*_e2e_stats.json"))
    stats = json.loads(files[0].read_text()) if len(files) == 1 else {}
    if not isinstance(stats, dict):
        return False, {}, ["malformed_stats"]
    expected = {str(i) for i in range(config.setup.workers)}
    completed = stats.get("completed_steps", {})
    statuses = stats.get("worker_status", {})
    elapsed = stats.get("elapsed_sec")
    valid = (stats.get("run_valid") is True and stats.get("timed_out") is False
             and stats.get("run_id") == config.run_id
             and stats.get("workers") == config.setup.workers
             and stats.get("total_steps") == config.setup.total_steps
             and stats.get("total_operation_errors") == 0
             and isinstance(completed, dict) and set(completed) == expected
             and all(completed[i] == config.setup.total_steps for i in expected)
             and isinstance(statuses, dict) and set(statuses) == expected
             and all(statuses[i] == "completed" for i in expected)
             and type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0)
    records = list(out.glob("*.parquet"))
    if len(records) != 1:
        valid = False
    else:
        table = parquet.read_table(records[0], columns=["run_id"])
        valid &= table.num_rows > 0 and set(table.column("run_id").to_pylist()) == {config.run_id}
    return valid, stats, [] if valid else ["result_validation"]


def log_failed(path):
    errors = re.compile(r"ERROR in flush_record|Traceback \(most recent call last\)|Error deleting database|Dolt schema commit failed")
    with path.open(errors="replace") as stream:
        return any(errors.search(line) for line in stream)


def seed_gate(seed_db, scale):
    tables = {str(row[0]) for row in query("MATRIXONE", f"SHOW TABLES FROM `{seed_db}`")}
    if not set(TABLES).issubset(tables):
        raise RuntimeError("seed is missing workflow tables")
    counts = query("MATRIXONE", f"SELECT (SELECT COUNT(*) FROM `{seed_db}`.warehouse), "
                   f"(SELECT COUNT(*) FROM `{seed_db}`.order_line)")[0]
    if tuple(int(n) for n in counts) != SCALES[scale]:
        raise RuntimeError("seed row counts do not match the selected scale")


def clone_seed(db, seed_db, snapshot):
    conn = connection("MATRIXONE")
    try:
        # Keep the catalog write and its immediate reads in one session.
        with conn.cursor() as cur:
            cur.execute(f"CREATE SNAPSHOT `{snapshot}` FOR DATABASE `{seed_db}`")
            try:
                cur.execute(f"CREATE DATABASE `{db}` CLONE `{seed_db}` {{SNAPSHOT='{snapshot}'}}")
            except Exception:
                try:
                    cur.execute(f"DROP SNAPSHOT IF EXISTS `{snapshot}`")
                except Exception:
                    pass
                raise
            cur.execute(f"DROP SNAPSHOT `{snapshot}`")
    finally:
        conn.close()


def cleanup_owned(db, seed_db):
    for row in query("MATRIXONE", "SHOW DATABASES"):
        name = str(row[0])
        if name != seed_db and (name == db or name.startswith(db + "_br_")):
            identifier(name)
            query("MATRIXONE", f"DROP DATABASE IF EXISTS `{name}`")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["MATRIXONE", "DOLT"], default="MATRIXONE",
                        help="DOLT is the PostgreSQL-protocol DoltgreSQL backend")
    parser.add_argument("--scale", choices=SCALES, default="100")
    parser.add_argument("--repo", type=Path, default=HERE / ".runtime" / "branchbench")
    parser.add_argument("--configs", type=Path, default=HERE / "configs")
    parser.add_argument("--container", help="Existing dedicated container; restarted at each workflow's r1")
    parser.add_argument("--seed-db", type=identifier)
    parser.add_argument("--sql-dump", type=Path, help="DoltgreSQL dump; reloaded for each rep")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--reps", type=int, default=5)
    parser.add_argument("--timeout", type=int, default=14400, help="Hard cap on the complete runner process")
    parser.add_argument("--max-runtime-sec", type=int, help="Worker-only runtime cap")
    parser.add_argument("--expected-version", default=MO_RELEASE)
    parser.add_argument("--workers", type=int)
    parser.add_argument("--steps", type=int)
    parser.add_argument("--workflows", nargs="+", choices=WORKFLOWS, default=list(WORKFLOWS[:-1]))
    parser.add_argument("--check", action="store_true", help="Generate configs without database or container actions")
    args = parser.parse_args(argv)
    if args.max_runtime_sec is None:
        args.max_runtime_sec = args.timeout
    numbers = [args.reps, args.timeout, args.max_runtime_sec]
    numbers += [n for n in (args.workers, args.steps) if n is not None]
    if min(numbers) < 1 or len(set(args.workflows)) != len(args.workflows):
        parser.error("positive limits and unique workflows are required")
    if not args.check and not args.container:
        parser.error("--container must name a dedicated instance")
    if args.backend == "DOLT":
        if args.sql_dump is None or not args.sql_dump.is_file():
            parser.error("DoltgreSQL requires --sql-dump")
        args.sql_dump = args.sql_dump.resolve()
    elif args.sql_dump is not None:
        parser.error("MO uses --seed-db; load it with load_seed.py first")
    args.repo, args.configs = args.repo.resolve(), args.configs.resolve()
    args.seed_db = args.seed_db or "bb_seed_sf" + args.scale
    verify_source(args.repo)
    sys.path.insert(0, str(args.repo))
    os.environ["PYTHONPATH"] = str(args.repo)
    os.environ["PYTHONUNBUFFERED"] = "1"
    os.environ["MO_QUERY_TIMEOUT_SEC"] = str(min(args.max_runtime_sec, args.timeout))
    from google.protobuf import text_format
    from macrobench import task_pb2 as tp
    tag = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "_" + uuid.uuid4().hex[:12]
    root = (args.output or HERE / "results" / (args.backend.lower() + "_sf" + args.scale + "_" + tag)).resolve()
    if root.exists() and any(root.iterdir()):
        parser.error("output must be empty")
    configs = render_configs(args, tp, text_format, tag)
    root.mkdir(parents=True, exist_ok=True)
    (root / "configs").mkdir()
    for workflow, rep, config in configs:
        (root / "configs" / f"{workflow}_r{rep}.textproto").write_text(text_format.MessageToString(config))
    if args.check:
        print(f"PASS: {len(configs)} configs; no database actions")
        return 0
    log_path = root / "driver.log"
    with log_path.open("a") as driver_log:
        try:
            info = inspect_container(args.container)
            check_container_endpoint(info, args.backend)
            ready(args.backend)
            version = str(query(args.backend, "SELECT VERSION()")[0][0])
            if args.backend == "MATRIXONE":
                if not version_matches(version, args.expected_version):
                    raise RuntimeError("MO version differs from --expected-version")
                seed_gate(args.seed_db, args.scale)
            metadata = {"source_commit": SOURCE_COMMIT, "source_patch_sha256": sha256(HERE / "branchbench.patch"),
                        "backend": "MatrixOne" if args.backend == "MATRIXONE" else "DoltgreSQL",
                        "server_version": version, "expected_mo_version": args.expected_version,
                        "container_image_id": info["Image"], "container_image": info["Config"]["Image"],
                        "sql_dump_sha256": sha256(args.sql_dump) if args.sql_dump else None}
            (root / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
            for workflow, rep, config in configs:
                rep_started = time.monotonic()
                if rep == 1:
                    subprocess.run(["docker", "restart", args.container], stdout=driver_log,
                                   stderr=driver_log, check=True, timeout=180)
                    ready(args.backend)
                db = config.database_setup.db_name
                if args.backend == "MATRIXONE":
                    if query(args.backend, f"SELECT COUNT(*) FROM `{args.seed_db}`.warehouse")[0][0] != SCALES[args.scale][0]:
                        raise RuntimeError("seed warehouse gate failed")
                    clone_seed(db, args.seed_db, "bb_snap_" + tag[-12:] + "_" + workflow + "_r" + str(rep))
                out = root / "results" / f"{workflow}_r{rep}"
                out.mkdir(parents=True)
                logfile = root / f"{workflow}_r{rep}.log"
                command = [sys.executable, "-m", "macrobench.runner", "--config",
                           str(root / "configs" / f"{workflow}_r{rep}.textproto"), "--outdir", str(out),
                           "--strict-operations", "--no-progress", "--max-runtime-sec", str(args.max_runtime_sec)]
                rc, timed_out, wall = run_process(command, args.repo, logfile, args.timeout)
                valid, stats, reasons = False, {}, []
                try:
                    valid, stats, reasons = validate_result(out, config)
                except Exception as error:
                    reasons = ["result_read_failure"]
                    driver_log.write(f"{type(error).__name__}: {error}\n")
                valid &= rc == 0 and not timed_out
                if rc != 0:
                    reasons.append("runner_exit")
                if timed_out:
                    reasons.append("hard_timeout")
                if log_failed(logfile):
                    valid = False
                    reasons.append("runner_log_error")
                cleanup_ok = False
                if valid:
                    try:
                        if not inspect_container(args.container)["State"]["Running"]:
                            raise RuntimeError("container exited after runner completion")
                        if not query(args.backend, "SELECT 1", timeout=10):
                            raise RuntimeError("database unhealthy after runner completion")
                        if args.backend == "MATRIXONE":
                            cleanup_owned(db, args.seed_db)
                        cleanup_ok = True
                    except Exception as error:
                        valid = False
                        reasons.append("health_or_cleanup")
                        driver_log.write(f"{type(error).__name__}: {error}\n")
                row = {"workflow": workflow, "rep": rep, "phase": "cold" if rep == 1 else "warm",
                       "backend": metadata["backend"], "scale": args.scale, "rc": rc,
                       "elapsed_sec": stats.get("elapsed_sec"), "wall_sec": wall,
                       "rep_wall_sec": time.monotonic() - rep_started,
                       "workers": config.setup.workers, "steps_per_worker": config.setup.total_steps,
                       "valid": bool(valid), "cleanup_ok": cleanup_ok, "invalid_reasons": reasons}
                with (root / "summary.jsonl").open("a") as summary:
                    summary.write(json.dumps(row) + "\n")
                print(f"{'PASS' if valid else 'FAIL'}: {workflow} r{rep}", flush=True)
                if not valid:
                    raise RuntimeError("invalid sample; stop and retain evidence and remaining run objects")
        except (Exception, KeyboardInterrupt) as error:
            driver_log.write(f"{type(error).__name__}: {error}\n")
            print("FAIL: see driver.log and per-run evidence", file=sys.stderr)
            return 130 if isinstance(error, KeyboardInterrupt) else 1
    return 0


if __name__ == "__main__":
    def cancelled(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, cancelled)
    raise SystemExit(main())
