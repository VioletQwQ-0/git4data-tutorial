-- =============================================================================
-- Git4Data Tutorial — Part 14: Agent traces
-- A trace is an append-only log — so this part is NOT about diffing logs.
-- The problem it solves is different: an agent run's behaviour depends on the
-- memory and config it read AT THAT MOMENT. Without pinning those, a trace tells
-- you WHAT happened but never WHY, and a v1-vs-v2 comparison isn't apples to
-- apples. Here we pin the eval set, bind every run to the exact memory/config
-- version it ran against, and attribute a regression down to the failing step.
--
-- Everything is DETERMINISTIC (no rand()). Verified on MatrixOne 4.1.0.
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_trace_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS evalset_v1;
DROP SNAPSHOT IF EXISTS mem_r1;
DROP DATABASE IF EXISTS agent_trace;
CREATE DATABASE agent_trace;
USE agent_trace;

-- the memory the agent reads (kept small here; see Part 13 for the full story)
CREATE TABLE agent_memory (
    mem_id BIGINT PRIMARY KEY, subject_key VARCHAR(64),
    fact_key VARCHAR(64), fact_value VARCHAR(128)
);
INSERT INTO agent_memory
SELECT g.result, CONCAT('cust_', g.result), 'plan_tier',
       CASE WHEN g.result % 3 = 0 THEN 'pro' ELSE 'basic' END
FROM generate_series(1, 5000) g;

-- the frozen evaluation set — a comparison is only valid on identical inputs
CREATE TABLE eval_inputs (
    input_id BIGINT PRIMARY KEY, category VARCHAR(24), question VARCHAR(256)
);
INSERT INTO eval_inputs
SELECT g.result,
       CASE g.result % 4 WHEN 0 THEN 'billing' WHEN 1 THEN 'technical'
                         WHEN 2 THEN 'account' ELSE 'general' END,
       CONCAT('eval question ', g.result)
FROM generate_series(1, 2000) g;

CREATE SNAPSHOT evalset_v1 FOR TABLE agent_trace eval_inputs;
CREATE SNAPSHOT mem_r1     FOR TABLE agent_trace agent_memory;

-- ---------------------------------------------------------------- trace tables
CREATE TABLE runs (
    run_id        BIGINT PRIMARY KEY,
    agent_version VARCHAR(16),
    input_id      BIGINT,
    memory_snapshot VARCHAR(32),   -- WHICH memory version this run read  <- the point
    config_version  VARCHAR(16),
    status        VARCHAR(12),     -- ok / failed
    n_steps       INT,
    total_tokens  INT,
    latency_ms    INT
);
CREATE TABLE run_steps (
    step_id   BIGINT PRIMARY KEY,
    run_id    BIGINT,
    step_no   INT,
    step_type VARCHAR(12),         -- llm / tool
    tool_name VARCHAR(32),
    ok        TINYINT,
    latency_ms INT
);

-- ---- agent v1 over the frozen eval set: fails only on a few hard inputs -----
INSERT INTO runs
SELECT g.result, 'v1', g.result, 'mem_r1', 'cfg_7',
       CASE WHEN g.result % 40 = 0 THEN 'failed' ELSE 'ok' END,
       4, 1200 + (g.result % 300), 900 + (g.result % 400)
FROM generate_series(1, 2000) g;

-- ---- agent v2: same inputs, same memory — but a new retrieval path makes the
--      search_kb tool fail on 'technical' questions (the regression)
INSERT INTO runs
SELECT 100000 + g.result, 'v2', g.result, 'mem_r1', 'cfg_8',
       CASE WHEN g.result % 40 = 0 THEN 'failed'
            WHEN g.result % 4 = 1 THEN 'failed'          -- 'technical' now breaks
            ELSE 'ok' END,
       4, 1500 + (g.result % 300), 1100 + (g.result % 400)
FROM generate_series(1, 2000) g;

-- 4 steps per run; the failing step is the search_kb tool call (step 3)
INSERT INTO run_steps
SELECT g.result,
       ((g.result - 1) DIV 4) + 1,
       ((g.result - 1) % 4) + 1,
       CASE WHEN (g.result - 1) % 4 = 2 THEN 'tool' ELSE 'llm' END,
       CASE WHEN (g.result - 1) % 4 = 2 THEN 'search_kb' ELSE NULL END,
       CASE WHEN (g.result - 1) % 4 = 2 AND (((g.result - 1) DIV 4) + 1) % 40 = 0 THEN 0 ELSE 1 END,
       120 + (g.result % 200)
FROM generate_series(1, 8000) g;

INSERT INTO run_steps
SELECT 500000 + g.result,
       100000 + ((g.result - 1) DIV 4) + 1,
       ((g.result - 1) % 4) + 1,
       CASE WHEN (g.result - 1) % 4 = 2 THEN 'tool' ELSE 'llm' END,
       CASE WHEN (g.result - 1) % 4 = 2 THEN 'search_kb' ELSE NULL END,
       CASE WHEN (g.result - 1) % 4 = 2
                 AND ((((g.result - 1) DIV 4) + 1) % 40 = 0 OR (((g.result - 1) DIV 4) + 1) % 4 = 1)
            THEN 0 ELSE 1 END,
       150 + (g.result % 200)
FROM generate_series(1, 8000) g;

SELECT COUNT(*) AS total_runs FROM runs;        -- 4000
SELECT COUNT(*) AS total_steps FROM run_steps;  -- 16000


-- #############################################################################
-- 1. THE HEADLINE — success rate, cost and latency per agent version
-- #############################################################################
SELECT agent_version,
       COUNT(*) AS runs,
       SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) AS ok_runs,
       ROUND(100.0 * SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) / COUNT(*), 1) AS ok_pct,
       ROUND(AVG(total_tokens), 0) AS avg_tokens,
       ROUND(AVG(latency_ms), 0)   AS avg_latency_ms
FROM runs GROUP BY agent_version ORDER BY agent_version;


-- #############################################################################
-- 2. ATTRIBUTION — which inputs regressed, and in which category
-- #############################################################################
SELECT COUNT(*) AS regressed_inputs
FROM runs a JOIN runs b ON a.input_id = b.input_id
WHERE a.agent_version = 'v1' AND b.agent_version = 'v2'
  AND a.status = 'ok' AND b.status = 'failed';

SELECT e.category, COUNT(*) AS regressed
FROM runs a
JOIN runs b ON a.input_id = b.input_id
JOIN eval_inputs e ON e.input_id = a.input_id
WHERE a.agent_version = 'v1' AND b.agent_version = 'v2'
  AND a.status = 'ok' AND b.status = 'failed'
GROUP BY e.category ORDER BY regressed DESC;


-- #############################################################################
-- 3. DOWN TO THE STEP — which tool broke, per version
-- #############################################################################
SELECT r.agent_version, s.tool_name,
       COUNT(*) AS calls,
       SUM(CASE WHEN s.ok = 0 THEN 1 ELSE 0 END) AS failures,
       ROUND(100.0 * SUM(CASE WHEN s.ok = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS fail_pct
FROM run_steps s JOIN runs r ON s.run_id = r.run_id
WHERE s.step_type = 'tool'
GROUP BY r.agent_version, s.tool_name ORDER BY r.agent_version;


-- #############################################################################
-- 4. REPLAY — the trace says WHAT happened; the pinned memory says WHY.
--    Every run recorded which memory version it read, so months later we can
--    reconstruct exactly what the agent knew at that moment.
-- #############################################################################
SELECT r.run_id, r.memory_snapshot, m.fact_key, m.fact_value
FROM runs r
JOIN agent_memory {SNAPSHOT='mem_r1'} m ON m.subject_key = CONCAT('cust_', r.input_id)
WHERE r.run_id = 100001;

-- the eval set is frozen too, so v1 and v2 provably answered the same questions
SELECT COUNT(*) AS eval_inputs_at_v1 FROM eval_inputs {SNAPSHOT='evalset_v1'};


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS evalset_v1;
DROP SNAPSHOT IF EXISTS mem_r1;
DROP DATABASE IF EXISTS agent_trace;
