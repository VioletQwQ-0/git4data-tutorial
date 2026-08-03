-- =============================================================================
-- Git4Data Tutorial — Part 13: Agent memory
-- An agent's long-term memory is a table of facts it wrote about the world.
-- Unlike training data, it is written by the AGENT ITSELF, continuously, with
-- no human in the loop — so a single bad session can quietly poison it forever.
-- This demo puts memory writes behind a branch: audit what a session wants to
-- remember, merge only what passes, and roll back a poisoned session entirely.
--
-- Everything is DETERMINISTIC (no rand()), so every number reproduces.
-- Verified on MatrixOne 4.1.0.
--     docker run -d -p 6001:6001 --name matrixone matrixorigin/matrixone:4.1.0
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_memory_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS mem_v1;
DROP SNAPSHOT IF EXISTS mem_before_session;
DROP DATABASE IF EXISTS agent_mem;
CREATE DATABASE agent_mem;
USE agent_mem;

-- The agent's long-term memory. One row = one fact the agent believes.
-- Note the provenance columns: WHICH run wrote this, WHEN, and how sure it was.
CREATE TABLE agent_memory (
    mem_id      BIGINT PRIMARY KEY,
    subject_key VARCHAR(64),    -- who/what this fact is about (e.g. customer id)
    fact_key    VARCHAR(64),    -- which attribute (e.g. 'preferred_channel')
    fact_value  VARCHAR(256),
    confidence  DOUBLE,         -- how sure the agent was when it wrote this
    source_run  VARCHAR(32),    -- the run that wrote it  <- provenance
    written_at  DATETIME,
    status      VARCHAR(16)     -- active / superseded
);

-- 40,000 facts already accumulated: 8,000 customers x 5 attributes.
INSERT INTO agent_memory
SELECT g.result,
       CONCAT('cust_', ((g.result - 1) % 8000) + 1),
       CASE (g.result - 1) DIV 8000
            WHEN 0 THEN 'preferred_channel' WHEN 1 THEN 'plan_tier'
            WHEN 2 THEN 'timezone'          WHEN 3 THEN 'language'
            ELSE 'open_issue' END,
       CONCAT('value_', ((g.result - 1) % 8000) + 1),
       0.70 + ((g.result % 25) / 100.0),
       CONCAT('run_', 1000 + (g.result % 400)),
       DATE_ADD('2026-06-01', INTERVAL (g.result % 40) DAY),
       'active'
FROM generate_series(1, 40000) g;

SELECT COUNT(*) AS memory_facts FROM agent_memory;   -- 40000

-- Pin the memory before this session runs. This is the rollback point.
CREATE SNAPSHOT mem_before_session FOR TABLE agent_mem agent_memory;


-- #############################################################################
-- 1. A SESSION WRITES MEMORY — on a branch, not straight into the mainline
-- #############################################################################
DATA BRANCH CREATE TABLE memory_staging FROM agent_memory;

-- The session (run_9001) proposes 3,000 new facts. Deterministically seeded
-- with the problems real agent sessions actually produce:
--   * every 10th fact CONTRADICTS an existing active fact (same subject+key,
--     different value)
--   * every 7th fact is written with low confidence (a guess)
--   * every 25th fact has no source run recorded (untraceable)
INSERT INTO memory_staging
SELECT 500000 + g.result,
       CONCAT('cust_', ((g.result - 1) % 8000) + 1),
       CASE WHEN g.result % 10 = 0 THEN 'preferred_channel'    -- collides on purpose
            ELSE CONCAT('note_', g.result % 50) END,
       CONCAT('new_value_', g.result),
       CASE WHEN g.result % 7 = 0 THEN 0.25 ELSE 0.85 END,
       CASE WHEN g.result % 25 = 0 THEN NULL ELSE 'run_9001' END,
       '2026-07-20 10:00:00',
       'active'
FROM generate_series(1, 3000) g;

-- what this session wants to remember, before anything is accepted
DATA BRANCH DIFF memory_staging AGAINST agent_memory OUTPUT SUMMARY;   -- INSERTED 3000


-- #############################################################################
-- 2. AUDIT the session's proposed memory (the gate)
-- #############################################################################
-- ---- a) contradictions: a new fact disagrees with an ACTIVE existing fact ---
SELECT COUNT(*) AS contradictions
FROM memory_staging s
JOIN agent_memory m
  ON s.subject_key = m.subject_key AND s.fact_key = m.fact_key
WHERE s.mem_id >= 500000
  AND m.status = 'active'
  AND s.fact_value <> m.fact_value;

-- ---- b) low-confidence guesses -------------------------------------------
SELECT COUNT(*) AS low_confidence FROM memory_staging
WHERE mem_id >= 500000 AND confidence < 0.5;

-- ---- c) untraceable writes (no source run) --------------------------------
SELECT COUNT(*) AS untraceable FROM memory_staging
WHERE mem_id >= 500000 AND source_run IS NULL;

-- Reject the untrustworthy ones; keep the rest.
DELETE FROM memory_staging WHERE mem_id >= 500000 AND (confidence < 0.5 OR source_run IS NULL);

-- Contradictions are NOT deleted — they are resolved: the old fact is marked
-- superseded, so the memory keeps its history instead of silently overwriting.
UPDATE memory_staging m
SET status = 'superseded'
WHERE m.mem_id < 500000 AND m.status = 'active'
  AND EXISTS (SELECT 1 FROM memory_staging s
              WHERE s.mem_id >= 500000
                AND s.subject_key = m.subject_key AND s.fact_key = m.fact_key
                AND s.fact_value <> m.fact_value);

DATA BRANCH DIFF memory_staging AGAINST agent_memory OUTPUT SUMMARY;   -- the gated receipt
SELECT COUNT(*) AS accepted_new FROM memory_staging WHERE mem_id >= 500000;

DATA BRANCH MERGE memory_staging INTO agent_memory;
SELECT COUNT(*) AS memory_after_session FROM agent_memory;
SELECT status, COUNT(*) AS n FROM agent_memory GROUP BY status ORDER BY status;


-- #############################################################################
-- 3. A POISONED SESSION — and a clean rollback
-- #############################################################################
CREATE SNAPSHOT mem_v1 FOR TABLE agent_mem agent_memory;   -- known-good point

-- run_9002 misreads a bulk import and overwrites 5,000 facts with garbage
UPDATE agent_memory
SET fact_value = 'GARBAGE', confidence = 0.99, source_run = 'run_9002'
WHERE mem_id BETWEEN 1 AND 5000;

-- the damage, measured against the known-good version
DATA BRANCH DIFF agent_memory AGAINST agent_memory {SNAPSHOT='mem_v1'} OUTPUT SUMMARY;
SELECT COUNT(*) AS poisoned FROM agent_memory WHERE fact_value = 'GARBAGE';

-- roll the whole memory back to the known-good point
RESTORE TABLE agent_mem.agent_memory {SNAPSHOT = mem_v1};
SELECT COUNT(*) AS poisoned_after_restore FROM agent_memory WHERE fact_value = 'GARBAGE';   -- 0
SELECT COUNT(*) AS memory_after_restore FROM agent_memory;


-- #############################################################################
-- 4. WHAT DID ONE RUN REMEMBER? — provenance makes this a single query
-- #############################################################################
SELECT source_run, COUNT(*) AS facts_written
FROM agent_memory WHERE source_run = 'run_9001' GROUP BY source_run;

-- and the memory a specific agent version was operating with, months later
SELECT COUNT(*) AS facts_at_mem_v1 FROM agent_memory {SNAPSHOT='mem_v1'};


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS mem_v1;
DROP SNAPSHOT IF EXISTS mem_before_session;
DROP DATABASE IF EXISTS agent_mem;
