# MatrixOne Git4Data Deep Dive (Part 12) · Large Models — RLHF Preference Data: Disagreement, Adjudication, Reproducibility

In [Part 11](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation/index.md) we ran a full SFT curation pass: six cuts on a branch, each counted, a DIFF as the receipt, registry before snapshot at release. This part moves one step further down the large-model training chain, into **preference alignment** — the **preference data** that RLHF / DPO depends on.

As [Part 11](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation/index.md) explained, SFT teaches a model to answer the way people expect. But SFT has a ceiling: it can learn "this is a good answer," not "**between these two decent answers, which one is better.**" And the latter is exactly what pushes a model from usable to good. That's what preference alignment is for: have humans (or models) compare candidate responses, train a **reward model** on those comparisons, and use it to steer the policy model.

So the shape of the training data changes once again — and this time more fundamentally than in any earlier part.

> This part makes clear what's special about preference data, the ways it breaks (degenerate pairs, no consensus, preference cycles, length bias), how to adjudicate disagreement between annotators, and how a preference dataset gets bound to a reward model as a reproducible pair. All SQL is verified on MatrixOne `4.1.0`, and **everything is deterministic** (no `rand()`), so every number reproduces run to run; the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `12-rlhf-preference/`.

---

## Two things that make preference data special

### 1. The unit isn't a row — it's a pair

In earlier parts one sample was one row: an SFT record, one image's metadata. Preference data isn't. Its smallest unit is a **triple**:

```text
(prompt, chosen — the better response, rejected — the worse one)
```

**A preference record is inherently relational**: it *links* two candidates under the same prompt and states a **relative** fact about them. That brings a set of problems the earlier parts didn't have:

- if the two candidates are the same text, the "preference" carries no information (**a degenerate pair**);
- several pairs under one prompt can **contradict** each other (A>B, B>C, and yet C>A);
- you can't judge one row in isolation — it only makes sense **in the context of its prompt**.

### 2. Preference data isn't collected — it's computed

This matters more. SFT data is handed to you: a vendor gives you a record, and that's the record. Preference data isn't. What you actually receive is **votes**:

```text
pair #1024   annotator anno_1: A     annotator anno_2: A     annotator anno_3: B
```

The `(chosen, rejected)` row that actually trains the reward model is **derived** from those votes: who has the majority? what if three people all disagree? does a "tie" vote count? **The derivation rule is itself a decision.**

So a preference dataset is **second-order data**:

```text
preference dataset version = version of the raw votes  ×  derivation rule
                             (majority / agreement threshold / tie handling)
```

Change the threshold and the same votes produce a different dataset. Which means "how this preference data came to be" must be versioned *with* the data — otherwise, six months later nobody can say which rule, over which batch of votes, produced `rm_v1`.

---

## A failure that really happens: the reward model learns "longer is better"

Here's a classic and well-hidden RLHF failure.

The team trains reward model `rm_v1`, hooks up PPO, and runs policy optimization. A few rounds in, the responses get **longer and longer**, more padded — while the reward score climbs steadily. Humans reading them think they got worse.

The problem isn't PPO; it's the preference data. Human annotators (and the models used for labeling) have a well-documented tendency: **between two decent answers, they lean toward the longer, more detailed one.** If that tendency goes unnoticed, the preference data systematically shows "chosen is longer than rejected," so the reward model learns **length** as a shortcut feature instead of quality. The policy model then climbs that reward — straight into verbosity.

What makes this dangerous: **nothing errors out, and every metric looks like it's improving.** The only way to catch it early is a **statistical audit of the preference data before training** — which is one SQL away.

We'll see it below: this article's pool measures **75.9% of chosen responses longer than rejected, by 95.2 characters on average.** That number belongs on the table before training starts.

---

## The running case: building and releasing one round of preference data

The setup: preference data for a chat model. **20,000 prompts, each with 3 candidate responses** (from different policy-model versions), with annotators comparing candidates pairwise.

Three tables, matching "raw material → votes → finished product":

```sql
-- ① candidate responses (raw material)
CREATE TABLE candidates (
    cand_id   BIGINT PRIMARY KEY,
    prompt_id BIGINT,
    slot      CHAR(1),          -- A / B / C
    response  VARCHAR(512),
    resp_len  INT,              -- length: needed for the length-bias audit
    model_tag VARCHAR(32)       -- which policy version generated it
);

-- ② raw votes (one row per annotator per pair)
CREATE TABLE annotations (
    anno_id   BIGINT PRIMARY KEY,
    pair_id   BIGINT,
    prompt_id BIGINT,
    cand_a    BIGINT,
    cand_b    BIGINT,
    annotator VARCHAR(16),
    verdict   CHAR(1)           -- 'a' / 'b' / 't' (tie)
);

-- ③ the derived preference pairs (the finished product that trains the reward model)
CREATE TABLE preference_pairs (
    pair_id     BIGINT PRIMARY KEY,
    prompt_id   BIGINT,
    chosen_id   BIGINT,
    rejected_id BIGINT,
    n_votes     INT,
    top_votes   INT,
    agree_rate  DOUBLE          -- agreement = top votes / total votes
);
```

**Keeping table ② — the raw votes — matters enormously.** Many teams store only the final `(chosen, rejected)` and throw the votes away. The moment you want a different derivation rule (say, raising the agreement threshold from 0.6 to 0.8), you can never compute it again. The raw votes are this dataset's source code.

Case scale: 60,000 candidates, **63,000 votes, 21,000 pairs** (20,000 main pairs, plus B-vs-C and C-vs-A constructed for 500 prompts to demonstrate preference cycles).

---

## Step 1: derive the preference pairs from votes

The derivation is itself one SQL — aggregate votes per pair, take the majority, compute the agreement rate:

```sql
INSERT INTO preference_pairs
SELECT v.pair_id, v.prompt_id,
       CASE WHEN v.a_votes >= v.b_votes THEN v.cand_a ELSE v.cand_b END,   -- chosen
       CASE WHEN v.a_votes >= v.b_votes THEN v.cand_b ELSE v.cand_a END,   -- rejected
       v.n_votes,
       GREATEST(v.a_votes, v.b_votes, v.t_votes),
       ROUND(GREATEST(v.a_votes, v.b_votes, v.t_votes) / v.n_votes, 3)     -- agreement
FROM (
  SELECT pair_id, MIN(prompt_id) AS prompt_id, MIN(cand_a) AS cand_a, MIN(cand_b) AS cand_b,
         COUNT(*) AS n_votes,
         SUM(CASE WHEN verdict = 'a' THEN 1 ELSE 0 END) AS a_votes,
         SUM(CASE WHEN verdict = 'b' THEN 1 ELSE 0 END) AS b_votes,
         SUM(CASE WHEN verdict = 't' THEN 1 ELSE 0 END) AS t_votes
  FROM annotations GROUP BY pair_id
) v;
--   measured: 21,000 pairs
```

The distribution of agreement rates is this dataset's first health check:

```sql
SELECT agree_rate, COUNT(*) AS n FROM preference_pairs GROUP BY agree_rate ORDER BY agree_rate;
--   measured 0.333 → 2,000    (three people, three answers — no conclusion)
--            0.667 → 4,000    (2:1 — a majority, but disagreement)
--            1.000 → 15,000   (unanimous)
```

**This table already talks**: 2,000 pairs where three annotators reached no consensus at all, and 4,000 with real disagreement. The former is mostly noise; the latter needs adjudication. We handle each separately below.

---

## Step 2: audit and curate on a branch

As in [Part 11](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation/index.md), branch first; the pool doesn't move a row:

```sql
DATA BRANCH CREATE TABLE pairs_curated FROM preference_pairs;
```

### Check 1: degenerate pairs — both candidates are the same text

The same response sampled into two slots (or a collision at generation time) makes a "preference" with no information, and feeds contradictory gradient to the reward model:

```sql
SELECT COUNT(*) AS degenerate FROM pairs_curated p
JOIN candidates c1 ON p.chosen_id   = c1.cand_id
JOIN candidates c2 ON p.rejected_id = c2.cand_id
WHERE c1.response = c2.response;
--   measured 200
```

Note this check **must JOIN back to the candidates table** — looking at `preference_pairs` alone can't find it, because `chosen_id` and `rejected_id` are two different IDs and only the body text reveals they're identical. That's a direct consequence of preference data being relational.

### Check 2: no consensus — the annotators effectively flipped a coin

An agreement rate of 0.333 means three people gave three different answers. Such a pair trains no useful signal; it's pure noise:

```sql
SELECT COUNT(*) AS no_consensus FROM pairs_curated WHERE agree_rate < 0.6;
--   measured 2,000
DELETE FROM pairs_curated WHERE agree_rate < 0.6;
```

**The 0.6 threshold is a decision**, not a law of nature: set it high and the data is cleaner but smaller — and you systematically drop the *hard* questions (the harder the question, the more disagreement). Set it low and you keep more noise. So it has to be recorded in the version's rule.

### Check 3: preference cycles — A>B, B>C, and yet C>A

This problem is unique to preference data, and the most interesting. Each judgment is legitimate on its own, but **together they can't logically hold**:

```text
        A ────▶ B          A is better than B
        ▲       │          B is better than C
        │       ▼          C is better than A   ← contradiction
        └────── C
```

Where do they come from? Usually not from careless annotators, but because different pairs were judged by **different people**, or because the three responses are genuinely close and the comparison criteria differ in subtle ways (one person values accuracy, another concision). **A cycle's existence is itself evidence that this group of comparisons is unreliable.**

If a reward model ingests a cycle, it's being told A>B>C>A simultaneously — it can only learn a mediocre compromise out of the contradiction. Detection is a three-way self-join within one prompt:

```sql
SELECT COUNT(DISTINCT p1.pair_id) AS pairs_in_cycles
FROM pairs_curated p1
JOIN pairs_curated p2 ON p1.prompt_id = p2.prompt_id AND p1.rejected_id = p2.chosen_id
JOIN pairs_curated p3 ON p2.prompt_id = p3.prompt_id AND p2.rejected_id = p3.chosen_id
WHERE p3.rejected_id = p1.chosen_id;
--   measured 630 pairs caught in cycles
```

Two ways to handle it: **drop the whole cycle** (what this article does — clean), or **send it back for re-adjudication** (more expensive, but keeps the hard samples). Either way, the prerequisite is that you **can find them**.

### Check 4: length bias — this cut doesn't delete, it *looks*

This is where the "reward model learns that longer is better" failure gets caught:

```sql
SELECT
  COUNT(*) AS pairs,
  SUM(CASE WHEN c1.resp_len > c2.resp_len THEN 1 ELSE 0 END) AS chosen_longer,
  ROUND(100.0 * SUM(CASE WHEN c1.resp_len > c2.resp_len THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_longer,
  ROUND(AVG(c1.resp_len - c2.resp_len), 1) AS avg_len_gap
FROM pairs_curated p
JOIN candidates c1 ON p.chosen_id   = c1.cand_id
JOIN candidates c2 ON p.rejected_id = c2.cand_id;
--   measured pairs 18170 / chosen_longer 13790 / pct_longer 75.9 / avg_len_gap 95.2
```

**75.9%.** Meaning: if you guessed purely by "pick the longer one," you'd be right three times in four — of course the reward model learns that shortcut first.

To be explicit: **this step should not delete data.** Longer answers genuinely are better sometimes, and cutting them bluntly destroys real signal along with the bias. It is a **signal that must be seen**, and the options include stratified sampling by length, explicit length de-biasing in the reward model, or accepting it and watching length as a separate metric at evaluation. **Git4Data's job is to guarantee this number gets seen before release — not to decide what to do about it.**

---

## The receipt: what this round actually changed

```sql
DATA BRANCH DIFF pairs_curated AGAINST preference_pairs OUTPUT SUMMARY;
--   measured INSERTED 0 / DELETED 2830 / UPDATED 0
```

`2830 = 200 (degenerate) + 2000 (no consensus) + 630 (cycles)`, and the pool's 21,000 pairs never moved a row. **18,170** pairs go on to the next step.

![The preference-data flow: 63,000 raw votes derive 21,000 preference pairs by majority, agreement distribution 15000/4000/2000; audited on a branch — degenerate 200, no consensus 2000, cycles 630 all dropped, while 75.9% length bias is audited not deleted; DIFF receipt DELETED 2830 leaving 18,170; two reviewers overturn 985 and 657 on their own branches with conflicts skipped; finally register-then-snapshot publishes pref_v1 bound to rm_v1, freezing all 63,000 raw votes with it](./images/fig_rlhf-preference_en.svg)

---

## Step 3: adjudicating disagreement — branches, conflicts, and picking only what was judged

Now back to those 4,000 pairs that split 2:1. These are the **most valuable and most dangerous** samples at once: disagreement tends to appear on genuinely hard questions, so dropping them wastes signal, while accepting them wholesale may be wrong.

The standard move is a senior review. And "several reviewers editing the same batch in parallel" is exactly the collaboration scenario from [Part 6](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part6-collaborative-dev/index.md) — one branch per person:

```sql
DATA BRANCH CREATE TABLE pairs_alice FROM pairs_curated;
DATA BRANCH CREATE TABLE pairs_bob   FROM pairs_curated;

-- an overturned verdict = swapping chosen / rejected
UPDATE pairs_alice SET chosen_id = rejected_id, rejected_id = chosen_id
WHERE agree_rate < 0.7 AND pair_id % 4 = 0;

UPDATE pairs_bob   SET chosen_id = rejected_id, rejected_id = chosen_id
WHERE agree_rate < 0.7 AND pair_id % 6 = 0;
```

How much each reviewer changed is one DIFF apiece:

```sql
DATA BRANCH DIFF pairs_alice AGAINST pairs_curated OUTPUT SUMMARY;   -- measured UPDATED 985
DATA BRANCH DIFF pairs_bob   AGAINST pairs_curated OUTPUT SUMMARY;   -- measured UPDATED 657
```

Their edits **partly overlap** (the pair_ids divisible by both 4 and 6). On merge, the overlap is the real conflict:

```sql
DATA BRANCH MERGE pairs_alice INTO pairs_curated;                    -- merge first
DATA BRANCH MERGE pairs_bob   INTO pairs_curated WHEN CONFLICT SKIP; -- keep the mainline's existing verdict
```

`SKIP` means: where Bob touched a row the mainline already has Alice's verdict on, keep the mainline version and skip Bob's; everything non-conflicting merges normally. **Disagreement is never silently overwritten — it's surfaced and handled explicitly**, which matters especially for preference data, since "whose judgment counts" is itself a decision worth recording.

If the process requires that only rows a final adjudicator approved may enter the mainline, use `PICK` to take just the reviewed queue back, rather than merging a whole branch.

---

## Step 4: release, and bind the reward model to it

The release order is the same as [Part 11](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation/index.md) — **register first, then snapshot**, so the binding is frozen into the version rather than sitting only in the live database:

```sql
INSERT INTO dataset_registry
SELECT 'pref_v1', 'pref_v1', COUNT(*),
       'drop degenerate, agree_rate>=0.6, drop cycle pairs, length bias reported'
FROM pairs_curated;

-- specific to preference data: bind the reward model to the data it ate
INSERT INTO reward_model_registry
VALUES ('rm_v1', 'pref_v1', 'pref_v1', 'policy_v3-base', '9c41ab');

DROP TABLE preference_pairs;
ALTER TABLE pairs_curated RENAME TO preference_pairs;
CREATE SNAPSHOT pref_v1 FOR DATABASE rlhf_pool;
```

`reward_model_registry` is specific to this link in the chain. RLHF's chain is long — **preference data → reward model → policy model** — and a problem anywhere in it shows up as a symptom at the far end, in the policy model. With this binding, "the policy model started padding its answers" can be traced back to "`rm_v1` was trained on `pref_v1`, and `pref_v1`'s length bias was 75.9%."

Verify after release that the binding really is in the version:

```sql
SELECT n_pairs FROM dataset_registry {SNAPSHOT='pref_v1'} WHERE dataset_version = 'pref_v1';
--   measured 18170
SELECT rm_version, pref_snapshot FROM reward_model_registry {SNAPSHOT='pref_v1'};
--   measured rm_v1 / pref_v1
SELECT COUNT(*) AS v1_pairs FROM preference_pairs {SNAPSHOT='pref_v1'};
--   measured 18170
```

The lineage chain closes:

```text
rm_v1
  ├── pref_version  = pref_v1
  ├── pref_snapshot = pref_v1          ← 18,170 pairs, bit-for-bit reproducible
  ├── curate_rule   = agree>=0.6, cycles dropped, degenerate dropped…
  ├── base_model    = policy_v3-base
  └── code_commit   = 9c41ab
```

And the raw votes (63,000 of them) are frozen in the same snapshot — which means **re-deriving under a different rule is always available**: raise the agreement threshold to 0.8, derive again, DIFF against `pref_v1`, and you know exactly how many pairs that decision would change.

---

## The industry's other approaches, and where each gets stuck

A few common ways preference data gets managed:

**Approach 1: export JSONL from the labeling platform, and have training scripts read it.** The most common. The platform (Label Studio, Argilla, or in-house) collects, then exports `pref_v1.jsonl`. The problem is that export **breaks the chain**: agreement rates, who voted, who later overturned what — all stay in the platform; the dataset side keeps only the final `(chosen, rejected)`. Changing the derivation rule means re-exporting; finding preference cycles means another script to read the JSONL back.

**Approach 2: keep raw votes in the platform, only the finished product in a warehouse.** Better than #1 — at least the votes survive. But **votes and product live in two systems**, and the versions don't line up: you can't say which moment's votes produced `pref_v1`, because annotation in the platform keeps growing and changing.

**Approach 3: HuggingFace Datasets + Hub for versioning.** The dataset gets revisions, with a good ecosystem. The granularity is still dataset-level: it can tell you v2 isn't v1, but not that "these 630 pairs went because they formed preference cycles"; and the derivation rule and audit queries still live in external scripts.

**Approach 4: derive and audit in a warehouse (Spark / BigQuery).** Aggregating votes, finding cycles, computing length bias in SQL — this path matches this article exactly, and is a common choice at larger teams. The difference is again version semantics: keeping each version means new tables or table versions, **row-level branch / DIFF / conflict merge isn't native**, and "several reviewers overturning verdicts in parallel, with conflicts surfaced explicitly" is very hard to express with table versions.

| Approach | Votes & product in one version | Row-level receipt | Parallel adjudication & conflict | Relational audit (cycles / degenerate) | Re-derive under a new rule |
|---|---|---|---|---|---|
| Platform JSONL export | no (chain broken) | no | inside the platform, invisible outside | another script | re-export from the platform |
| Votes in platform + product in warehouse | no (two systems) | no | inside the platform | partial (product side) | versions don't line up |
| HF Datasets + Hub | no | no (dataset level) | no | external scripts | re-upload |
| Warehouse SQL | yes (same database) | no (table-version level) | **no native conflict semantics** | **SQL** ✅ | yes |
| **MatrixOne (Git4Data capability)** | **yes (one database snapshot)** | **yes (`DATA BRANCH DIFF`)** | **branches + `MERGE` conflict / `PICK`** | **SQL** ✅ | **yes (votes are in the snapshot too)** |

In one line: preference data needs **relational queries** (find cycles, find degenerate pairs, compute bias), **row-level version semantics** (who overturned which rows), and **conflict semantics** (two reviewers judged differently) at the same time. Warehouses give you the first two halfway; almost nothing supports the third natively — and all three are the same thing on the same table.

---

## Boundaries and applicability

- **Agreement isn't quality.** A high agreement rate says annotators agree, not that they're right; a systematic bias (everyone preferring longer answers) sails through with very high agreement. **So the agreement threshold and the bias audit must both run** — either alone misses something.

- **Preference cycles aren't always noise.** Some cycles reflect that the candidates genuinely have **no total order** (each is better in its own way). Dropping whole cycles is the simplest handling, but if they make up a large share, the labeling criteria need redesigning rather than endless deletion.

- **Don't "fix" length bias by deleting data.** Cutting the "chosen is longer" samples removes real signal along with the bias. The audit's value is making it visible; how to de-bias is a modeling decision.

- **Git4Data makes no semantic judgments.** Which answer is better, where the threshold sits, how cycles get handled — your decisions. What it guarantees: votes and product in one version, every overturn on record, conflicts surfaced explicitly, any historical version reproducible.

- **Keep the raw votes long-term.** They're this dataset's source code. Delete them and you permanently lose the ability to re-derive under a new rule.

---

## Closing

Preference data is the **softest link** in the whole large-model training chain: it isn't collected fact but a conclusion derived from a pile of human judgments; its smallest unit isn't a row but a pair; and it breaks not by missing fields but by **contradicting itself (preference cycles) or systematically favoring a shortcut feature (length bias)**.

Which is exactly why it needs to be queryable, adjudicable, and reproducible: **of 21,000 pairs, 630 were caught in preference cycles, 2,000 reached no consensus at all, and 75.9% of chosen responses were longer than rejected** — three numbers, each one SQL away, and each one that should be seen before the reward model starts training. The 985 and 657 verdicts two reviewers overturned in parallel had their conflicts surfaced at merge rather than silently overwritten. And in the end `rm_v1` and `pref_v1` are bound inside the same snapshot, with all 63,000 raw votes frozen alongside — so re-deriving under a different rule is always one query away.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
