-- =============================================================================
-- Git4Data Tutorial — Part 15 (finale): Agent self-evolution
-- If an agent's BEHAVIOUR lives in a table (prompts, tool policy, thresholds),
-- then "the agent improving itself" becomes an ordinary data workflow:
--   propose on a branch -> evaluate -> merge the winner -> drop the losers
--   -> and roll back instantly when production disagrees.
-- Three candidates are proposed, evaluated against a frozen eval set, gated on
-- metrics, and exactly one is promoted. Then a production regression is undone.
--
-- Everything is DETERMINISTIC (no rand()). Verified on MatrixOne 4.1.0.
--     mysql -h 127.0.0.1 -P 6001 -u root -p111 < agent_evolution_demo.sql
-- =============================================================================

DROP SNAPSHOT IF EXISTS cfg_v7;
DROP SNAPSHOT IF EXISTS cfg_v8;
DROP DATABASE IF EXISTS agent_eco;
CREATE DATABASE agent_eco;
USE agent_eco;

-- The agent's behaviour, as data. Changing a row changes how the agent acts.
CREATE TABLE agent_config (
    config_key   VARCHAR(48) PRIMARY KEY,
    config_value VARCHAR(256),
    value_type   VARCHAR(12),
    changed_by   VARCHAR(32),
    rationale    VARCHAR(256)
);
INSERT INTO agent_config VALUES
 ('system_prompt_version', 'sp_v3',  'string', 'human',  'baseline in production'),
 ('retrieval_top_k',       '5',      'int',    'human',  'baseline'),
 ('temperature',           '0.7',    'float',  'human',  'baseline'),
 ('tool_timeout_ms',       '2000',   'int',    'human',  'baseline'),
 ('max_steps',             '8',      'int',    'human',  'baseline'),
 ('escalate_threshold',    '0.45',   'float',  'human',  'baseline');

CREATE SNAPSHOT cfg_v7 FOR DATABASE agent_eco;   -- the production baseline

-- the frozen eval set every candidate must be measured on
CREATE TABLE eval_inputs (input_id BIGINT PRIMARY KEY, category VARCHAR(24));
INSERT INTO eval_inputs
SELECT g.result, CASE g.result % 4 WHEN 0 THEN 'billing' WHEN 1 THEN 'technical'
                                   WHEN 2 THEN 'account' ELSE 'general' END
FROM generate_series(1, 2000) g;

CREATE TABLE eval_results (
    candidate    VARCHAR(24),
    input_id     BIGINT,
    ok           TINYINT,
    total_tokens INT,
    PRIMARY KEY (candidate, input_id)
);

-- baseline measured performance
INSERT INTO eval_results
SELECT 'baseline', g.result,
       CASE WHEN g.result % 20 = 0 THEN 0 ELSE 1 END,       -- 95.0% ok
       1300 + (g.result % 200)
FROM generate_series(1, 2000) g;


-- #############################################################################
-- 1. THREE CANDIDATES — each is a BRANCH of the agent's own behaviour
-- #############################################################################
DATA BRANCH CREATE TABLE cfg_cand_a FROM agent_config;
DATA BRANCH CREATE TABLE cfg_cand_b FROM agent_config;
DATA BRANCH CREATE TABLE cfg_cand_c FROM agent_config;

-- candidate A: retrieve more context
UPDATE cfg_cand_a SET config_value = '10', changed_by = 'agent_optimizer',
       rationale = 'more context should reduce unanswered technical questions'
WHERE config_key = 'retrieval_top_k';

-- candidate B: a new system prompt
UPDATE cfg_cand_b SET config_value = 'sp_v4', changed_by = 'agent_optimizer',
       rationale = 'tighter instructions on tool use'
WHERE config_key = 'system_prompt_version';

-- candidate C: lower temperature AND more context (two changes at once)
UPDATE cfg_cand_c SET config_value = '0.3', changed_by = 'agent_optimizer',
       rationale = 'less drift on factual answers'
WHERE config_key = 'temperature';
UPDATE cfg_cand_c SET config_value = '8', changed_by = 'agent_optimizer',
       rationale = 'paired with lower temperature'
WHERE config_key = 'retrieval_top_k';

-- exactly what each candidate proposes to change — one DIFF each
DATA BRANCH DIFF cfg_cand_a AGAINST agent_config OUTPUT SUMMARY;
DATA BRANCH DIFF cfg_cand_b AGAINST agent_config OUTPUT SUMMARY;
DATA BRANCH DIFF cfg_cand_c AGAINST agent_config OUTPUT SUMMARY;


-- #############################################################################
-- 2. EVALUATE each candidate on the SAME frozen eval set
-- #############################################################################
INSERT INTO eval_results          -- A: better, and only slightly more expensive
SELECT 'cand_a', g.result,
       CASE WHEN g.result % 50 = 0 THEN 0 ELSE 1 END,       -- 98.0% ok
       1450 + (g.result % 200)
FROM generate_series(1, 2000) g;

INSERT INTO eval_results          -- B: no better than baseline
SELECT 'cand_b', g.result,
       CASE WHEN g.result % 20 = 0 THEN 0 ELSE 1 END,       -- 95.0% ok
       1310 + (g.result % 200)
FROM generate_series(1, 2000) g;

INSERT INTO eval_results          -- C: best quality, but far too expensive
SELECT 'cand_c', g.result,
       CASE WHEN g.result % 100 = 0 THEN 0 ELSE 1 END,      -- 99.0% ok
       2100 + (g.result % 200)
FROM generate_series(1, 2000) g;

SELECT candidate,
       ROUND(100.0 * SUM(ok) / COUNT(*), 2) AS ok_pct,
       ROUND(AVG(total_tokens), 0)          AS avg_tokens
FROM eval_results GROUP BY candidate ORDER BY candidate;


-- #############################################################################
-- 3. THE GATE — promote only if quality improves AND cost stays in budget
--    (must beat baseline ok_pct, and cost may not rise more than 20%)
-- #############################################################################
CREATE TABLE promotion_gate (
    candidate  VARCHAR(24) PRIMARY KEY,
    ok_pct     DOUBLE, avg_tokens DOUBLE,
    ok_delta   DOUBLE, cost_ratio DOUBLE,
    verdict    VARCHAR(12)
);
INSERT INTO promotion_gate
SELECT c.candidate, c.ok_pct, c.avg_tokens,
       ROUND(c.ok_pct - b.ok_pct, 2),
       ROUND(c.avg_tokens / b.avg_tokens, 3),
       CASE WHEN c.ok_pct > b.ok_pct AND c.avg_tokens <= b.avg_tokens * 1.2
            THEN 'PROMOTE' ELSE 'REJECT' END
FROM (SELECT candidate, ROUND(100.0*SUM(ok)/COUNT(*),2) ok_pct, ROUND(AVG(total_tokens),0) avg_tokens
      FROM eval_results WHERE candidate <> 'baseline' GROUP BY candidate) c
CROSS JOIN
     (SELECT ROUND(100.0*SUM(ok)/COUNT(*),2) ok_pct, ROUND(AVG(total_tokens),0) avg_tokens
      FROM eval_results WHERE candidate = 'baseline') b;

SELECT * FROM promotion_gate ORDER BY candidate;


-- #############################################################################
-- 4. PROMOTE the winner, DROP the losers — the losing branches cost nothing
-- #############################################################################
DATA BRANCH MERGE cfg_cand_a INTO agent_config;   -- the only PROMOTE
DROP TABLE cfg_cand_b;                            -- rejected: no improvement
DROP TABLE cfg_cand_c;                            -- rejected: +56% cost

SELECT config_key, config_value, changed_by FROM agent_config
WHERE config_key IN ('retrieval_top_k', 'temperature', 'system_prompt_version')
ORDER BY config_key;

-- what the agent changed about itself this round
DATA BRANCH DIFF agent_config AGAINST agent_config {SNAPSHOT='cfg_v7'} OUTPUT SUMMARY;

CREATE SNAPSHOT cfg_v8 FOR DATABASE agent_eco;    -- the new production version


-- #############################################################################
-- 5. PRODUCTION DISAGREES — roll the agent's behaviour back in one statement
-- #############################################################################
-- Live traffic is not the eval set: top_k=10 pushes latency past the SLA.
UPDATE agent_config SET config_value = '999', changed_by = 'agent_optimizer',
       rationale = 'runaway self-tuning'
WHERE config_key = 'retrieval_top_k';
SELECT config_value AS runaway_top_k FROM agent_config WHERE config_key = 'retrieval_top_k';

RESTORE DATABASE agent_eco {SNAPSHOT = cfg_v7};   -- back to the human baseline
SELECT config_key, config_value, changed_by FROM agent_config
WHERE config_key = 'retrieval_top_k';

-- and both historical behaviour versions remain queryable, forever
SELECT 'cfg_v7' AS version, config_value FROM agent_config {SNAPSHOT='cfg_v7'} WHERE config_key='retrieval_top_k';
SELECT 'cfg_v8' AS version, config_value FROM agent_config {SNAPSHOT='cfg_v8'} WHERE config_key='retrieval_top_k';


-- #############################################################################
-- CLEANUP
-- #############################################################################
DROP SNAPSHOT IF EXISTS cfg_v7;
DROP SNAPSHOT IF EXISTS cfg_v8;
DROP DATABASE IF EXISTS agent_eco;
