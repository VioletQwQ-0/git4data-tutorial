-- =============================================================================
-- Git4Data Tutorial — Part 11: SFT data curation
-- An SFT set is a table of (instruction, input, response) records. Every cut a
-- curator makes — dedup, quality filter, decontamination, safety, mix balance —
-- is a row-level edit. This demo does the whole pass on a BRANCH, keeps a DIFF
-- as the receipt for every cut, then publishes one atomic MERGE + snapshot.
-- Verified on MatrixOne 4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < sft_curation_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS sft_v1;
DROP SNAPSHOT IF EXISTS sft_v2;
DROP DATABASE IF EXISTS sft_pool;
CREATE DATABASE sft_pool;
USE sft_pool;

-- The SFT pool. Text lives IN the database — unlike Part 10's image files,
-- these records are structured enough to query, dedup and filter with SQL.
CREATE TABLE sft_records (
    record_id     BIGINT PRIMARY KEY,
    conv_id       BIGINT,          -- a multi-turn conversation groups several rows
    turn_no       INT,             -- 1,2,3... within the conversation
    instruction   VARCHAR(512),
    response      VARCHAR(1024),
    norm_hash     VARCHAR(64),     -- hash of the normalized instruction (near-dup key)
    exact_hash    VARCHAR(64),     -- hash of instruction+response (exact-dup key)
    domain        VARCHAR(24),     -- code / math / chat / safety ...
    source        VARCHAR(32),     -- which vendor / synthetic run it came from
    lang          VARCHAR(8),
    resp_len      INT,
    quality_score DOUBLE,          -- from a reward model / heuristic scorer
    is_safe       TINYINT,         -- 1 = passed the safety classifier
    ingest_batch  VARCHAR(32)
);

-- ---------------------------------------------------------------- 60,000 single-turn
INSERT INTO sft_records
SELECT g.result, g.result, 1,
       CONCAT('task ', g.result, ': explain the concept'),
       CONCAT('answer body for ', g.result),
       CONCAT('nh-', g.result),
       CONCAT('eh-', g.result),
       CASE WHEN g.result % 4 = 0 THEN 'code' WHEN g.result % 4 = 1 THEN 'math'
            WHEN g.result % 4 = 2 THEN 'chat' ELSE 'safety' END,
       CASE WHEN g.result % 3 = 0 THEN 'vendor_a'
            WHEN g.result % 3 = 1 THEN 'synthetic_gpt' ELSE 'human_written' END,
       CASE WHEN g.result % 10 = 0 THEN 'en' ELSE 'zh' END,
       20 + (g.result % 400),
       round(0.3 + (g.result % 70) / 100.0, 3),
       CASE WHEN g.result % 500 = 0 THEN 0 ELSE 1 END,
       '2026w30'
FROM generate_series(1, 60000) g;

-- 4,000 EXACT duplicates (the same pair scraped twice / shipped by two vendors)
INSERT INTO sft_records
SELECT 200000 + g.result, 200000 + g.result, 1,
       CONCAT('task ', g.result, ': explain the concept'),
       CONCAT('answer body for ', g.result),
       CONCAT('nh-', g.result),
       CONCAT('eh-', g.result),          -- same exact_hash as 1..4000
       'chat', 'vendor_b', 'zh', 20 + (g.result % 400),
       round(0.3 + (g.result % 70) / 100.0, 3), 1, '2026w30'
FROM generate_series(1, 4000) g;

-- 3,000 NEAR duplicates: same instruction after normalization (punctuation /
-- casing / whitespace differ), DIFFERENT response -> same norm_hash, new exact_hash
INSERT INTO sft_records
SELECT 300000 + g.result, 300000 + g.result, 1,
       CONCAT('Task ', 10000 + g.result, ': Explain the concept!!'),
       CONCAT('a differently worded answer for ', 10000 + g.result),
       CONCAT('nh-', 10000 + g.result),  -- collides with records 10001..13000
       CONCAT('eh-near-', g.result),
       'math', 'synthetic_gpt', 'zh', 20 + (g.result % 400),
       round(0.3 + (g.result % 70) / 100.0, 3), 1, '2026w30'
FROM generate_series(1, 3000) g;

-- 2,000 multi-turn conversations (3 turns each) — turns must stay together
INSERT INTO sft_records
SELECT 400000 + g.result,
       500000 + ((g.result - 1) DIV 3),          -- 3 rows share one conv_id
       ((g.result - 1) % 3) + 1,
       CONCAT('multi-turn q', g.result), CONCAT('multi-turn a', g.result),
       CONCAT('nh-mt-', g.result), CONCAT('eh-mt-', g.result),
       'chat', 'human_written', 'zh', 50 + (g.result % 300),
       round(0.5 + (g.result % 50) / 100.0, 3), 1, '2026w30'
FROM generate_series(1, 6000) g;

-- 800 too-short / empty responses (truncated generations)
UPDATE sft_records SET response = '', resp_len = 0
WHERE record_id BETWEEN 50000 AND 50799;

-- 150 truncated turns INSIDE multi-turn conversations: one turn of each of these
-- conversations will be cut by the quality gate, leaving the conversation broken.
UPDATE sft_records SET response = '', resp_len = 0
WHERE record_id BETWEEN 400002 AND 400450 AND turn_no = 2;

SELECT COUNT(*) AS pool_rows FROM sft_records;   -- 73000


-- #############################################################################
-- CURATE ON A BRANCH — the pool is never touched until the pass is approved.
-- #############################################################################
DATA BRANCH CREATE TABLE sft_curated FROM sft_records;

-- ---- cut 1: exact duplicates (keep the lowest record_id per exact_hash) -----
SELECT COUNT(*) AS exact_dup_rows FROM sft_curated c
WHERE c.record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2 WHERE c2.exact_hash = c.exact_hash);
DELETE FROM sft_curated
WHERE record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2 WHERE c2.exact_hash = sft_curated.exact_hash);

-- ---- cut 2: near duplicates by normalized instruction ----------------------
SELECT COUNT(*) AS near_dup_rows FROM sft_curated c
WHERE c.record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2 WHERE c2.norm_hash = c.norm_hash);
DELETE FROM sft_curated
WHERE record_id > (SELECT MIN(c2.record_id) FROM sft_curated c2 WHERE c2.norm_hash = sft_curated.norm_hash);

-- ---- cut 3: quality gate (empty / truncated / low reward score) -------------
SELECT COUNT(*) AS low_quality FROM sft_curated
WHERE resp_len < 10 OR quality_score < 0.35;
DELETE FROM sft_curated WHERE resp_len < 10 OR quality_score < 0.35;

-- ---- cut 4: safety ---------------------------------------------------------
SELECT COUNT(*) AS unsafe FROM sft_curated WHERE is_safe = 0;
DELETE FROM sft_curated WHERE is_safe = 0;

-- ---- cut 5: benchmark decontamination (exact prompt-hash overlap) ----------
CREATE TABLE eval_prompts (norm_hash VARCHAR(64) PRIMARY KEY);
INSERT INTO eval_prompts SELECT CONCAT('nh-', g.result) FROM generate_series(100, 899) g;  -- 800 eval prompts

SELECT COUNT(*) AS contaminated FROM sft_curated c
WHERE EXISTS (SELECT 1 FROM eval_prompts e WHERE e.norm_hash = c.norm_hash);
DELETE FROM sft_curated
WHERE EXISTS (SELECT 1 FROM eval_prompts e WHERE e.norm_hash = sft_curated.norm_hash);

-- ---- cut 6: multi-turn integrity — a conversation must keep ALL its turns ---
-- (if any turn of a conv was cut above, drop the whole conversation)
SELECT COUNT(*) AS broken_conv_rows FROM sft_curated c
WHERE c.conv_id IN (
  SELECT conv_id FROM sft_curated GROUP BY conv_id HAVING COUNT(*) < MAX(turn_no)
);
DELETE FROM sft_curated WHERE conv_id IN (
  SELECT conv_id FROM (SELECT conv_id FROM sft_curated GROUP BY conv_id HAVING COUNT(*) < MAX(turn_no)) t
);

SELECT COUNT(*) AS curated_rows FROM sft_curated;


-- #############################################################################
-- THE RECEIPT — one DIFF says exactly what this curation pass removed.
-- #############################################################################
DATA BRANCH DIFF sft_curated AGAINST sft_records OUTPUT SUMMARY;

-- and the mix you are about to ship (domain balance is a curation decision)
SELECT domain, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM sft_curated), 1) AS pct
FROM sft_curated GROUP BY domain ORDER BY domain;
SELECT source, COUNT(*) AS n FROM sft_curated GROUP BY source ORDER BY source;


-- #############################################################################
-- PUBLISH — atomic merge, then register + snapshot (registry BEFORE snapshot
-- so the binding is frozen inside the version).
-- #############################################################################
CREATE TABLE dataset_registry (
    dataset_version VARCHAR(32) PRIMARY KEY,
    metadata_snapshot VARCHAR(64),
    n_records       BIGINT,
    curate_rule     VARCHAR(256)
);
INSERT INTO dataset_registry
SELECT 'sft_v1', 'sft_v1', COUNT(*),
       'exact+near dedup, len>=10, score>=0.35, safe only, eval-decontam, whole-conv'
FROM sft_curated;

DROP TABLE sft_records;
ALTER TABLE sft_curated RENAME TO sft_records;   -- publish the curated pool
CREATE SNAPSHOT sft_v1 FOR DATABASE sft_pool;

SELECT n_records FROM dataset_registry {SNAPSHOT='sft_v1'} WHERE dataset_version = 'sft_v1';


-- #############################################################################
-- v2 — a later pass tightens the quality bar; DIFF shows what THAT round cut.
-- #############################################################################
DATA BRANCH CREATE TABLE sft_v2_wip FROM sft_records;
DELETE FROM sft_v2_wip WHERE quality_score < 0.50;
DATA BRANCH DIFF sft_v2_wip AGAINST sft_records OUTPUT SUMMARY;   -- the v2 receipt
SELECT COUNT(*) AS v2_rows FROM sft_v2_wip;

-- v1 stays reproducible, bit for bit
SELECT COUNT(*) AS v1_rows FROM sft_records {SNAPSHOT='sft_v1'};


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS sft_v1;
DROP SNAPSHOT IF EXISTS sft_v2;
DROP DATABASE IF EXISTS sft_pool;
