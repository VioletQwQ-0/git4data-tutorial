# MatrixOne Git4Data Deep Dive (Part 10) · Deep Learning — Managing Training Data: lakeFS for the Files, MatrixOne for the Metadata

The first nine parts stayed on structured data: the [first four](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part1-data-at-scale/index.md) established what Git4Data is, how to use it, and [where it sits](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md) versus other tools; parts five through seven covered data operations; parts eight and nine entered AI training, walking a risk model through the [whole-pipeline map](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md) and [dataset release & leakage](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part9-dataset-release/index.md).

In this part, we turn to the data of **deep learning**. One clarification first: deep learning is a broad field, and it is not the same as multimodal — a text-only network or an image-only CNN is still deep learning. But it shares a watershed with classical ML in one respect, **data shape**: deep learning often trains directly on large-scale unstructured data (images, audio, video, raw text).

**This part focuses on managing that kind of file-based (image, audio, video, …) unstructured training data** — the most typical, and hardest-to-version, data shape in deep learning. To keep it concrete, we follow one classic task throughout: **training an image classifier**. When the data goes from "rows in a table" to "a pile of files + a huge metadata table," the versioning playbook has to change.

> This part walks through **managing file-based training data** end to end, much as Part 8 did for classical machine learning: lay out the whole picture first — from arrival to release, what the real problem is at each step, and which side owns the files versus the metadata. All metadata-side SQL here is verified on MatrixOne `4.1.0`; the full end-to-end lakeFS + MatrixOne script [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh) is verified too, in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `10-multimodal-lakefs/`.

---

## Deep learning's data is, first of all, a "file" problem

A classical ML sample is a row in a table: a few dozen structured fields, naturally fit for a database, naturally snapshot-able, diff-able, merge-able.

Deep learning's data isn't like that. A sample's body is **a file** — a few-MB image, a few-tens-of-MB audio clip, a hundred-MB video segment (a pile of bytes, ultimately). A whole dataset runs to tens of millions of files, TB to PB. Stuffing those files into a database is neither economical nor a good fit for what a database is good at (more in the next section).

But note one thing: **the files themselves don't go in the database, yet everything about the files is highly structured.** Every sample has: where it lives (object path), its content hash, its perceptual hash, its class label, which source it came from, what license, width/height, quality score, whether it's train or test, which model version used it… These are tens of millions of rows, still constantly inserted / updated / deleted — exactly where row-level version semantics matter most.

So this kind of data's versioning splits naturally into **two worlds**:

- **The file world**: the image / audio / video bodies. In object storage or lakeFS, what's versioned is "the object / file version."
- **The metadata world**: who points to which file, label, split, various hashes, source, license… one (or a few) huge structured tables, where what's versioned is "the row."

A truly reproducible training set is this product:

```text
reproducible training set = one definite metadata version (metadata snapshot)
                          × one definite set of file versions (lakeFS commit)
```

The two worlds must be **pinned together and kept consistent**: pin only the metadata and the files may have been overwritten; pin only the files and you don't know which samples, what labels, what split were in play. This is exactly where lakeFS (for the files) and MatrixOne's Git4Data capability (for the metadata) each do their job and then compose.

### Why give the files to lakeFS, instead of stuffing them into the database too?

A natural question: since MatrixOne can version data, why not put the image files in there too and let one system manage everything? The earlier parts already laid out the answer.

- **Git4Data's cheap snapshots assume "structured data + a metadata catalog."** [Part 3](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md) showed MatrixOne's snapshots are nearly independent of data size because immutable objects plus a metadata catalog version **row-level structured data**. Pour in PB of unparseable image files and that assumption breaks — the database degrades into a slow, expensive object store.

- **Files have no structure to diff.** Git4Data's value, established back in [Part 2](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part2-hands-on/index.md), is row-level diff / merge / query. But a JPEG has no rows, no primary key, no columns — a "row-level diff" of two images is meaningless. The boundary [Part 4](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape/index.md) drew is exactly this: Git4Data manages "structured-data evolution under one schema," and a file has no schema.

- **Files are written whole and are immutable.** An image isn't `UPDATE`d row by row; it's replaced wholesale. lakeFS writes objects whole, the underlying objects are immutable, a branch is a zero-copy metadata operation, and unmodified objects are reused across versions — this "whole objects + cheap branching" versioning is exactly what object storage + lakeFS (git-over-objects) is built for; forcing the database's row-level MVCC onto it is a mismatch.

- **It's more economical for the database to hold just the pointer.** MatrixOne can store BLOBs, but putting PB of files in it is a cost/architecture trade-off; the more practical division from [Part 8](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md)'s overview is: unparseable files go to object storage / lakeFS, and MatrixOne stores the catalog, hashes, URI, and commit. And a database snapshot can only freeze the **value of the pointer field**, not the external file itself (the `datalink` boundary) — so the file version is better left to lakeFS.

In one line: **the database is best at "row-level versioning of structured metadata," lakeFS is best at "whole-file versioning of large objects." Let each do what it's strongest at, then pin the two together — that's the whole thesis of this part.**

---

## One master map: the training-data lifecycle — files to lakeFS, metadata to MatrixOne

The conclusion first. The whole lifecycle of this file-based training data splits cleanly into a "file side" and a "metadata side," each versioned on its own, aligned at release.

![The training-data lifecycle: ingest → dedup → decontaminate → integrity → relabel → curate → release → train; at each stop the file side goes to lakeFS and the metadata side to MatrixOne, pinned together at release by one metadata snapshot × one lakeFS commit](./images/fig_multimodal-lifecycle_en.svg)

| Stage | The real problem | File side (lakeFS) | Metadata side (MatrixOne Git4Data) |
|---|---|---|---|
| Ingestion | new images, quality unknown, mustn't poison the set | land on an ingest branch | metadata rows on a branch, `MERGE` only on pass |
| Dedup | exact + perceptual duplicates across tens of millions | objects stored as-is | `GROUP BY` on `content_hash` / `phash`, pure SQL |
| Decontamination | eval / benchmark samples leaked into train | —— | anti-join the metadata to a benchmark-hash table, `DELETE` overlaps |
| Integrity check | every sample needs a label and a resolving pointer | object existence guaranteed by lakeFS | find missing labels; anti-join pointers vs the commit's object listing |
| Relabel | class labels, safety scores iterate | files unchanged | one branch per person, `MERGE` conflicts, `DIFF` the changes |
| Data curation | filter a clean subset by quality / safety / license | —— | a versioned `dataset_membership` subset |
| Dataset release | freeze "which version of which files this training used" | one lakeFS commit | one database-scope metadata snapshot, commit recorded in a registry |
| Training & evaluation | model must trace back to the exact data scene | commit locates the files | snapshot + registry build `model → metadata snapshot × lakeFS commit × code/env` lineage |
| Monitoring & retrain | new data accumulates, when to trigger the next round | new commit | distribution stats on the metadata + cross-version `DIFF` |

The division of labor in one line:

> **lakeFS makes the files traceable and reversible; MatrixOne's Git4Data capability makes the metadata queryable, row-level comparable, and atomically publishable. The two align into one reproducible whole via "a lakeFS commit recorded inside a metadata snapshot."**

Below, one complete case runs the whole map.

---

## The running case: preparing training data for an image classifier

Say we're training an **image classifier** — a content-safety model that sorts images into `safe` / `nsfw` (product categories or scene classification work the same way). The training data is **a large pile of image files + a class label per image**, gathered from several sources; it needs dedup, decontamination, an integrity check, and relabeling, and finally curation into a clean, reproducible training set.

The metadata is a `samples` table — **note it stores no files, only a pointer to the file plus everything you actually query on**:

```sql
CREATE TABLE samples (
    sample_id     BIGINT PRIMARY KEY,
    object_uri    VARCHAR(512),   -- lakeFS path (a pointer, not the file)
    object_commit VARCHAR(64),    -- the lakeFS commit that pins this file
    content_hash  VARCHAR(64),    -- sha256 of the file (exact-dup key)
    phash         VARCHAR(64),    -- perceptual hash (near-dup key)
    label         VARCHAR(16),    -- class label (safe / nsfw; NULL = not labeled yet)
    source        VARCHAR(32),    -- provenance
    license       VARCHAR(16),
    ingest_batch  VARCHAR(32)
);
```

A reproducible training record must bind at least these:

```text
run = metadata snapshot
    + lakeFS commit (the file version)
    + data-curation & split rules
    + preprocessing / augmentation version
    + code commit + runtime image digest
    + hyperparameters & random seed
    + model artifact URI & hash
    + evaluation metrics
```

**The metadata snapshot owns "which samples, what labels, how split"; the lakeFS commit owns "which version of the files" — drop either and this record can't be reproduced.**

### Stop 1: Ingestion — WAP across two worlds

Monday, upstream delivers a new batch of images. Both worlds move at once, each running its own WAP.

**File side (lakeFS)**: new objects are uploaded to an ingest branch, file-level checks run (can it decode, dimensions, a safety pre-scan — a pre-merge hook fits here), then commit and merge to main — the commit you get is this batch's file version (the lakeFS commands and commit value below are from the runnable [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh); `$L` is its API endpoint, `$KEY:$SECRET` its credentials):

```bash
# after uploading objects to the ingest branch, commit and merge to main
curl -u $KEY:$SECRET -H 'Content-Type: application/json' \
     -X POST $L/repositories/media/branches/ingest/commits -d '{"message":"ingest 2026w30"}'
curl -u $KEY:$SECRET -H 'Content-Type: application/json' \
     -X POST $L/repositories/media/refs/ingest/merge/main   -d '{"message":"publish 2026w30"}'
#   -> main commit (the file version) = ba1693908b37…  (example; differs per run)
```

**Metadata side (MatrixOne)**: the same batch's metadata rows — pointer to the lakeFS object, `object_commit` set to the commit just obtained — enter a branch, are audited, and merge only on pass. This is exactly [Part 7's Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish/index.md), now spanning two worlds:

```sql
DATA BRANCH CREATE TABLE samples_stage FROM samples;
-- the batch enters staging only; each row object_commit = 'ba1693908b37…'
INSERT INTO samples_stage SELECT ... FROM ...;

-- metadata-side gate: pointers complete? labels present? license known?
SELECT
  SUM(CASE WHEN object_uri IS NULL OR object_commit IS NULL THEN 1 ELSE 0 END) AS missing_pointer,
  SUM(CASE WHEN label IS NULL THEN 1 ELSE 0 END)                               AS missing_label,
  SUM(CASE WHEN license = 'unknown' THEN 1 ELSE 0 END)                         AS unknown_license
FROM samples_stage WHERE ingest_batch = '2026w30';
--   measured missing_pointer 0 / missing_label 250 / unknown_license 1000

DATA BRANCH DIFF samples_stage AGAINST samples OUTPUT SUMMARY;   -- measured INSERTED 5000
DATA BRANCH MERGE samples_stage INTO samples;                    -- publish only on full pass
```

**Each side audits and merges atomically within its own system.** But be clear: there is **no cross-system transaction** between lakeFS and MatrixOne — here the file side merges first, so if the metadata side then fails, lakeFS main has already moved. To truly get "if either side fails, neither publishes," you need a release coordinator: both sides first form immutable candidate versions, and only after a joint check do they publish the visible version through a versioned registry.

### Stop 2: Dedup — exact + perceptual, pure SQL, not one file touched

Across tens of millions of files there will be exact duplicates (the same image crawled twice at different URLs) and perceptual near-duplicates (the "same image" after cropping, compression, or a watermark). Both can be found on the metadata with SQL, **without pulling a single file back**:

```sql
-- exact duplicates: one content_hash owned by more than one sample
SELECT COUNT(*) AS exact_dup_groups FROM (
  SELECT content_hash FROM samples GROUP BY content_hash HAVING COUNT(*) > 1
) t;   -- measured 3000 groups

-- perceptual near-dups (not exact dups): same phash, more than one content_hash
SELECT COUNT(*) AS near_dup_groups FROM (
  SELECT phash FROM samples GROUP BY phash HAVING COUNT(DISTINCT content_hash) > 1
) t;   -- measured 2000 groups
```

The file hashes are computed offline and written into the metadata; once in the metadata, dedup is a few `GROUP BY`s, not a sweep across PB of object storage.

### Stop 3: Decontamination — dig the eval set out of the training set

This is the sore spot of deep learning, foundation models especially: **one test / benchmark image leaking into the training set inflates every downstream number.** The move is to anti-join the metadata against known eval-set hashes:

```sql
-- how many training samples overlap the benchmark (by content)?
SELECT COUNT(*) AS contaminated FROM samples s
WHERE EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash);
--   measured 1000 (matching 500 benchmark content hashes: each benchmark image + its exact re-crawled copy)
```

The 1000 rows this anti-join returns are all **exact `content_hash` matches** (500 unique benchmark hashes, each matching an original plus its exact copy). **Note it only covers exact content duplicates**: near-duplicates after cropping / compression / a watermark (a different `content_hash`, a close `phash`) won't be caught — to decontaminate those too, add a second anti-join on the benchmark's `phash`, the same way dedup does. The implementation here does exact decontamination only.

### Stop 4: Integrity check — every sample needs a label, and a pointer that resolves to a real file

To train an image classifier, each sample must satisfy at least two things: **it has a class label**, and **its pointer resolves to a file that actually exists**.

The first is one SQL on the metadata:

```sql
-- missing label: an image with no class label can't enter training this round
SELECT COUNT(*) AS unlabeled FROM samples WHERE label IS NULL;
--   measured 550
```

The second needs care: **checking only that `object_uri` / `object_commit` are non-NULL proves the fields are filled, not that the file exists** (a non-existent commit, a wrong path, a deleted object all pass such a check). A real existence check has to ask lakeFS — the simplest way is to pull that commit's object listing into a table and anti-join the pointers against it:

```sql
-- import the commit's object listing into lakefs_objects(path), then anti-join
SELECT COUNT(*) AS dangling FROM samples s
WHERE NOT EXISTS (
  SELECT 1 FROM lakefs_objects o
  WHERE s.object_uri = CONCAT('lakefs://media/main/', o.path)
);
--   the companion run_practice.sh really runs this: it lists the commit's objects
--   from lakeFS, imports them, and anti-joins — measured dangling = 0
```

This also surfaces the trap between the file world and the metadata world: **deleting an object in lakeFS does not automatically delete the metadata rows pointing to it; and deleting a metadata row doesn't delete the file.** The two worlds are versioned independently, and consistency rides on cross-world checks like this one.

### Stop 5: Relabel — the metadata evolves, the files don't budge

Class labels get corrected, safety scores get re-assessed — all of these touch only the **metadata**; the files are untouched. So we're back to the parallel collaboration of [Part 6](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part6-collaborative-dev/index.md): one branch per person, conflicts surface themselves, changes are on the record.

```sql
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review SET label = 'nsfw'
WHERE sample_id BETWEEN 1000 AND 1999 AND label = 'safe';
DATA BRANCH DIFF samples_review AGAINST samples OUTPUT SUMMARY;   -- measured UPDATED 980
DATA BRANCH MERGE samples_review INTO samples;
```

What a relabeling round changed is one `DIFF` away — and none of it produced a single file copy.

### Stop 6: Data curation and release — metadata snapshot × lakeFS commit

Release time. First run a **data curation** pass on the metadata to get a clean subset: drop exact duplicates (keep the lowest `sample_id` per `content_hash`), drop eval overlaps, drop unlabeled, keep only clearly-licensed samples, and write the split:

```sql
INSERT INTO dataset_membership
SELECT s.sample_id,
       CASE WHEN s.sample_id % 10 < 8 THEN 'train'
            WHEN s.sample_id % 10 = 8 THEN 'valid' ELSE 'test' END,
       'curate:v1 dedup+decontam+labeled+licensed'
FROM samples s
WHERE s.label IS NOT NULL
  AND s.license <> 'unknown'
  AND NOT EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash)
  AND s.sample_id = (SELECT MIN(s2.sample_id) FROM samples s2 WHERE s2.content_hash = s.content_hash);
--   measured train 38474 / valid 4934 / test 4935
```

Then the key step — **register the lakeFS commit first, then snapshot, so the binding is frozen inside the snapshot**. Order matters: write the registry first, take the snapshot second, so the binding lives in the frozen metadata version, not just in the mutable live database:

```sql
-- register the "metadata version × file version" binding first
-- (the snapshot name is chosen up front, so the row can name it)
INSERT INTO dataset_registry
SELECT 'ic_v1', 'ic_dataset_v1', 'media', 'ba1693908b37…',
       COUNT(*), 'metadata snapshot × lakeFS commit = reproducible training set'
FROM dataset_membership;

-- then snapshot, freezing samples / dataset_membership / dataset_registry together
CREATE SNAPSHOT ic_dataset_v1 FOR DATABASE img_cls;

-- the binding is now inside the snapshot (not just the live db):
SELECT lakefs_commit FROM dataset_registry {SNAPSHOT='ic_dataset_v1'} WHERE dataset_version = 'ic_v1';
--   -> ba1693908b37…
```

From now on, "what data did ic_v1 use" is no longer a verbal description but a product: `ic_dataset_v1` (the metadata snapshot) names the samples, labels, and split, and `ba1693908b37…` (the lakeFS commit) names the files. And reproducing isn't just counting rows — you can fetch the **actual file** back: read a train sample's pointer and commit from the snapshot, then go to lakeFS at that commit (this is really run in the companion [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh)):

```sql
SELECT s.object_uri, s.object_commit
FROM samples {SNAPSHOT='ic_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='ic_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train' ORDER BY s.sample_id LIMIT 1;
--   -> lakefs://media/main/img/000003.jpg  @  ba1693908b37…
```

```bash
curl -u $KEY:$SECRET "$L/repositories/media/refs/ba1693908b37…/objects?path=img/000003.jpg"
#   -> "img-3-bytes"   <- metadata snapshot × lakeFS commit reproduced the exact file
```

---

## lakeFS and MatrixOne: how the two version worlds divide the work and compose

This part has to make the boundary clear, or it's easy to assume "one of them is enough."

**lakeFS manages the files.** It's git-style version control over object storage: branch / commit / merge on top of S3 / GCS / Azure, pinning "the state of object storage at a moment" as a commit you can return to; plus pre-merge hooks for file-level checks before a merge. It excels at versioning and rolling back **large file bodies**. What it doesn't do: treat tens of millions of metadata entries as a table to run SQL / JOIN / aggregate on, or tell you "between these two versions, which **rows'** labels changed."

**MatrixOne's Git4Data capability manages the metadata.** It treats the metadata as a live, queryable table: row-level snapshot / branch / diff / merge / restore, JOIN-able, aggregate-able, anti-join-able any time. It excels at versioning, row-level comparison, and atomic publishing of **structured metadata**. What it's not the right fit for: storing and versioning the file bodies of images/audio/video (it can hold BLOBs, but that's not economical).

**How do they compose?** Via "a lakeFS commit recorded inside a metadata snapshot." At release, the MatrixOne side takes a database-scope metadata snapshot and writes the current lakeFS commit into a registry; to reproduce, you use both IDs together.

| Object | Better suited to | What it owns | What it doesn't |
|---|---|---|---|
| Image / audio / video / large files | **lakeFS / object storage** | file versioning, rollback, pre-merge checks | row-level metadata query & diff |
| Metadata: pointers, label, hash, split, source | **MatrixOne (Git4Data capability)** | row-level snapshot / branch / diff / merge / restore, JOIN & aggregate | storing file bodies (BLOBs work, but aren't economical) |
| Alignment of the two | **a binding in the registry** | metadata snapshot × lakeFS commit = reproducible training set | —— |

This is more realistic than "hoping one tool manages both files and metadata well." Files have their optimal solution, the metadata has its own; the key is to **pin them together explicitly**.

---

## A minimal loop you can adopt directly

1. Files to lakeFS, metadata to a MatrixOne `samples` table, each row recording a pointer + `content_hash` + `phash` + label + source + license.
2. New batches go to a branch first: files on a lakeFS branch, metadata on a MatrixOne branch; each side audits, merge only on pass.
3. On the metadata, use SQL for dedup, decontamination, and integrity checks, keeping suspicious samples out of curation.
4. Run data curation into `dataset_membership`, take a database-scope metadata snapshot.
5. **Register the lakeFS commit together with the metadata snapshot** — that's the reproducibility anchor.
6. At training, bind `model → metadata snapshot × lakeFS commit × code/env`; next round, use `DIFF` for metadata changes and a new commit for file changes.

---

## Closing

Deep learning turned training data from "rows in a table" into "files in object storage + a huge metadata table." The optimal way to manage the two differs: the files want whole-object versioning and rollback, the metadata wants row-level query, comparison, and atomic publishing. Force them into one tool and one end always chafes.

The more realistic architecture lets **lakeFS manage the files and MatrixOne's Git4Data capability manage the metadata**, then pins the two version worlds into one reproducible whole via "metadata snapshot × lakeFS commit." Dedup, decontamination, integrity, relabeling, data curation — the operations that actually decide training-data quality happen almost entirely on the metadata, and the metadata happens to be a table you can version with SQL.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
