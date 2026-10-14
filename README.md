# MatrixOne Git4Data Tutorial

Runnable companion code for the **MatrixOne Git4Data Deep Dive** article series —
Git-style version control for data at scale (`commit`, `branch`, `diff`, `merge`,
`cherry-pick`, time travel), built into [MatrixOne](https://github.com/matrixorigin/matrixone).

> What is Git4Data? If you treat a database as a Git repository and a table as a
> file in it, MatrixOne lets you run everyday Git operations — snapshot, clone,
> branch, diff, merge, cherry-pick, restore — over terabytes of data, almost
> instantly. It's the same workflow software engineers use on code, now on data.

## The series

| Part | Theme | Topic | Article | Code |
|------|-------|-------|---------|------|
| 1 | Concept | The Git moment for data at scale | [Blog ↗](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part1-data-at-scale/index.md) | — |
| 2 | Concept | **Hands on: every Git primitive, from zero** | [Blog ↗](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part2-hands-on/index.md) | [`02-hands-on/`](02-hands-on/) |
| 3 | Concept | Under the hood: why snapshot/diff/merge are this fast | [Blog ↗](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md) | — |
| 4 | Concept | The data-versioning landscape: git4data vs lakeFS / Dolt / Snowflake | [Blog ↗](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md) | — |
| 5 | Data Ops | **Incident rescue**: snapshot / DIFF investigation / PITR | [Article](05-incident-rescue/article_en.md) | [`05-incident-rescue/`](05-incident-rescue/) |
| 6 | Data Ops | **Collaborative development**: one branch per engineer | [Article](06-collaborative-dev/article_en.md) | [`06-collaborative-dev/`](06-collaborative-dev/) |
| 7 | Data Ops | **Write-Audit-Publish**: a release gate for data | [Article](07-write-audit-publish/article_en.md) | [`07-write-audit-publish/`](07-write-audit-publish/) |
| 8 | AI Training | **ML continuous learning**: train only the delta | [Article](08-ml-incremental/article_en.md) | [`08-ml-incremental/`](08-ml-incremental/) |
| 9 | AI Training | **SFT curation**: clean in place, with receipts | [Article](09-sft-curation/article_en.md) | [`09-sft-curation/`](09-sft-curation/) |
| 10 | AI Training | **Collaborative labeling**: disagreement IS the conflict | [Article](10-labeling-collab/article_en.md) | [`10-labeling-collab/`](10-labeling-collab/) |
| 11 | AI Training | **RLHF preference data**: consensus, re-judging, reproducibility | [Article](11-rlhf-preference/article_en.md) | [`11-rlhf-preference/`](11-rlhf-preference/) |
| 12 | AI Training | **Multimodal × lakeFS**: bytes there, catalog here | [Article](12-multimodal-lakefs/article_en.md) | [`12-multimodal-lakefs/`](12-multimodal-lakefs/) |
| 13 | Agents | **Agent memory**: versioned, branchable, rewindable | [Article](13-agent-memory/article_en.md) | [`13-agent-memory/`](13-agent-memory/) |
| 14 | Agents | **Agent traces**: queryable, joinable, versioned | [Article](14-agent-trace/article_en.md) | [`14-agent-trace/`](14-agent-trace/) |
| 15 | Agents | **Agent self-evolution** (finale): branch / evaluate / merge / roll back | [Article](15-agent-evolution/article_en.md) | [`15-agent-evolution/`](15-agent-evolution/) |

Concept parts (1–4) link out to the published blog. Each practice part (5–15)
ships its full article in-folder — `article_en.md` / `article_zh.md` — right
next to the runnable SQL.

## Quick start (5 minutes)

```bash
# 1. Run a local MatrixOne (open source, MySQL-compatible)
docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.0.0-rc3

# 2. Run the Part 2 walkthrough — every Git primitive on 1,000,000 rows
mysql -h 127.0.0.1 -P 6001 -u root -p111 < 02-hands-on/git4data_primitives.sql
```

Default credentials: user `root`, password `111`, port `6001`.

## What Part 2 covers

[`02-hands-on/git4data_primitives.sql`](02-hands-on/git4data_primitives.sql) is a
single, copy-paste-runnable script (English comments) that walks through:

- **commit / tag / reset** — `CREATE SNAPSHOT`, time-travel `SELECT … {snapshot=…}`, `RESTORE`
- **clone** — zero-copy `CREATE TABLE … CLONE`
- **branch** — lineage-tracked `DATA BRANCH CREATE`
- **diff** — row-level `DATA BRANCH DIFF … OUTPUT SUMMARY / COUNT / LIMIT / FILE`
- **merge** — three-way `DATA BRANCH MERGE … WHEN CONFLICT FAIL | SKIP | ACCEPT`
- **cherry-pick** — `DATA BRANCH PICK … KEYS(…)`
- **point-in-time recovery** — `CREATE PITR` + `RESTORE … FROM PITR "…"`
- **granularity** — the same semantics at **table / database / account / cluster** levels
- **scale** — measured numbers showing snapshot/clone/branch cost is independent of table size

It loads a million rows with a single `generate_series` statement (no external
files needed) and cleans up after itself.

## Measured: cost is independent of data size

Same table, same operations, on a single-node Docker MatrixOne (diff/merge each
touch only 1,000 rows):

Steady-state, median of several runs (MatrixOne 4.0.0-rc3):

| table size | load | `CREATE SNAPSHOT` | `CLONE` | `DATA BRANCH CREATE` | `DIFF` (1000) | `MERGE` (1000) |
|---|---|---|---|---|---|---|
| 1,000,000 | 0.5 s | 6 ms | 6 ms | 7 ms | 13 ms | 64 ms |
| 10,000,000 | 5.3 s | 8 ms | 8 ms | 7 ms | 21 ms | 178 ms |
| 100,000,000 | 41 s | 5 ms | 25 ms | 19 ms | 23 ms | 189 ms |

Snapshot is dead constant (it just names a metadata directory). Clone/branch copy
the metadata directory, not the data — 100× the data, clone rises only 6 ms → 25 ms.
Diff/merge scale with *how many rows changed*, not table size. (The first snapshot
of a freshly loaded table is ~10–12 ms — a one-time flush of in-memory data — then
drops to the steady-state numbers above.)

## Links

- Benchmark scripts and release-specific setup: [benchmarks/](benchmarks/README.md)

- MatrixOne: https://github.com/matrixorigin/matrixone
- Docs: https://docs.matrixorigin.cn/

## License

Apache 2.0
