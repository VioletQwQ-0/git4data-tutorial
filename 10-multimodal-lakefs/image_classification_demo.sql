-- =============================================================================
-- Git4Data Part 10 — image-classification training data (lakeFS × MatrixOne)
-- The image FILES live in lakeFS; the METADATA (which sample points to which
-- file version, its class label, hashes, source, license) lives in MatrixOne.
-- This demo exercises the metadata side: WAP ingest, exact + perceptual dedup,
-- benchmark decontamination, an integrity check, relabel via branch/merge, then
-- a curated release that pins the metadata snapshot together with a lakeFS commit.
-- Task: a content-safety image classifier (label = safe / nsfw).
-- Verified on MatrixOne 4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < image_classification_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS ic_dataset_v1;
DROP DATABASE IF EXISTS img_cls;
CREATE DATABASE img_cls;
USE img_cls;

-- The METADATA. One row per image. The file bytes are NOT here — only a pointer
-- (object_uri) plus the lakeFS commit that pins it, plus everything you query on:
-- hashes, the class label, provenance, license.
CREATE TABLE samples (
    sample_id     BIGINT PRIMARY KEY,
    object_uri    VARCHAR(512),   -- lakeFS path (a pointer, not the file)
    object_commit VARCHAR(64),    -- the lakeFS commit that pins this file
    content_hash  VARCHAR(64),    -- sha256 of the file (exact-dup key)
    phash         VARCHAR(64),    -- perceptual hash (near-dup key)
    label         VARCHAR(16),    -- class: safe / nsfw  (NULL = not labeled yet)
    source        VARCHAR(32),    -- provenance
    license       VARCHAR(16),
    ingest_batch  VARCHAR(32)
);

-- 50,000 base images; content_hash and phash both unique here.
INSERT INTO samples
SELECT g.result,
       CONCAT('lakefs://media/main/img/', g.result, '.jpg'),
       'commit-2026w29-a1b2c3',
       CONCAT('sha256-', g.result),
       CONCAT('ph-', g.result),
       CASE WHEN g.result % 50 = 0 THEN 'nsfw' ELSE 'safe' END,
       CASE WHEN g.result % 3 = 0 THEN 'crawl_web'
            WHEN g.result % 3 = 1 THEN 'partner' ELSE 'internal' END,
       CASE WHEN g.result % 7 = 0 THEN 'unknown'
            WHEN g.result % 2 = 0 THEN 'cc-by' ELSE 'cc0' END,
       '2026w29'
FROM generate_series(1, 50000) g;

-- 3,000 EXACT duplicates: same file re-crawled at a different URL
--   -> same content_hash + same phash as images 1..3000, new sample_id/uri.
INSERT INTO samples
SELECT 100000 + g.result,
       CONCAT('lakefs://media/main/mirror/', g.result, '.jpg'),
       'commit-2026w29-a1b2c3',
       CONCAT('sha256-', g.result),
       CONCAT('ph-', g.result),
       'safe', 'crawl_web', 'unknown', '2026w29'
FROM generate_series(1, 3000) g;

-- 2,000 NEAR duplicates: visually the same, bytes differ slightly
--   -> DIFFERENT content_hash, but SAME phash as images 3001..5000.
INSERT INTO samples
SELECT 200000 + g.result,
       CONCAT('lakefs://media/main/aug/', g.result, '.jpg'),
       'commit-2026w29-a1b2c3',
       CONCAT('sha256-near-', g.result),
       CONCAT('ph-', 3000 + g.result),
       'safe', 'partner', 'cc-by', '2026w29'
FROM generate_series(1, 2000) g;

-- 300 not-yet-labeled images (label came back empty from the labeling pass).
UPDATE samples SET label = NULL WHERE sample_id BETWEEN 400 AND 699;

SELECT COUNT(*) AS total_rows FROM samples;   -- 55000


-- #############################################################################
-- 1. INGEST — a new batch lands on a metadata BRANCH (files went to a lakeFS
--    branch separately); audit on the branch; publish only on pass. WAP.
-- #############################################################################
DATA BRANCH CREATE TABLE samples_stage FROM samples;
INSERT INTO samples_stage
SELECT 300000 + g.result,
       CONCAT('lakefs://media/ingest-2026w30/img/', g.result, '.jpg'),
       'commit-2026w30-d4e5f6',
       CONCAT('sha256-w30-', g.result),
       CONCAT('ph-w30-', g.result),
       CASE WHEN g.result % 20 = 0 THEN NULL ELSE 'safe' END,   -- some arrive unlabeled
       'crawl_web',
       CASE WHEN g.result % 5 = 0 THEN 'unknown' ELSE 'cc0' END,
       '2026w30'
FROM generate_series(1, 5000) g;

-- audit the incoming batch on the branch (each must be acceptable before merge)
SELECT
  SUM(CASE WHEN object_uri IS NULL OR object_commit IS NULL THEN 1 ELSE 0 END) AS missing_pointer,
  SUM(CASE WHEN label IS NULL THEN 1 ELSE 0 END)                               AS missing_label,
  SUM(CASE WHEN license = 'unknown' THEN 1 ELSE 0 END)                         AS unknown_license
FROM samples_stage WHERE ingest_batch = '2026w30';
DATA BRANCH DIFF samples_stage AGAINST samples OUTPUT SUMMARY;   -- INSERTED 5000
DATA BRANCH MERGE samples_stage INTO samples;
SELECT COUNT(*) AS after_ingest FROM samples;   -- 60000


-- #############################################################################
-- 2. DEDUP — exact (content_hash) and perceptual near-dup (phash), pure SQL on
--    the metadata, at scale, without touching a single file in lakeFS.
-- #############################################################################
SELECT COUNT(*) AS exact_dup_groups FROM (
  SELECT content_hash FROM samples GROUP BY content_hash HAVING COUNT(*) > 1
) t;   -- 3000
SELECT COUNT(*) AS near_dup_groups FROM (
  SELECT phash FROM samples GROUP BY phash HAVING COUNT(DISTINCT content_hash) > 1
) t;   -- 2000


-- #############################################################################
-- 3. DECONTAMINATION — remove training images that overlap an eval benchmark.
-- #############################################################################
CREATE TABLE eval_hashes (content_hash VARCHAR(64) PRIMARY KEY);
INSERT INTO eval_hashes SELECT CONCAT('sha256-', g.result)
FROM generate_series(100, 599) g;   -- 500 benchmark images

SELECT COUNT(*) AS contaminated FROM samples s
WHERE EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash);
-- 1000: images 100..599 AND their re-crawled mirrors


-- #############################################################################
-- 4. INTEGRITY — every training sample must have a label and a live pointer.
-- #############################################################################
SELECT COUNT(*) AS unlabeled FROM samples WHERE label IS NULL;              -- 550
SELECT COUNT(*) AS dangling_pointer FROM samples
WHERE object_uri IS NULL OR object_commit IS NULL;                         -- 0


-- #############################################################################
-- 5. RELABEL — the metadata evolves (safety re-scoring) while files stay
--    immutable. A reviewer flips 1,000 labels on a branch, merged back.
-- #############################################################################
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review SET label = 'nsfw'
WHERE sample_id BETWEEN 1000 AND 1999 AND label = 'safe';
DATA BRANCH DIFF samples_review AGAINST samples OUTPUT SUMMARY;   -- UPDATED ~980
DATA BRANCH MERGE samples_review INTO samples;


-- #############################################################################
-- 6. DATA CURATION + RELEASE — curate a clean subset into dataset_membership,
--    then pin the METADATA snapshot together with the lakeFS COMMIT.
--    Reproducible training set = metadata snapshot  ×  lakeFS commit.
-- #############################################################################
CREATE TABLE dataset_membership (
    sample_id  BIGINT PRIMARY KEY,
    split_name VARCHAR(16),
    curate_rule VARCHAR(256)
);
-- keep labeled, licensed, non-eval samples; drop exact dups (lowest id per hash)
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

SELECT split_name, COUNT(*) FROM dataset_membership GROUP BY split_name ORDER BY split_name;

CREATE TABLE dataset_registry (
    dataset_version  VARCHAR(32) PRIMARY KEY,
    metadata_snapshot VARCHAR(64),   -- the MatrixOne snapshot (metadata version)
    lakefs_repo      VARCHAR(64),
    lakefs_commit    VARCHAR(64),    -- the lakeFS commit (file version)
    n_samples        BIGINT,
    note             VARCHAR(128)
);
-- Register the binding FIRST, then snapshot — so the lakeFS commit is INSIDE the
-- metadata snapshot (not just in the mutable live database). The snapshot name is
-- chosen up front, so the row can name the snapshot it is about to be frozen into.
INSERT INTO dataset_registry
SELECT 'ic_v1', 'ic_dataset_v1', 'media', 'commit-2026w30-d4e5f6', COUNT(*),
       'metadata snapshot x lakeFS commit = reproducible training set'
FROM dataset_membership;
CREATE SNAPSHOT ic_dataset_v1 FOR DATABASE img_cls;

-- the binding is now frozen INSIDE the snapshot (not just the live db):
SELECT lakefs_commit FROM dataset_registry {SNAPSHOT='ic_dataset_v1'}
WHERE dataset_version = 'ic_v1';   -- commit-2026w30-d4e5f6

-- reproduce the exact train split months later, from the pinned metadata version
SELECT COUNT(*) AS train_rows_v1
FROM samples {SNAPSHOT='ic_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='ic_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train';


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS ic_dataset_v1;
DROP DATABASE IF EXISTS img_cls;
