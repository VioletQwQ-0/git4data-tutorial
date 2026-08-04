# MatrixOne Git4Data Deep Dive (Part 11) · Large Models — SFT Data Curation: Auditable and Reproducible

Across the first ten parts we took MatrixOne's Git4Data capability from concept to the AI training floor: the [first four](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part1-data-at-scale/index.md) built the coordinate system, parts five through seven covered data operations ([incident rescue](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part5-incident-rescue/index.md), [parallel collaboration](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part6-collaborative-dev/index.md), [Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish/index.md)), parts eight and nine covered classical machine learning (the [whole-pipeline map](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle/index.md), [dataset release & leakage](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part9-dataset-release/index.md)), and [Part 10](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part10-multimodal/index.md) turned to deep learning's file-based data, with lakeFS for the files and MatrixOne for the metadata.

This part enters **large models** — specifically the step that leans hardest on human judgment: **SFT (Supervised Fine-Tuning) data curation**.

First, where it sits. A large model usually goes through three stages: **pretraining** (learning language and world knowledge from a vast corpus), **SFT** (teaching it to answer the way people expect, using high-quality "instruction → response" samples), and **preference alignment** (RLHF / DPO and friends, choosing the better of several decent answers). SFT is the hinge between them, and it's the stage with **the least data and the highest value per record** — pretraining runs to trillions of tokens; SFT is often just tens to hundreds of thousands of records.

Precisely because it's small, **every record's quality and every curation decision imprints directly on model behavior.** And those decisions are almost all human calls: do we keep this batch of synthetic data? a vendor's quality dropped — do we pull their data? what's the right code-to-chat ratio? is the quality bar 0.35 or 0.50?

> This part runs one complete SFT data curation pass end to end: what the pool looks like, which cuts to make, how each cut leaves an audit record, how to publish it as a reproducible version, and where the industry's other approaches get stuck. All SQL is verified on MatrixOne `4.1.0`; the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `11-sft-curation/`.

---

## What's special about SFT data: it comes back to the database's home turf

In [Part 10](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part10-multimodal/index.md), image training data had to split into two worlds: files to lakeFS, metadata to MatrixOne. A JPEG has no rows and no columns; a database can't do much with it.

SFT data is different. One SFT sample looks like this:

```json
{"instruction": "Explain what a database snapshot is", "response": "A snapshot is the state of...", "domain": "chat"}
```

It's **text, but highly structured**: instruction in one column, response in another, plus source, language, domain, quality score, safety flag, length… **the entire sample, body text included, fits directly into a table.** A few hundred thousand records of a few hundred to a few thousand characters each is comfortably within a database's wheelhouse.

That gives SFT curation an advantage Part 10 didn't have: **no two-world alignment is needed — everything happens on one table, in SQL, and is natively covered by row-level version semantics.**

And SFT curation's actions happen to be entirely row-level:

```text
drop duplicate samples        = DELETE some rows
cut samples below the bar     = DELETE some rows
remove eval-set overlap       = DELETE some rows
pull a source's data          = DELETE some rows
rebalance the domain mix      = selectively DELETE / keep
fix some responses            = UPDATE some rows
```

**Every cut is a row-level change** — exactly what the Git4Data capability is best at. So the thesis up front:

> **SFT curation shouldn't be a script that runs and vanishes. It should be a controlled change: done on a branch, audited by a DIFF, published atomically as a version.**

---

## Why curation has to be auditable

Here's a scene almost every large-model team has lived through.

After `sft-v7` ships, the team finds it noticeably worse than `sft-v6` on coding questions — but the training code didn't change and neither did the hyperparameters; the data was just "cleaned as usual." So the question becomes: **what exactly did that cleaning remove?**

If curation is a pile of Python scripts that run and finish, what you typically have is: 730k records before, 600k after. What those missing 130k were, nobody can say — deduped? cut by the quality bar? did an entire domain get dropped by mistake? And reproducing the dataset `sft-v6` used is hopeless, because the raw pool has taken in new data since.

That is what auditable means here. Every cut in curation should answer three questions:

1. **how many, and which ones** (auditable);
2. **why** (the rule is on record);
3. **can this version be reproduced exactly** (traceable).

The case below makes all three concrete.

---

## The running case: one SFT curation pass for a chat model

Say we maintain the SFT pool for a general chat model. The data comes from three channels: **purchased vendor data**, **model-synthesized data**, and **human-written data**; it spans code / math / chat / safety; and it contains both single-turn samples and multi-turn conversations.

The pool is one table — note that **the body text (instruction / response) lives in the table**, alongside every field the curation decisions rely on:

```sql
CREATE TABLE sft_records (
    record_id     BIGINT PRIMARY KEY,
    conv_id       BIGINT,          -- multi-turn: several rows share one conv_id
    turn_no       INT,             -- which turn within the conversation
    instruction   VARCHAR(512),
    response      VARCHAR(1024),
    norm_hash     VARCHAR(64),     -- hash of the normalized instruction (near-dup key)
    exact_hash    VARCHAR(64),     -- hash of instruction+response (exact-dup key)
    domain        VARCHAR(24),     -- code / math / chat / safety
    source        VARCHAR(32),     -- vendor / synthetic / human
    lang          VARCHAR(8),
    resp_len      INT,
    quality_score DOUBLE,          -- from a scoring model or heuristics
    is_safe       TINYINT,         -- 1 = passed the safety classifier
    ingest_batch  VARCHAR(32)
);
```

The two hash columns deserve a note — they're two different knives:

- **`exact_hash`**: hashes instruction + response together, catching **identical samples** — the same record sold to you by two vendors, or one batch imported twice.
- **`norm_hash`**: hashes only the **normalized** instruction (unified case, stripped punctuation and whitespace), catching **near-duplicates where the question is the same but the answer differs** — extremely common in synthetic data, where one prompt gets sampled several times.

The case pool: 60,000 single-turn samples + 4,000 exact duplicates + 3,000 near-duplicates + 2,000 three-turn conversations (6,000 rows), plus 800 responses truncated to empty strings and 150 conversations whose second turn was truncated — **73,000 rows measured**.

---

## Curate on a branch: six cuts, each with a number

The first move matters: **don't delete on the pool's main table**. Branch first and do the whole pass on the branch — the pool doesn't move a row, and you can compare against it or throw the attempt away at any time. That's [Part 7's Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish/index.md) applied to curation:

```sql
DATA BRANCH CREATE TABLE sft_curated FROM sft_records;
```

The branch is zero-copy ([Part 3](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md) explains why), so even for a multi-million-row pool this is a millisecond operation that copies no data.

### Cut 1: exact duplicates

The same "instruction + response" appearing several times makes the model overfit that sample. Group by `exact_hash`, keep the lowest `record_id` in each group:

```sql
-- how many will go
SELECT COUNT(*) AS exact_dup_rows FROM sft_curated c
WHERE c.record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2
                     WHERE c2.exact_hash = c.exact_hash);
--   measured 4000

DELETE FROM sft_curated
WHERE record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2
                   WHERE c2.exact_hash = sft_curated.exact_hash);
```

### Cut 2: near-duplicates

Subtler and more common: **one question with several different synthesized answers.** Their `exact_hash` values all differ, but the normalized `norm_hash` is the same. Which one to keep is a policy choice (here the lowest `record_id`; in practice **keeping the highest quality score** is more common):

```sql
SELECT COUNT(*) AS near_dup_rows FROM sft_curated c
WHERE c.record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2
                     WHERE c2.norm_hash = c.norm_hash);
--   measured 3000

DELETE FROM sft_curated
WHERE record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2
                   WHERE c2.norm_hash = sft_curated.norm_hash);
```

Be clear about the boundary: `norm_hash` only catches near-duplicates that are **identical after normalization**. The **semantically equivalent but differently worded** kind ("what is a snapshot" vs "what does snapshot mean") escapes a hash and needs vector similarity or MinHash/SimHash. Those methods produce candidate pairs — but the final "which row to drop" is still a row-level delete, and still runs through this same flow.

### Cut 3: the quality gate

Empty responses, truncated generations, and low scores from the scoring model all stay out of training:

```sql
SELECT COUNT(*) AS low_quality FROM sft_curated
WHERE resp_len < 10 OR quality_score < 0.35;
--   measured 5184

DELETE FROM sft_curated WHERE resp_len < 10 OR quality_score < 0.35;
```

Note that these thresholds (length 10, score 0.35) **are a decision of this curation pass**, not a law of nature. They must be recorded — they'll go into the curation rule at release, because the next version will very likely change them (we raise it to 0.50 at the end of this article).

### Cut 4: safety

Samples flagged unsafe by the classifier are removed:

```sql
SELECT COUNT(*) AS unsafe FROM sft_curated WHERE is_safe = 0;   -- measured 101
DELETE FROM sft_curated WHERE is_safe = 0;
```

### Cut 5: benchmark decontamination

The most dangerous cut in large-model curation. **If benchmark questions leak into the SFT training set, the model memorized the answers rather than learning the ability** — every benchmark number inflates, and nothing errors out. The move is an anti-join against the eval set's prompt hashes:

```sql
SELECT COUNT(*) AS contaminated FROM sft_curated c
WHERE EXISTS (SELECT 1 FROM eval_prompts e WHERE e.norm_hash = c.norm_hash);
--   measured 744

DELETE FROM sft_curated
WHERE EXISTS (SELECT 1 FROM eval_prompts e WHERE e.norm_hash = sft_curated.norm_hash);
```

The same honesty as [Part 10](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part10-multimodal/index.md) applies: this anti-join matches prompts that are **identical after normalization**. Rewritten, translated, or reworded contamination escapes it — catching that needs a semantic-similarity layer over the eval set. **Hash decontamination is the floor, not the ceiling.**

### Cut 6: multi-turn integrity

This cut is specific to SFT, and the one scripts most often miss. **A multi-turn conversation must enter and leave as a whole**: if turn 2 was dropped by cut 3 because its response was truncated, a conversation left with only turns 1 and 3 is **broken and harmful** — the model learns jumpy, incoherent dialogue structure.

So after every filter, sweep once more: which `conv_id`s no longer have all their turns, and drop those whole:

```sql
SELECT COUNT(*) AS broken_conv_rows FROM sft_curated c
WHERE c.conv_id IN (
  SELECT conv_id FROM sft_curated GROUP BY conv_id HAVING COUNT(*) < MAX(turn_no)
);
--   measured 300 (150 conversations, each left with two turns after one was cut)

DELETE FROM sft_curated WHERE conv_id IN (
  SELECT conv_id FROM (
    SELECT conv_id FROM sft_curated GROUP BY conv_id HAVING COUNT(*) < MAX(turn_no)
  ) t
);
```

**This is why curation order matters**: the integrity check must come after all the filters, because what it cleans up is precisely the collateral damage they caused.

After six cuts: **73,000 → 59,671 rows, measured.**

![One SFT curation pass: from a 73,000-row pool, take a zero-copy branch, make six cuts on it (exact dup 4000, near dup 3000, quality 5184, safety 101, decontamination 744, conversation integrity 300), the DIFF audit record showing DELETED 13329, then register first and snapshot to publish sft_v1 at 59,671 rows](./images/fig_sft-curation_en.svg)

---

## The audit record: one DIFF says exactly what this pass removed

With the pass complete, the important move — **record what it did**:

```sql
DATA BRANCH DIFF sft_curated AGAINST sft_records OUTPUT SUMMARY;
--   measured INSERTED 0 / DELETED 13329 / UPDATED 0
```

`13329` isn't an estimate; it's the sum of the six cuts: `4000 + 3000 + 5184 + 101 + 744 + 300 = 13329`. **The pool never moved a row, and this pass's entire impact compresses into one summary line.**

More useful than the total: you can expand the difference **down to rows** at any time — which ones went, how much a given domain lost, whether one source got hit unusually hard — all of it ordinary SQL:

```sql
-- before publishing, look at the mix: domain and source ratios are themselves curation decisions
SELECT domain, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sft_curated), 1) AS pct
FROM sft_curated GROUP BY domain ORDER BY domain;
--   measured chat 19346 (32.2%) / code 13247 (22.0%) / math 13764 (22.9%) / safety 13764 (22.9%)

SELECT source, COUNT(*) AS n FROM sft_curated GROUP BY source ORDER BY source;
--   measured human_written 24041 / synthetic_gpt 18040 / vendor_a 18040
```

These two queries surface something easy to overlook: **the mix is part of curation too.** Chat at 32% and code at only 22% — does that match this run's goal? Synthetic data at nearly a third — is that too high? There's no universal answer, but these judgments must be seen **before release**, not guessed at after training produces a strange model.

---

## Release: atomic merge, register before snapshot

Only after the audit passes do we publish. Two details are worth stressing.

**First, register before you snapshot.** We want "this dataset version = which snapshot + which curation rule" recorded as a queryable binding. The order must be **write the registry first, take the snapshot second** — otherwise the binding sits only in the mutable live database, never frozen into the version:

```sql
CREATE TABLE dataset_registry (
    dataset_version   VARCHAR(32) PRIMARY KEY,
    metadata_snapshot VARCHAR(64),
    n_records         BIGINT,
    curate_rule       VARCHAR(256)
);

-- register first (the snapshot name is chosen up front, so this row can name it)
INSERT INTO dataset_registry
SELECT 'sft_v1', 'sft_v1', COUNT(*),
       'exact+near dedup, len>=10, score>=0.35, safe only, eval-decontam, whole-conv'
FROM sft_curated;
```

Note the `curate_rule` column: **it makes "the rules this version was filtered by" part of the data.** Three months later, when someone asks what v1's quality bar was, it's one SELECT — not an archaeology trip through the script repo's git log.

**Second, publishing is atomic.** Replace the pool with the curated branch, then snapshot to freeze the whole version:

```sql
DROP TABLE sft_records;
ALTER TABLE sft_curated RENAME TO sft_records;   -- the curated pool becomes the pool
CREATE SNAPSHOT sft_v1 FOR DATABASE sft_pool;

-- the binding is now inside the snapshot, not just the live db
SELECT n_records FROM dataset_registry {SNAPSHOT='sft_v1'} WHERE dataset_version = 'sft_v1';
--   measured 59671
```

---

## The next round: v2's audit record, and v1 still reproducible

Weeks later the team decides to tighten the quality bar — from 0.35 to 0.50. Same flow again, and this time **the DIFF tells you what that decision costs**:

```sql
DATA BRANCH CREATE TABLE sft_v2_wip FROM sft_records;
DELETE FROM sft_v2_wip WHERE quality_score < 0.50;

DATA BRANCH DIFF sft_v2_wip AGAINST sft_records OUTPUT SUMMARY;
--   measured DELETED 12514
SELECT COUNT(*) AS v2_rows FROM sft_v2_wip;   -- measured 47157
```

Moving one threshold from 0.35 to 0.50 costs another **12,514** records — the dataset drops from 59,671 to 47,157, **down 21%**. That number belongs on the table before training starts, not after the model comes out dumber and someone starts guessing.

Meanwhile v1 remains queryable, untouched:

```sql
SELECT COUNT(*) AS v1_rows FROM sft_records {SNAPSHOT='sft_v1'};   -- measured 59671
```

So the opening problem — "`sft-v7` regressed on coding" — now has an executable investigation path: DIFF the data snapshot v7 used against v6's, see which code-domain rows disappeared and which cut removed them. **For the first time, a model regression lands on specific data changes.**

---

## The industry's other approaches: how SFT curation usually gets managed, and where each gets stuck

Making SFT curation "auditable, reproducible, reversible" has a few common paths, each solving part of it:

**Approach 1: a pile of Python cleaning scripts producing a new file.** The most common. `clean_v3.py` runs and emits `sft_train_v3.jsonl`. Flexible; the cost is that **neither the result nor the process is queryable** — you have a 600k-line file but no record of "which 13,329 went, and why"; reproducing the previous version depends on both the script and the raw pool being unchanged.

**Approach 2: scripts plus keeping every intermediate artifact.** Disciplined teams do this: `step1_dedup.jsonl`, `step2_quality.jsonl`… It is traceable, at the cost of **a full copy per step** (N× storage), and comparing two versions means writing more scripts — you can't just JOIN or aggregate.

**Approach 3: HuggingFace Datasets versioned on the Hub.** The dataset gets versions and revisions, with a strong ecosystem. But the granularity is the **dataset version**: it can tell you v3 isn't v2, not that "these 300 rows went because their conversations were left incomplete"; the filtering logic still lives in external scripts.

**Approach 4: data-version tools like DVC / lakeFS.** They pin JSONL files to versions you can return to, which is solid. But what they see is **files**: the diff is file- or object-level, while SFT curation's semantics are entirely row-level; and with the data in files, computing "the domain mix" means reading it back first.

**Approach 5: curation in a data warehouse (Spark / BigQuery, …).** Filtering in SQL matches this article's approach and is common at larger teams. The difference is **version semantics**: keeping each version in Spark usually means writing to a new date-suffixed table, or leaning on Delta/Iceberg table versions; row-level branch / diff / merge isn't native, so "try a curation pass on a branch and throw it away if it's bad" has to be assembled by hand.

Put in one table:

| Approach | Row-level audit record (which rows) | Where the filtering lives | Version reproducible | Cost of a failed attempt | Extra copies |
|---|---|---|---|---|---|
| Python scripts + output file | none | scripts | on discipline | re-run everything | one per version |
| Scripts + intermediate artifacts | partial (by diffing files) | scripts | yes | re-run | **N×** |
| HF Datasets + Hub | no (dataset level) | external scripts | yes | re-upload | one per version |
| DVC / lakeFS | no (file level) | external scripts | yes | re-run | deduped, cheaper |
| Warehouse SQL (Spark, …) | no (table-version level) | **SQL** ✅ | yes | new table | one table per version |
| **MatrixOne (Git4Data capability)** | **yes (`DATA BRANCH DIFF`)** | **SQL** ✅ | **yes (snapshot)** | **zero-copy branch, just drop it** | **none** |

In one line: the other approaches either lock the filtering logic in scripts and leave you a file (the script family), or version the data without row-level semantics (file-version tools), or let you filter in SQL without native branching and row-level diff (warehouses). What's different about MatrixOne is that **all three hold on one table at once**: curation written in SQL, tried on a zero-copy branch, each cut recorded by `DATA BRANCH DIFF`, then published atomically and snapshotted.

---

## Boundaries and applicability

- **The Git4Data capability doesn't judge quality for you.** Where the quality score comes from (a scoring model, rules, humans), where the bar sits, how the mix is set — all your decisions. What it guarantees is that those decisions act on a definite data version, the results are auditable, and mistakes can be rolled back.

- **Hash dedup and hash decontamination are the floor, not the ceiling.** Semantic near-duplicates and reworded contamination need vector retrieval or MinHash-style methods to produce candidates first; but once candidates exist, "which rows to drop" comes right back to the row-level flow here.

- **Multi-turn integrity must be checked explicitly.** It doesn't hold by itself, and it has to come after every filter — the 300 rows measured here were collateral damage from the earlier cuts.

- **Snapshots have retention cost.** Keep the `sft_vN` for each shipped model long-term, and set a cleanup policy for abandoned trial versions, or historical versions will hold storage indefinitely.

- **Curation rules should travel with the version.** Writing the thresholds and rules into the registry (this article's `curate_rule` column) is far more reliable than a comment in some script.

---

## Closing

SFT is the stage of large-model training with the least data and the highest value per record. That's exactly why every curation decision imprints directly on model behavior — and why this has long been the **least transparent** link in the chain: a pile of scripts runs, the pool shrinks a lot, and what went, why, and whether it can be undone rests on memory and discipline.

Replace that with "do it on a branch, audit it with a DIFF, publish atomically, freeze with a snapshot," and the link becomes as controllable as code review: **73,000 → 59,671, and where those 13,329 went is one SQL away**; raising the bar from 0.35 to 0.50 costs 21% of the data, and that price is on the table before training starts; and any historical version can be reconstructed bit for bit at any time.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
