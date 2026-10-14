# Git4Data Benchmarks

One driver and one pinned BranchBench implementation for MatrixOne **4.2.5** and
DoltgreSQL. These are current-release runs; their timings do not reproduce the
paper's historical 4.0.0-rc2 results automatically.

[MatrixOne BranchBench](https://github.com/matrixorigin/matrixone-branchbench-mo)
is the compatibility entrypoint for older published links. Its migration forwards
to a fixed commit of this package; the legacy `run_mo_v424.py` filename no longer
means the new driver runs 4.2.4. Use this directory as the maintained implementation,
not a second copy of its driver in the compatibility repository.

## Prepare

Python 3.11+, Git, Docker, and a dedicated database container are required.

```bash
bash benchmarks/prepare_branchbench.sh
export PYTHON="$PWD/benchmarks/.runtime/branchbench/.venv/bin/python"
```

Preparation checks out `dengn/matrixone-branchbench` at
`95c18b7bf7a51029e3344a65e807df07aa28a2ea`, applies `branchbench.patch`, installs
pinned dependencies, and generates protobuf modules. It refuses an existing
destination. Use its optional first argument for another runner directory, then
pass that directory through `--repo` and set `PYTHON` to its virtual environment.
The driver verifies the pinned commit and patch before running.
Preparation also performs its import check from the prepared runner directory,
so old `dblib`/`macrobench` modules in the caller's directory cannot shadow it.

## MatrixOne Smoke

The image digest pins the multi-platform 4.2.5 release. Use an unused local port.

```bash
docker run -d --name git4data-bb --memory=8g \
  -p 127.0.0.1:16001:6001 \
  matrixorigin/matrixone:4.2.5@sha256:4455f6904a0cca5bb0f876d3026c407755216f91a4413a623c028495e0bba20f
export MO_HOST=127.0.0.1 MO_PORT=16001 MO_USER=root MO_PASSWORD=111
# Wait until the dedicated instance accepts SQL connections.
"$PYTHON" benchmarks/load_seed.py --scale smoke --db bb_seed_sfsmoke
"$PYTHON" benchmarks/run_branchbench.py --scale smoke --seed-db bb_seed_sfsmoke \
  --container git4data-bb --reps 2 \
  --workflows software_dev failure_repro data_cleaning mcts simulation
```

Smoke executes seven worker steps per repetition. It checks functionality, not
full-scale performance. `--check` renders configs without contacting a database
or restarting a container.

## SF100 / SF1000

Load a new seed once, then reuse it through independent run clones:

```bash
"$PYTHON" benchmarks/load_seed.py --scale 100 --db bb_seed_sf100
bash benchmarks/run_mo_sf100.sh --container git4data-bb

"$PYTHON" benchmarks/load_seed.py --scale 1000 --db bb_seed_sf1000
bash benchmarks/run_mo_sf1000.sh --container git4data-bb
bash benchmarks/run_mo_sf1000_simulation.sh --container git4data-bb
```

The loader checks all eight workflow tables. By default each large INSERT covers
one warehouse: at most 300,000 order-line rows, rather than one transaction for
all 30M/300M rows. `--warehouses-per-batch` changes this bound. Partial loads are
retained on failure, and existing databases are never overwritten. Batching can
change physical object layout, so record it when comparing performance.

Each MO wrapper runs five reps. The four ordinary workflows are separate from
simulation. Canonical full parameters come from the original archive/4.2.4
adaptation and are identical across SF100/SF1000:

| Workflow | Workers | Steps Per Worker |
|---|---:|---:|
| software_dev | 5 | 20 |
| failure_repro | 1 | 10 |
| data_cleaning | 10 | 20 |
| mcts | 10 | 100 |
| simulation | 1000 | 1 |

`--workers` / `--steps` permit explicit sweeps; generated configs and summaries
record the selected values. `software_dev` uses both required DDL changes.
Full-scale workloads need separately provisioned resources; the smoke container
above does not establish SF100/SF1000 capacity.

## DoltgreSQL

`DOLT` means the PostgreSQL-protocol **DoltgreSQL** backend, not MySQL Dolt.
Provide an existing dedicated DoltgreSQL container and matching local endpoint.
Install the PostgreSQL `psql` client on the machine running the driver.
Its image ID and server version are recorded; this change does not validate a
new DoltgreSQL release.

```bash
"$PYTHON" benchmarks/load_seed.py --scale 100 --dialect dolt \
  --write-sql benchmarks/.runtime/ch-w100.sql
export DOLT_HOST=127.0.0.1 DOLT_PORT=15432 DOLT_USER=postgres DOLT_PASSWORD=password
bash benchmarks/run_dolt_sf100.sh --container my-doltgres \
  --sql-dump "$PWD/benchmarks/.runtime/ch-w100.sql"
```

DoltgreSQL reloads the dump into a new database each rep. Four reps are the
default. `existing_db` is not used. SQL errors, including compare failures,
invalidate the sample; a timeout is not proof of a database throughput limit.

## Timing and Failure Handling

- Cold = restart the dedicated container before each workflow's r1. This does
  not clear host OS or persistent file caches. Warm reps do not restart.
- `elapsed_sec` = runner worker interval; excludes seed/setup and cleanup.
- `wall_sec` = complete runner process, including its setup and cleanup.
- `rep_wall_sec` also includes the driver's restart/clone, checks, and cleanup.
- `--max-runtime-sec` is the worker cap; `--timeout` bounds the entire process
  group, including loader children. MO cancellation uses a separate KILL
  connection; socket deadlines and the outer hard timeout provide fallbacks.
- Valid samples require all steps, zero operation errors, matching JSON/Parquet
  run IDs, successful runner exit, a healthy container, and successful cleanup.
  Any invalid sample stops later reps and retains evidence. The driver never
  removes containers or data volumes.

Results default to `benchmarks/results/`. `metadata.json`, generated configs,
per-run logs/results, and `summary.jsonl` capture the execution inputs. Passwords
are supplied through environment variables and are not written to metadata.

## SQL Diff/Merge Experiments

`branch_sql_diff_merge.sh` and `branch_sql_collaborative.sh` originate from
`matrixorigin/academic_paper` commit `6e86267908126e1ec2986c9a6fb8f345343438b4`.
They now check MO 4.2.5 and both accept `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`,
`MYSQL_PASSWORD`, and `MYSQL_DB`. See each script's usage. They require the
original TPC-H `lineitem` data and snapshots in a disposable benchmark database;
the SQL scripts require the MySQL `mysql` client and the collaborative script
requires Bash 4+. Historical paper measurements remain
version-specific.

## Tests and Provenance

```bash
BB_REPO="$PWD/benchmarks/.runtime/branchbench" "$PYTHON" \
  -m unittest discover -s benchmarks/tests
```

Local validation on 2026-10-14 used an arm64 4.2.5 container: all five workflows
passed one cold and one warm smoke rep (14 worker steps total). A bounded seed
batch produced 300,000 order-line rows with correct counts in all eight tables;
active-query KILL and snapshot/clone/diff/merge primitives were also checked.
Full SF100/SF1000 performance and live DoltgreSQL runs remain unvalidated.

`branchbench.patch` combines the 4.2.4 adaptation's per-worker error/validity
checks with MO socket deadlines and cancellation. The original machine-specific
drivers, their repair runs, and the reconstructed wrappers have one shared
lifecycle here. Fixed paths, automatic data-directory deletion, and silent
restart of a warm rep are not carried over. Latest-release smoke and offline
validation do not certify the old paper numbers or full-scale stability.

The runner also propagates DoltgreSQL schema-commit and cleanup failures instead
of accepting those warnings as a successful setup or teardown.
Its psql loader avoids undrained output pipes, inherits the per-run stderr log,
and passes the connection password through `PGPASSWORD`, never argv.
