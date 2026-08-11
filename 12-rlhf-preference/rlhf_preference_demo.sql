-- =============================================================================
-- Git4Data Tutorial — Part 12: RLHF preference data
-- A preference record is not one row: it is (prompt, chosen, rejected), derived
-- from several annotators voting on a pair. This demo builds pairs from raw
-- annotations by majority vote, audits them (degenerate / low agreement /
-- preference cycles / length bias), adjudicates disagreements on branches with
-- MERGE + PICK, then publishes one version bound to a reward-model record.
--
-- Everything is DETERMINISTIC (no rand()), so every number reproduces exactly.
-- Verified on MatrixOne 4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < rlhf_preference_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS pref_v1;
DROP DATABASE IF EXISTS rlhf_pool;
CREATE DATABASE rlhf_pool;
USE rlhf_pool;

-- ---------------------------------------------------------------- candidates
-- 20,000 prompts x 3 candidate responses (A/B/C) = 60,000 rows.
-- Candidate A is deterministically the LONGEST for most prompts — that is what
-- creates the length bias we audit later.
CREATE TABLE candidates (
    cand_id   BIGINT PRIMARY KEY,
    prompt_id BIGINT,
    slot      CHAR(1),          -- A / B / C
    response  VARCHAR(512),
    resp_len  INT,
    model_tag VARCHAR(32)
);
INSERT INTO candidates
SELECT g.result, ((g.result - 1) DIV 3) + 1,
       CASE (g.result - 1) % 3 WHEN 0 THEN 'A' WHEN 1 THEN 'B' ELSE 'C' END,
       CONCAT('response text ', g.result),
       CASE (g.result - 1) % 3
            WHEN 0 THEN 300 + ((g.result - 1) DIV 3) % 50     -- A: long
            WHEN 1 THEN 120 + ((g.result - 1) DIV 3) % 50     -- B: short
            ELSE       200 + ((g.result - 1) DIV 3) % 50 END, -- C: medium
       CASE (g.result - 1) % 3 WHEN 0 THEN 'policy_v3' WHEN 1 THEN 'policy_v2' ELSE 'policy_v3' END
FROM generate_series(1, 60000) g;

-- 200 DEGENERATE candidates: slot C is a verbatim copy of slot A for prompts 1..200
UPDATE candidates SET response = CONCAT('response text ', (prompt_id - 1) * 3 + 1)
WHERE slot = 'C' AND prompt_id <= 200;

-- ---------------------------------------------------------------- annotations
-- 3 annotators vote on each pair. Deterministic voting pattern by pair_id % 10:
--   0,3,4,5,6 -> unanimous for A (the long one) : agreement 1.000
--   1,2       -> unanimous for B (the short one) : agreement 1.000
--   7,8       -> split (2-1), A wins             : agreement 0.667
--   9         -> no consensus (1-1-1 with a tie) : agreement 0.333
CREATE TABLE annotations (
    anno_id   BIGINT PRIMARY KEY,
    pair_id   BIGINT,
    prompt_id BIGINT,
    cand_a    BIGINT,          -- the "A side" of the pair
    cand_b    BIGINT,          -- the "B side"
    annotator VARCHAR(16),
    verdict   CHAR(1)          -- 'a' = a wins, 'b' = b wins, 't' = tie
);

-- main pairs: for every prompt, A vs B  -> pair_id = prompt_id
INSERT INTO annotations
SELECT g.result,
       ((g.result - 1) DIV 3) + 1,                       -- pair_id
       ((g.result - 1) DIV 3) + 1,                       -- prompt_id (same here)
       (((g.result - 1) DIV 3)) * 3 + 1,                 -- cand A
       (((g.result - 1) DIV 3)) * 3 + 2,                 -- cand B
       CONCAT('anno_', (g.result - 1) % 3 + 1),
       CASE
         WHEN (((g.result - 1) DIV 3) + 1) % 10 IN (1,2) THEN 'b'      -- unanimous: short one wins
         WHEN (((g.result - 1) DIV 3) + 1) % 10 <= 6 THEN 'a'          -- unanimous: long one wins
         WHEN (((g.result - 1) DIV 3) + 1) % 10 IN (7,8)
              THEN CASE WHEN (g.result - 1) % 3 = 2 THEN 'b' ELSE 'a' END   -- 2-1
         ELSE CASE (g.result - 1) % 3 WHEN 0 THEN 'a' WHEN 1 THEN 'b' ELSE 't' END  -- 1-1-1
       END
FROM generate_series(1, 60000) g;   -- 20,000 pairs x 3 annotators

-- CYCLE pairs: for prompts 1..500 add B-vs-C and C-vs-A, voted so that
-- A>B, B>C, C>A — a logically impossible preference cycle.
INSERT INTO annotations
SELECT 1000000 + g.result,
       100000 + ((g.result - 1) DIV 3) + 1,                 -- pair_id (B vs C)
       ((g.result - 1) DIV 3) + 1,
       (((g.result - 1) DIV 3)) * 3 + 2,                    -- cand B
       (((g.result - 1) DIV 3)) * 3 + 3,                    -- cand C
       CONCAT('anno_', (g.result - 1) % 3 + 1), 'a'         -- unanimous: B beats C
FROM generate_series(1, 1500) g;
INSERT INTO annotations
SELECT 2000000 + g.result,
       200000 + ((g.result - 1) DIV 3) + 1,                 -- pair_id (C vs A)
       ((g.result - 1) DIV 3) + 1,
       (((g.result - 1) DIV 3)) * 3 + 3,                    -- cand C
       (((g.result - 1) DIV 3)) * 3 + 1,                    -- cand A
       CONCAT('anno_', (g.result - 1) % 3 + 1), 'a'         -- unanimous: C beats A
FROM generate_series(1, 1500) g;

SELECT COUNT(*) AS annotation_rows FROM annotations;          -- 63000
SELECT COUNT(DISTINCT pair_id) AS pairs_annotated FROM annotations;   -- 21000


-- #############################################################################
-- 1. DERIVE the preference pairs from raw votes (majority + agreement rate)
-- #############################################################################
CREATE TABLE preference_pairs (
    pair_id     BIGINT PRIMARY KEY,
    prompt_id   BIGINT,
    chosen_id   BIGINT,
    rejected_id BIGINT,
    n_votes     INT,
    top_votes   INT,
    agree_rate  DOUBLE
);
INSERT INTO preference_pairs
SELECT v.pair_id, v.prompt_id,
       CASE WHEN v.a_votes >= v.b_votes THEN v.cand_a ELSE v.cand_b END,
       CASE WHEN v.a_votes >= v.b_votes THEN v.cand_b ELSE v.cand_a END,
       v.n_votes,
       GREATEST(v.a_votes, v.b_votes, v.t_votes),
       ROUND(GREATEST(v.a_votes, v.b_votes, v.t_votes) / v.n_votes, 3)
FROM (
  SELECT pair_id, MIN(prompt_id) AS prompt_id, MIN(cand_a) AS cand_a, MIN(cand_b) AS cand_b,
         COUNT(*) AS n_votes,
         SUM(CASE WHEN verdict = 'a' THEN 1 ELSE 0 END) AS a_votes,
         SUM(CASE WHEN verdict = 'b' THEN 1 ELSE 0 END) AS b_votes,
         SUM(CASE WHEN verdict = 't' THEN 1 ELSE 0 END) AS t_votes
  FROM annotations GROUP BY pair_id
) v;

SELECT COUNT(*) AS derived_pairs FROM preference_pairs;   -- 21000
SELECT agree_rate, COUNT(*) AS n FROM preference_pairs GROUP BY agree_rate ORDER BY agree_rate;


-- #############################################################################
-- 2. AUDIT + CURATE on a branch — the pool is never touched
-- #############################################################################
DATA BRANCH CREATE TABLE pairs_curated FROM preference_pairs;

-- ---- check 1: degenerate pairs (chosen and rejected are the same text) -----
SELECT COUNT(*) AS degenerate FROM pairs_curated p
JOIN candidates c1 ON p.chosen_id = c1.cand_id
JOIN candidates c2 ON p.rejected_id = c2.cand_id
WHERE c1.response = c2.response;

DELETE FROM pairs_curated WHERE pair_id IN (
  SELECT pair_id FROM (
    SELECT p.pair_id FROM pairs_curated p
    JOIN candidates c1 ON p.chosen_id = c1.cand_id
    JOIN candidates c2 ON p.rejected_id = c2.cand_id
    WHERE c1.response = c2.response
  ) t
);

-- ---- check 2: no consensus (annotators effectively coin-flipped) -----------
SELECT COUNT(*) AS no_consensus FROM pairs_curated WHERE agree_rate < 0.6;
DELETE FROM pairs_curated WHERE agree_rate < 0.6;

-- ---- check 3: preference CYCLES  A>B, B>C, C>A ----------------------------
-- Logically impossible; a reward model trained on these gets contradictory signal.
SELECT COUNT(DISTINCT p1.pair_id) AS pairs_in_cycles
FROM pairs_curated p1
JOIN pairs_curated p2 ON p1.prompt_id = p2.prompt_id AND p1.rejected_id = p2.chosen_id
JOIN pairs_curated p3 ON p2.prompt_id = p3.prompt_id AND p2.rejected_id = p3.chosen_id
WHERE p3.rejected_id = p1.chosen_id;

DELETE FROM pairs_curated WHERE pair_id IN (
  SELECT pair_id FROM (
    SELECT DISTINCT p1.pair_id
    FROM pairs_curated p1
    JOIN pairs_curated p2 ON p1.prompt_id = p2.prompt_id AND p1.rejected_id = p2.chosen_id
    JOIN pairs_curated p3 ON p2.prompt_id = p3.prompt_id AND p2.rejected_id = p3.chosen_id
    WHERE p3.rejected_id = p1.chosen_id
  ) t
);

-- ---- check 4: LENGTH BIAS audit (measure, do not silently "fix") ----------
-- If chosen is nearly always the longer response, the reward model learns
-- "longer = better" instead of "better = better".
SELECT
  COUNT(*)                                                        AS pairs,
  SUM(CASE WHEN c1.resp_len > c2.resp_len THEN 1 ELSE 0 END)      AS chosen_longer,
  ROUND(100.0 * SUM(CASE WHEN c1.resp_len > c2.resp_len THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_longer,
  ROUND(AVG(c1.resp_len - c2.resp_len), 1)                        AS avg_len_gap
FROM pairs_curated p
JOIN candidates c1 ON p.chosen_id = c1.cand_id
JOIN candidates c2 ON p.rejected_id = c2.cand_id;

SELECT COUNT(*) AS curated_pairs FROM pairs_curated;


-- #############################################################################
-- 3. THE RECEIPT — what this curation pass removed
-- #############################################################################
DATA BRANCH DIFF pairs_curated AGAINST preference_pairs OUTPUT SUMMARY;


-- #############################################################################
-- 4. ADJUDICATION — two reviewers re-judge the 2-1 splits on their own branches;
--    the overlap is materialised as a conflict list BEFORE merging, MERGE then
--    applies an explicit policy, and PICK takes only adjudicated rows back.
-- #############################################################################
DATA BRANCH CREATE TABLE pairs_alice FROM pairs_curated;
DATA BRANCH CREATE TABLE pairs_bob   FROM pairs_curated;

-- Alice overturns some 2-1 splits (swap chosen/rejected)
UPDATE pairs_alice
SET chosen_id = rejected_id, rejected_id = chosen_id
WHERE agree_rate < 0.7 AND pair_id % 4 = 0;

-- Bob overturns a partly overlapping set
UPDATE pairs_bob
SET chosen_id = rejected_id, rejected_id = chosen_id
WHERE agree_rate < 0.7 AND pair_id % 6 = 0;

DATA BRANCH DIFF pairs_alice AGAINST pairs_curated OUTPUT SUMMARY;
DATA BRANCH DIFF pairs_bob   AGAINST pairs_curated OUTPUT SUMMARY;

-- IMPORTANT: materialise the conflict list BEFORE merging.
-- `WHEN CONFLICT SKIP` skips conflicting rows by policy but does NOT return the
-- skipped pair_ids, so the only way to keep a record of "which rows both
-- reviewers touched, and what each said" is to query it here, while the
-- mainline still holds the pre-merge values.
SELECT COUNT(*) AS rows_both_reviewers_edited
FROM pairs_alice   a
JOIN pairs_bob     b ON a.pair_id = b.pair_id
JOIN pairs_curated m ON m.pair_id = a.pair_id
WHERE a.chosen_id <> m.chosen_id      -- Alice edited this row
  AND b.chosen_id <> m.chosen_id;     -- Bob edited it too

SELECT a.pair_id, a.chosen_id AS alice_chosen, b.chosen_id AS bob_chosen
FROM pairs_alice   a
JOIN pairs_bob     b ON a.pair_id = b.pair_id
JOIN pairs_curated m ON m.pair_id = a.pair_id
WHERE a.chosen_id <> m.chosen_id
  AND b.chosen_id <> m.chosen_id
ORDER BY a.pair_id LIMIT 10;
-- (CREATE TABLE conflicts_v1 AS SELECT ... to freeze the list with the version)

-- Alice merges first; Bob's overlapping rows are then handled by the declared
-- policy — SKIP keeps the mainline's already-adjudicated verdict in place.
DATA BRANCH MERGE pairs_alice INTO pairs_curated;
DATA BRANCH MERGE pairs_bob   INTO pairs_curated WHEN CONFLICT SKIP;

SELECT COUNT(*) AS pairs_after_adjudication FROM pairs_curated;


-- #############################################################################
-- 5. PUBLISH — register first, then snapshot, then bind the reward model
-- #############################################################################
CREATE TABLE dataset_registry (
    dataset_version   VARCHAR(32) PRIMARY KEY,
    metadata_snapshot VARCHAR(64),
    n_pairs           BIGINT,
    curate_rule       VARCHAR(256)
);
INSERT INTO dataset_registry
SELECT 'pref_v1', 'pref_v1', COUNT(*),
       'drop degenerate, agree_rate>=0.6, drop cycle pairs, length bias reported'
FROM pairs_curated;

CREATE TABLE reward_model_registry (
    rm_version      VARCHAR(32) PRIMARY KEY,
    pref_version    VARCHAR(32),
    pref_snapshot   VARCHAR(64),
    base_model      VARCHAR(64),
    code_commit     VARCHAR(64)
);
INSERT INTO reward_model_registry
VALUES ('rm_v1', 'pref_v1', 'pref_v1', 'policy_v3-base', '9c41ab');

DROP TABLE preference_pairs;
ALTER TABLE pairs_curated RENAME TO preference_pairs;
CREATE SNAPSHOT pref_v1 FOR DATABASE rlhf_pool;

-- the binding is inside the version
SELECT n_pairs FROM dataset_registry {SNAPSHOT='pref_v1'} WHERE dataset_version = 'pref_v1';
SELECT rm_version, pref_snapshot FROM reward_model_registry {SNAPSHOT='pref_v1'};
SELECT COUNT(*) AS v1_pairs FROM preference_pairs {SNAPSHOT='pref_v1'};


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS pref_v1;
DROP DATABASE IF EXISTS rlhf_pool;
