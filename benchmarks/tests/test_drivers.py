import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
REPO = Path(os.environ.get("BB_REPO", HERE / ".runtime" / "branchbench")).resolve()
sys.path[:0] = [str(HERE), str(REPO)]
import run_branchbench as bb
import load_seed
from google.protobuf import text_format
from macrobench import task_pb2 as tp
from macrobench.validation import summarize_run_validity
from pyarrow import Table, parquet


def args(**overrides):
    data = dict(backend="MATRIXONE", scale="100", configs=HERE / "configs", workers=None,
                steps=None, reps=2, workflows=list(bb.WORKFLOWS), sql_dump=Path("/tmp/dump.sql"))
    return SimpleNamespace(**(data | overrides))


def write_result(out, config, **overrides):
    workers = config.setup.workers
    stats = dict(run_id=config.run_id, workers=workers, total_steps=config.setup.total_steps,
                 elapsed_sec=0.25, timed_out=False, run_valid=True, total_operation_errors=0,
                 completed_steps={str(i): config.setup.total_steps for i in range(workers)},
                 worker_status={str(i): "completed" for i in range(workers)})
    stats.update(overrides)
    (out / (config.run_id + "_e2e_stats.json")).write_text(json.dumps(stats))
    parquet.write_table(Table.from_pydict({"run_id": [config.run_id]}), out / "result.parquet")


class DriverTests(unittest.TestCase):
    def test_release_version_is_exact(self):
        self.assertTrue(bb.version_matches("8.0.30-MatrixOne-v4.2.5", "4.2.5"))
        self.assertFalse(bb.version_matches("4.2.50", "4.2.5"))
        self.assertFalse(bb.version_matches("4.2.4", "4.2.5"))

    def test_source_is_pinned_and_patched(self):
        bb.verify_source(REPO)

    def test_source_drift_is_rejected(self):
        with patch.object(bb.subprocess, "check_output", side_effect=["wrong", b"", b""]):
            with self.assertRaises(RuntimeError):
                bb.verify_source(REPO)

    def test_full_profile_preserves_original_parameters(self):
        configs = bb.render_configs(args(reps=1), tp, text_format, "stamp_123456789abc")
        expected = {"software_dev": (5, 20), "failure_repro": (1, 10),
                    "data_cleaning": (10, 20), "mcts": (10, 100), "simulation": (1000, 1)}
        for name, _, config in configs:
            self.assertEqual((config.setup.workers, config.setup.total_steps), expected[name])
            self.assertEqual(config.database_setup.WhichOneof("source"), "existing_db")

    def test_smoke_is_seven_worker_steps(self):
        configs = bb.render_configs(args(scale="smoke", reps=1), tp, text_format, "stamp_123456789abc")
        self.assertEqual(sum(c.setup.workers * c.setup.total_steps for _, _, c in configs), 7)
        self.assertTrue(all(c.setup.db_scale == 0 for _, _, c in configs))

    def test_scale_does_not_change_workflow_shape(self):
        a = bb.render_configs(args(scale="100", reps=1), tp, text_format, "stamp_123456789abc")
        b = bb.render_configs(args(scale="1000", reps=1), tp, text_format, "stamp_123456789abc")
        self.assertEqual([(c.setup.workers, c.setup.total_steps) for _, _, c in a],
                         [(c.setup.workers, c.setup.total_steps) for _, _, c in b])
        self.assertTrue(all(c.setup.db_scale == 1000 for _, _, c in b))

    def test_software_dev_has_both_schema_changes(self):
        config = bb.render_configs(args(workflows=["software_dev"]), tp, text_format, "stamp_123456789abc")[0][2]
        self.assertEqual(config.step.schema_changes, 2)

    def test_simulation_worker_override_updates_fanout(self):
        config = bb.render_configs(args(workflows=["simulation"], workers=50), tp, text_format, "stamp_123456789abc")[0][2]
        self.assertEqual((config.setup.workers, config.setup.root_fanout), (50, 50))

    def test_dolt_uses_sql_dump(self):
        config = bb.render_configs(args(backend="DOLT"), tp, text_format, "stamp_123456789abc")[0][2]
        self.assertEqual(config.backend, tp.DOLT)
        self.assertEqual(config.database_setup.WhichOneof("source"), "sql_dump")

    def test_errors_on_nonzero_worker_are_invalid(self):
        work = {0: dict(steps=1, status="completed", operation_errors={}),
                1: dict(steps=1, status="completed", operation_errors={"dml": 1})}
        validity = summarize_run_validity(work, 2, 1, False)
        self.assertFalse(validity["valid"])
        self.assertEqual(validity["total_operation_errors"], 1)

    def fixture(self, root):
        return bb.render_configs(args(scale="smoke", workflows=["simulation"], reps=1),
                                 tp, text_format, "stamp_123456789abc")[0][2]

    def test_complete_result_is_valid(self):
        with tempfile.TemporaryDirectory() as root:
            out, config = Path(root), self.fixture(root)
            write_result(out, config)
            self.assertTrue(bb.validate_result(out, config)[0])

    def test_completed_steps_do_not_hide_sql_errors(self):
        with tempfile.TemporaryDirectory() as root:
            out, config = Path(root), self.fixture(root)
            write_result(out, config, total_operation_errors=1)
            self.assertFalse(bb.validate_result(out, config)[0])

    def test_missing_worker_is_invalid(self):
        with tempfile.TemporaryDirectory() as root:
            out, config = Path(root), self.fixture(root)
            write_result(out, config, completed_steps={"0": 1})
            self.assertFalse(bb.validate_result(out, config)[0])

    def test_stale_parquet_is_invalid(self):
        with tempfile.TemporaryDirectory() as root:
            out, config = Path(root), self.fixture(root)
            write_result(out, config)
            parquet.write_table(Table.from_pydict({"run_id": ["old"]}), out / "result.parquet")
            self.assertFalse(bb.validate_result(out, config)[0])

    def test_empty_parquet_is_invalid(self):
        with tempfile.TemporaryDirectory() as root:
            out, config = Path(root), self.fixture(root)
            write_result(out, config)
            parquet.write_table(Table.from_pydict({"run_id": []}), out / "result.parquet")
            self.assertFalse(bb.validate_result(out, config)[0])

    def test_container_endpoint_must_match(self):
        info = {"HostConfig": {"NetworkMode": "bridge"}, "NetworkSettings": {"Ports": {"6001/tcp": [{"HostPort": "6001"}]}}}
        with patch.dict(os.environ, MO_HOST="127.0.0.1", MO_PORT="6002"):
            with self.assertRaises(RuntimeError):
                bb.check_container_endpoint(info, "MATRIXONE")

    def test_cleanup_does_not_match_other_runs_or_seed(self):
        seen = []
        def query(backend, sql, **kwargs):
            seen.append(sql)
            return [("mine",), ("mine_br_a",), ("mine0",), ("seed",), ("other",)] if sql == "SHOW DATABASES" else []
        with patch.object(bb, "query", side_effect=query):
            bb.cleanup_owned("mine", "seed")
        self.assertEqual(seen[1:], ["DROP DATABASE IF EXISTS `mine`", "DROP DATABASE IF EXISTS `mine_br_a`"])

    def test_snapshot_clone_uses_one_session(self):
        conn = unittest.mock.MagicMock()
        with patch.object(bb, "connection", return_value=conn) as connect:
            bb.clone_seed("mine", "seed", "snapshot")
        connect.assert_called_once_with("MATRIXONE")
        self.assertEqual(conn.cursor.return_value.__enter__.return_value.execute.call_count, 3)
        conn.close.assert_called_once()

    def test_hard_timeout_terminates_runner(self):
        with tempfile.TemporaryDirectory() as root:
            rc, timeout, wall = bb.run_process([sys.executable, "-c", "import time; time.sleep(30)"],
                                               root, Path(root) / "run.log", 0.1)
            self.assertEqual(rc, 124)
            self.assertTrue(timeout)
            self.assertLess(wall, 5)

    def test_timeout_also_terminates_child_process(self):
        with tempfile.TemporaryDirectory() as root:
            pidfile = Path(root) / "child.pid"
            code = "import pathlib,subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); pathlib.Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(30)"
            bb.run_process([sys.executable, "-c", code, str(pidfile)], root, Path(root) / "run.log", 0.5)
            pid = int(pidfile.read_text())
            result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            self.assertTrue(not result.stdout.strip() or result.stdout.lstrip().startswith("Z"))

    def test_interrupt_terminates_process_group(self):
        child = unittest.mock.Mock()
        child.wait.side_effect = KeyboardInterrupt
        child.poll.return_value = None
        with tempfile.TemporaryDirectory() as root, patch.object(bb.subprocess, "Popen", return_value=child), patch.object(bb, "stop_child") as stop:
            with self.assertRaises(KeyboardInterrupt):
                bb.run_process([], root, Path(root) / "run.log", 1)
            stop.assert_called_once_with(child)

    def test_seed_batches_cover_each_warehouse_once(self):
        statements = list(load_seed.seed_statements("100", batch=3))
        inserts = [s for s in statements if s.startswith("INSERT INTO order_line")]
        covered = []
        for sql in inserts:
            low, high = map(int, re.search(r"w >= (\d+) AND w < (\d+)", sql).groups())
            self.assertLessEqual(high - low, 3)
            covered.extend(range(low, high))
        self.assertEqual(covered, list(range(1, 101)))

    def test_seed_counts_match_sf100_and_sf1000(self):
        self.assertEqual(load_seed.expected_counts("100")["order_line"], 30_000_000)
        self.assertEqual(load_seed.expected_counts("1000")["order_line"], 300_000_000)
        self.assertEqual(load_seed.expected_counts("1000")["stock"], 100_000_000)

    def test_dolt_dump_uses_postgres_timestamps(self):
        sql = "\n".join(load_seed.seed_statements("smoke", dialect="dolt"))
        self.assertNotIn("DATETIME", sql)
        self.assertIn("TIMESTAMP", sql)

    def test_sql_dump_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "dump.sql"
            target.write_text("existing")
            with self.assertRaises(FileExistsError):
                load_seed.main(["--scale", "smoke", "--write-sql", str(target)])
            self.assertEqual(target.read_text(), "existing")

    def test_backend_connection_has_socket_deadlines(self):
        from dblib import matrixone
        with patch.object(matrixone.pymysql, "connect") as connect:
            matrixone._connect(timeout=17)
            self.assertEqual(connect.call_args.kwargs["read_timeout"], 17)
            self.assertEqual(connect.call_args.kwargs["write_timeout"], 17)

    def test_dolt_connection_does_not_require_extra_server_options(self):
        import psycopg2
        with patch.dict(os.environ, DOLT_PASSWORD="test"), patch.object(psycopg2, "connect") as connect:
            bb.connection("DOLT")
            self.assertNotIn("options", connect.call_args.kwargs)
            self.assertEqual(connect.call_args.kwargs["connect_timeout"], 5)

    def assert_micro_version_gate(self, script, arguments):
        shell = "/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").exists() else "bash"
        with tempfile.TemporaryDirectory() as root:
            client = Path(root) / "mysql"
            client.write_text("#!/bin/sh\nprintf '8.0.30-MatrixOne-v4.2.4\\n'\n")
            client.chmod(0o755)
            env = dict(os.environ, MYSQL_BIN=str(client), EXPECTED_MO_VERSION="4.2.5")
            result = subprocess.run([shell, str(HERE / script), *arguments], env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Expected MatrixOne 4.2.5", result.stderr)

    def test_diff_merge_rejects_wrong_release(self):
        self.assert_micro_version_gate("branch_sql_diff_merge.sh", ["branch", "1000", "1"])

    def test_collaborative_rejects_wrong_release(self):
        self.assert_micro_version_gate("branch_sql_collaborative.sh", ["branch", "1000", "1", "false"])

    def test_schema_commit_failure_is_not_silently_accepted(self):
        from dblib import dolt
        conn = unittest.mock.MagicMock()
        conn.cursor.return_value.execute.side_effect = RuntimeError("commit failed")
        with patch.object(dolt.psycopg2, "connect", return_value=conn):
            with self.assertRaises(RuntimeError):
                dolt.commit_dolt_schema("test")
        conn.close.assert_called_once()

    def test_collector_write_error_is_detected(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "run.log"
            log.write_text("100/100 steps\nERROR in flush_record: serialization failed\n")
            self.assertTrue(bb.log_failed(log))

    def test_psql_password_is_not_in_argv(self):
        from util import import_db
        with tempfile.TemporaryDirectory() as root:
            sql = Path(root) / "seed.sql"
            sql.write_text("SELECT 1;")
            with patch.object(import_db.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
                import_db.load_sql_file("postgresql://user:test-secret@localhost:5432/db", sql)
            self.assertNotIn("test-secret", str(run.call_args.args))
            self.assertEqual(run.call_args.kwargs["env"]["PGPASSWORD"], "test-secret")
            self.assertNotIn("stderr", run.call_args.kwargs)

    def test_psql_output_larger_than_pipe_buffer_does_not_hang(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            sql = root / "seed.sql"
            sql.write_text("SELECT 1;")
            client = root / "psql"
            client.write_text(f"#!{sys.executable}\nimport sys\nsys.stdout.write('row\\n' * 50000)\nsys.stderr.write('notice\\n' * 50000)\n")
            client.chmod(0o755)
            code = "from util.import_db import load_sql_file; import sys; load_sql_file('postgresql://user@localhost/db', sys.argv[1])"
            with patch.dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], PYTHONPATH=str(REPO)):
                rc, timed_out, _ = bb.run_process([sys.executable, "-c", code, str(sql)], root, root / "run.log", 3)
            self.assertEqual(rc, 0)
            self.assertFalse(timed_out)
            self.assertGreater((root / "run.log").stat().st_size, 65536)


class LifecycleTests(unittest.TestCase):
    def run_driver(self, root, fail=False):
        calls = []
        restarts = []
        def query(backend, sql, **kwargs):
            if sql == "SELECT VERSION()":
                return [("8.0.30-MatrixOne-v4.2.5",)]
            if sql.startswith("SHOW TABLES"):
                return [(name,) for name in bb.TABLES]
            if sql.startswith("SELECT (SELECT COUNT"):
                return [(10, 10)]
            if sql.startswith("SELECT COUNT"):
                return [(10,)]
            if sql == "SELECT 1":
                return [(1,)]
            if sql == "SHOW DATABASES":
                return [("seed",)]
            return []
        def run(command, repo, logfile, timeout):
            logfile.write_text("")
            out = Path(command[command.index("--outdir") + 1])
            cfg = text_format.Parse(Path(command[command.index("--config") + 1]).read_text(), tp.MacroBenchConfig())
            calls.append(cfg.run_id)
            write_result(out, cfg, **({"total_operation_errors": 1} if fail else {}))
            return 0, False, 0.5
        info = dict(HostConfig={"NetworkMode": "bridge"}, NetworkSettings={"Ports": {"6001/tcp": [{"HostPort": "6001"}]}},
                    State={"Running": True}, Image="sha256:test", Config={"Image": "matrixorigin/matrixone:4.2.5"})
        with patch.dict(os.environ, MO_HOST="127.0.0.1", MO_PORT="6001"), patch.object(bb, "verify_source"), patch.object(bb, "clone_seed"), patch.object(bb, "inspect_container", return_value=info), patch.object(bb, "query", side_effect=query), patch.object(bb, "run_process", side_effect=run), patch.object(bb.subprocess, "run", side_effect=lambda *a, **kw: restarts.append(a[0])):
            code = bb.main(["--repo", str(REPO), "--container", "dedicated", "--scale", "smoke",
                            "--seed-db", "seed", "--workflows", "software_dev", "--reps", "2", "--output", str(root)])
        return code, calls, restarts

    def test_restart_only_at_cold_rep(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "results"
            code, calls, restarts = self.run_driver(root)
            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 2)
            self.assertEqual(restarts, [["docker", "restart", "dedicated"]])
            rows = [json.loads(line) for line in (root / "summary.jsonl").read_text().splitlines()]
            self.assertEqual([r["phase"] for r in rows], ["cold", "warm"])

    def test_sql_error_stops_later_reps(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "results"
            code, calls, _ = self.run_driver(root, fail=True)
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 1)
            row = json.loads((root / "summary.jsonl").read_text())
            self.assertFalse(row["valid"])
            self.assertFalse(row["cleanup_ok"])


if __name__ == "__main__":
    unittest.main()
