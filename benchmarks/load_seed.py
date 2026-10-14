#!/usr/bin/env python3
"""Load a bounded-batch MO seed, or emit the equivalent DoltgreSQL SQL dump."""

import argparse
import json
from pathlib import Path
import time

import run_branchbench as bb


SCHEMA = {
    "warehouse": "w_id INT PRIMARY KEY, w_name VARCHAR(32), w_ytd DECIMAL(12,2)",
    "district": "d_id INT, d_w_id INT, d_next_o_id INT, PRIMARY KEY(d_w_id, d_id)",
    "customer": "c_id INT, c_d_id INT, c_w_id INT, c_credit_lim DECIMAL(12,2), c_ytd_payment DECIMAL(12,2), c_balance DECIMAL(12,2), PRIMARY KEY(c_w_id, c_d_id, c_id)",
    "item": "i_id INT PRIMARY KEY, i_price DECIMAL(12,2), i_name VARCHAR(32)",
    "stock": "s_i_id INT, s_w_id INT, s_quantity INT, PRIMARY KEY(s_w_id, s_i_id)",
    "orders": "o_id INT, o_d_id INT, o_w_id INT, o_c_id INT, o_carrier_id INT NULL, o_ol_cnt INT, o_all_local INT, o_entry_d DATETIME, PRIMARY KEY(o_w_id, o_d_id, o_id)",
    "new_order": "no_o_id INT, no_d_id INT, no_w_id INT, PRIMARY KEY(no_w_id, no_d_id, no_o_id)",
    "order_line": "ol_o_id INT, ol_d_id INT, ol_w_id INT, ol_number INT, ol_i_id INT, ol_supply_w_id INT, ol_delivery_d DATETIME NULL, ol_quantity INT, ol_amount DECIMAL(12,2), ol_dist_info VARCHAR(32), PRIMARY KEY(ol_w_id, ol_d_id, ol_o_id, ol_number)",
}
INSERTS = {
    "customer": "SELECT c2.n * 1000 + c1.n + 1, d.n + 1, w.w, 50000, (c1.n % 1000) * 10, CASE WHEN c1.n % 50 = 0 THEN NULL ELSE (c1.n % 2000) - 1000 END FROM {warehouses} w CROSS JOIN n10 d CROSS JOIN n3 c2 CROSS JOIN n1000 c1",
    "stock": "SELECT a.n * 100 + b.n + 1, w.w, 100 + ((a.n + b.n) % 50) FROM {warehouses} w CROSS JOIN n1000 a CROSS JOIN n100 b",
    "orders": "SELECT c2.n * 1000 + c1.n + 1, d.n + 1, w.w, c2.n * 1000 + c1.n + 1, NULL, 10, 1, CURRENT_TIMESTAMP FROM {warehouses} w CROSS JOIN n10 d CROSS JOIN n3 c2 CROSS JOIN n1000 c1",
    "new_order": "SELECT c1.n + 2101, d.n + 1, w.w FROM {warehouses} w CROSS JOIN n10 d CROSS JOIN n1000 c1 WHERE c1.n < 900",
    "order_line": "SELECT c2.n * 1000 + c1.n + 1, d.n + 1, w.w, l.n + 1, ((c1.n * 10 + l.n) % 100000) + 1, w.w, NULL, 5, ((c1.n + l.n) % 500) + 1, 'dist_info' FROM {warehouses} w CROSS JOIN n10 d CROSS JOIN n3 c2 CROSS JOIN n1000 c1 CROSS JOIN n10 l",
}


def expected_counts(scale):
    if scale == "smoke":
        return dict(warehouse=10, district=100, customer=100, item=1000, stock=10000,
                    orders=10, new_order=10, order_line=10)
    warehouses = int(scale)
    factors = dict(warehouse=1, district=10, customer=30000, stock=100000,
                   orders=30000, new_order=9000, order_line=300000)
    return {"item": 100000, **{table: factor * warehouses for table, factor in factors.items()}}


def seed_statements(scale, batch=1, dialect="mo"):
    if batch < 1:
        raise ValueError("batch size must be positive")
    if scale == "smoke":
        statements = [s.strip() for s in (bb.HERE / "seed" / "smoke.sql").read_text().split(";") if s.strip()]
        for statement in statements:
            yield statement.replace("DATETIME", "TIMESTAMP") if dialect == "dolt" else statement
        return
    warehouses = int(scale)
    yield "CREATE TABLE n10 (n INT PRIMARY KEY)"
    yield "INSERT INTO n10 VALUES " + ",".join(f"({n})" for n in range(10))
    yield "CREATE TABLE n100 (n INT PRIMARY KEY)"
    yield "INSERT INTO n100 SELECT a.n * 10 + b.n FROM n10 a CROSS JOIN n10 b"
    yield "CREATE TABLE n1000 (n INT PRIMARY KEY)"
    yield "INSERT INTO n1000 SELECT a.n * 10 + b.n FROM n100 a CROSS JOIN n10 b"
    yield "CREATE TABLE n3 (n INT PRIMARY KEY)"
    yield "INSERT INTO n3 VALUES (0),(1),(2)"
    yield "CREATE TABLE nw (w INT PRIMARY KEY)"
    yield "INSERT INTO nw VALUES " + ",".join(f"({n})" for n in range(1, warehouses + 1))
    for table, schema in SCHEMA.items():
        if dialect == "dolt":
            schema = schema.replace("DATETIME", "TIMESTAMP")
        yield f"CREATE TABLE {table} ({schema})"
    yield "INSERT INTO warehouse SELECT w, CONCAT('w', w), 0 FROM nw"
    yield "INSERT INTO district SELECT d.n + 1, w.w, 3001 FROM nw w CROSS JOIN n10 d"
    yield "INSERT INTO item SELECT a.n * 100 + b.n + 1, ((a.n * 100 + b.n) % 1000) / 10.0, CONCAT('item', a.n * 100 + b.n + 1) FROM n1000 a CROSS JOIN n100 b"
    # Restrict the warehouse input before the cross joins, bounding each INSERT.
    for low in range(1, warehouses + 1, batch):
        high = min(low + batch, warehouses + 1)
        subset = f"(SELECT w FROM nw WHERE w >= {low} AND w < {high})"
        for table, select in INSERTS.items():
            yield f"INSERT INTO {table} " + select.format(warehouses=subset)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scale", choices=bb.SCALES, required=True)
    parser.add_argument("--db", type=bb.identifier)
    parser.add_argument("--warehouses-per-batch", type=int, default=1)
    parser.add_argument("--statement-timeout", type=int, default=1800)
    parser.add_argument("--expected-version", default=bb.MO_RELEASE)
    parser.add_argument("--write-sql", type=Path, help="Write a dump without connecting to a database")
    parser.add_argument("--dialect", choices=["mo", "dolt"], default="mo")
    parser.add_argument("--output", type=Path, help="New directory for seed load evidence")
    args = parser.parse_args(argv)
    if min(args.warehouses_per_batch, args.statement_timeout) < 1:
        parser.error("batch size and statement timeout must be positive")
    if args.write_sql:
        with args.write_sql.open("x") as dump:
            for statement in seed_statements(args.scale, args.warehouses_per_batch, args.dialect):
                dump.write(statement + ";\n")
        print("PASS: SQL dump generated; row counts have not been checked against a database")
        return 0
    if not args.db or args.dialect != "mo":
        parser.error("MO loading requires --db; DoltgreSQL uses --write-sql --dialect dolt")
    root = (args.output or bb.HERE / "results" / ("seed_" + args.db + "_" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))).resolve()
    root.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    conn = None
    with (root / "load.log").open("w") as log:
        try:
            conn = bb.connection("MATRIXONE", args.statement_timeout)
            with conn.cursor() as cur:
                cur.execute("SELECT VERSION()")
                version = str(cur.fetchone()[0])
                if not bb.version_matches(version, args.expected_version):
                    raise RuntimeError("MO version differs from --expected-version")
                cur.execute("SHOW DATABASES")
                if args.db in {row[0] for row in cur.fetchall()}:
                    raise RuntimeError("refusing to overwrite an existing database")
                cur.execute(f"CREATE DATABASE `{args.db}`")
                cur.execute(f"USE `{args.db}`")
                for index, statement in enumerate(seed_statements(args.scale, args.warehouses_per_batch), 1):
                    cur.execute(statement)
                    log.write(f"statement {index} completed\n")
                    log.flush()
                actual = {}
                for table in SCHEMA:
                    cur.execute(f"SELECT COUNT(*) FROM `{table}`")
                    actual[table] = int(cur.fetchone()[0])
                valid = actual == expected_counts(args.scale)
                result = {"database": args.db, "scale": args.scale, "server_version": version,
                          "warehouses_per_batch": args.warehouses_per_batch,
                          "elapsed_sec": time.monotonic() - started, "rows": actual, "valid": valid}
                (root / "seed_result.json").write_text(json.dumps(result, indent=2) + "\n")
                if not valid:
                    raise RuntimeError("seed row count validation failed")
        except Exception as error:
            log.write(f"{type(error).__name__}: {error}\n")
            print("FAIL: seed retained for inspection; see load.log")
            return 1
        finally:
            if conn:
                conn.close()
    print("PASS: seed loaded; all eight workflow table counts matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
