# MatrixOne Git4Data Deep Dive (Part 15 · Finale) · Agents — Self-Evolution: Turning an Agent's Behaviour into Reviewable, Reversible Data

This is the final part of the series.

[Part 13](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part13-agent-memory/index.md) covered an agent's **memory** — the facts it writes about the world. [Part 14](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part14-agent-trace/index.md) covered its **traces** — every step it ran. This part covers the last piece, and the most interesting: **the agent's behaviour itself**.

When an agent starts trying to improve itself — a different system prompt, more retrieved context, a tweaked threshold — what it is really doing is **editing its own behaviour definition**. And if that definition is a table, then "agent self-evolution," which sounds futuristic, collapses back onto a pattern we've used for fourteen parts:

```text
propose → branch → evaluate → merge if it passes / drop if it doesn't → roll back if production disagrees
```

> All SQL is verified on MatrixOne `4.1.0` using deterministic expressions (no `rand()`); the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `15-agent-evolution/`.

---

## First, make the agent's behaviour data

Much of an agent's behaviour doesn't live in code — it lives in **tunable configuration**:

```sql
CREATE TABLE agent_config (
    config_key   VARCHAR(48) PRIMARY KEY,
    config_value VARCHAR(256),
    value_type   VARCHAR(12),
    changed_by   VARCHAR(32),     -- human / agent_optimizer  <- who changed it
    rationale    VARCHAR(256)     -- why                       <- the reasoning
);

INSERT INTO agent_config VALUES
 ('system_prompt_version', 'sp_v3', 'string', 'human', 'baseline in production'),
 ('retrieval_top_k',       '5',     'int',    'human', 'baseline'),
 ('temperature',           '0.7',   'float',  'human', 'baseline'),
 ('tool_timeout_ms',       '2000',  'int',    'human', 'baseline'),
 ('max_steps',             '8',     'int',    'human', 'baseline'),
 ('escalate_threshold',    '0.45',  'float',  'human', 'baseline');
```

Change a row and the agent behaves differently. **So this table isn't a config file — it's the agent's genome.**

`changed_by` and `rationale` matter a lot here: when the proposer may be the agent itself (`agent_optimizer`), you must be able to see at a glance **which changes came from humans and which the machine made on its own**, and what reason it gave.

Snapshot the production baseline first — it's this round's rollback point:

```sql
CREATE SNAPSHOT cfg_v7 FOR DATABASE agent_eco;
```

---

## Step 1: three candidates, one branch each

The agent (or an automated optimizer) proposes three improvements. Each is a branch — **they don't interfere with each other, and none of them touches the production config**:

```sql
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

-- candidate C: lower temperature AND more context (two changes)
UPDATE cfg_cand_c SET config_value = '0.3' WHERE config_key = 'temperature';
UPDATE cfg_cand_c SET config_value = '8'   WHERE config_key = 'retrieval_top_k';
```

What each candidate proposes is one DIFF apiece:

```sql
DATA BRANCH DIFF cfg_cand_a AGAINST agent_config OUTPUT SUMMARY;   -- measured UPDATED 1
DATA BRANCH DIFF cfg_cand_b AGAINST agent_config OUTPUT SUMMARY;   -- measured UPDATED 1
DATA BRANCH DIFF cfg_cand_c AGAINST agent_config OUTPUT SUMMARY;   -- measured UPDATED 2
```

**This is "the agent opened a pull request."** What it changed and how much is visible — rather than some process quietly moving a production parameter in the background.

---

## Step 2: evaluate on the same frozen questions

Each candidate runs the same 2,000 **frozen** eval inputs ([Part 14](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part14-agent-trace/index.md) explained why they must be frozen):

```sql
SELECT candidate,
       ROUND(100.0 * SUM(ok) / COUNT(*), 2) AS ok_pct,
       ROUND(AVG(total_tokens), 0)          AS avg_tokens
FROM eval_results GROUP BY candidate ORDER BY candidate;
```

| candidate | ok_pct | avg_tokens |
|---|---|---|
| baseline | 95.00 | 1400 |
| cand_a | **98.00** | 1550 |
| cand_b | 95.00 | 1410 |
| cand_c | **99.00** | 2200 |

At a glance `cand_c` looks best (99%). But quality alone isn't enough.

---

## Step 3: the gate — quality must rise, cost must not run away

**This is the most important section of the part.** If self-evolution admits anything whose metric went up, the agent will quickly learn to buy metrics with resources: retrieve more, reason more, retry more — the score rises, and so do cost and latency.

So the gate must be **multi-dimensional**, and written as an executable rule:

```sql
INSERT INTO promotion_gate
SELECT c.candidate, c.ok_pct, c.avg_tokens,
       ROUND(c.ok_pct - b.ok_pct, 2)          AS ok_delta,
       ROUND(c.avg_tokens / b.avg_tokens, 3)  AS cost_ratio,
       CASE WHEN c.ok_pct > b.ok_pct                     -- quality must genuinely improve
                 AND c.avg_tokens <= b.avg_tokens * 1.2  -- cost may not rise over 20%
            THEN 'PROMOTE' ELSE 'REJECT' END
FROM (...) c CROSS JOIN (...) b;
```

Measured:

| candidate | ok_pct | avg_tokens | ok_delta | cost_ratio | verdict |
|---|---|---|---|---|---|
| cand_a | 98.00 | 1550 | **+3.00** | 1.107 | **PROMOTE** |
| cand_b | 95.00 | 1410 | 0.00 | 1.007 | REJECT |
| cand_c | 99.00 | 2200 | +4.00 | **1.571** | REJECT |

- **cand_a**: +3 points of quality for only 10.7% more cost → **promoted**.
- **cand_b**: no improvement at all → rejected.
- **cand_c**: the best quality (+4 points), but **57% more expensive** → rejected.

That rejection of `cand_c` is the one worth dwelling on. **Without the cost dimension it would have won** — and then the production bill would more than double with nobody able to say which "automatic optimization" caused it. **Writing the gate as a rule in the data, rather than leaving it to someone's judgment, is exactly what prevents that.**

![The agent self-evolution flow: agent_config holds behaviour as data and is snapshotted as cfg_v7 first; three candidates each take a zero-copy branch (DIFF showing 1/1/2 changes); the gate compares them on the same frozen 2,000 eval inputs, promoting cand_a at 98% and x1.107 cost while rejecting cand_b for no gain and cand_c for x1.571 cost despite 99%; the winner merges and losers are dropped for free; when tuning runs away to top_k 999, one RESTORE returns to the human baseline of 5](./images/fig_agent-evolution_en.svg)

---

## Step 4: promote the winner, drop the losers

```sql
DATA BRANCH MERGE cfg_cand_a INTO agent_config;   -- the only PROMOTE
DROP TABLE cfg_cand_b;                            -- rejected: no improvement
DROP TABLE cfg_cand_c;                            -- rejected: +57% cost
```

**Dropping losers costs nothing** — branches are zero-copy ([Part 3](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood/index.md)), so a rejected candidate is just `DROP`ped, leaving no trace on the production config. That matters enormously for self-evolution: **the cheaper failure is, the more freely the agent can propose.**

After the merge, look at what the agent actually changed about itself this round:

```sql
SELECT config_key, config_value, changed_by FROM agent_config
WHERE config_key IN ('retrieval_top_k', 'temperature', 'system_prompt_version');
--   measured retrieval_top_k = 10 / agent_optimizer   <- machine-changed
--            system_prompt_version = sp_v3 / human    <- human-set, untouched
--            temperature = 0.7 / human                <- human-set, untouched

DATA BRANCH DIFF agent_config AGAINST agent_config {SNAPSHOT='cfg_v7'} OUTPUT SUMMARY;
--   measured UPDATED 1 — this round of self-evolution, as a complete change set

CREATE SNAPSHOT cfg_v8 FOR DATABASE agent_eco;   -- the new production version
```

The `changed_by` column keeps human decisions and machine decisions cleanly separated — a necessary boundary in any self-evolving system.

---

## Step 5: production disagrees — one statement to roll back

An eval set is never live traffic. `top_k=10` looked great offline, but in production it pushed P99 latency past the SLA — and worse, the optimizer "saw" the latency metric and kept pushing, all the way to 999:

```sql
UPDATE agent_config SET config_value = '999', changed_by = 'agent_optimizer',
       rationale = 'runaway self-tuning'
WHERE config_key = 'retrieval_top_k';
SELECT config_value AS runaway_top_k FROM agent_config WHERE config_key='retrieval_top_k';
--   measured 999
```

One statement returns to the human-set baseline:

```sql
RESTORE DATABASE agent_eco {SNAPSHOT = cfg_v7};
SELECT config_key, config_value, changed_by FROM agent_config WHERE config_key='retrieval_top_k';
--   measured 5 / human
```

And both historical versions remain queryable forever:

```sql
SELECT config_value FROM agent_config {SNAPSHOT='cfg_v7'} WHERE config_key='retrieval_top_k';  -- measured 5
SELECT config_value FROM agent_config {SNAPSHOT='cfg_v8'} WHERE config_key='retrieval_top_k';  -- measured 10
```

**This is the seatbelt of a self-evolving system.** A system that can change itself must be paired with a fallback point it *cannot* change — otherwise there's no guardrail between "self-improvement" and "self-damage."

---

## Looking back: fifteen parts about the same thing

With that, the whole line can be drawn together.

| Parts | What the data is | Who changes it |
|---|---|---|
| 1–4 | structured business data | humans (engineers) |
| 5–7 | production data, ETL batches | humans (ops / data engineering) |
| 8–9 | ML samples, labels, splits | humans (data scientists) |
| 10 | image files + metadata | humans (labeling / curation) |
| 11–12 | SFT records, preference votes | humans (curators / annotators / reviewers) |
| 13 | agent memory | **the agent itself** |
| 14 | run traces | the agent (write-only) |
| 15 | **the agent's behaviour definition** | **the agent itself** |

The shape of the data changed all the way through — from rows in a table, to files in object storage, to preference pairs, to an agent's memory and behaviour. **But every part answered the same four questions:**

```text
which version is this?          → snapshot
what changed since the last?    → diff
can I try it without risking main? → branch
can I undo it if I break things?   → merge / restore
```

Fifteen parts in, the conclusion is plain: **once data changes frequently and those changes directly affect a running system, you need version control.** Code figured this out decades ago; data never did — and AI has pushed the urgency to its peak, because the thing changing the data is no longer only human.

---

## Boundaries and applicability

- **The scope of self-evolution must be explicitly bounded.** Letting an agent tune `retrieval_top_k` is one thing; letting it change `escalate_threshold` (when to hand off to a human) is another. **Which keys a machine may change and which only humans may change should be an explicit rule**, not left to the agent's discretion.

- **The gate must be multi-dimensional, and must include cost.** Optimize on quality alone and the agent will learn to buy score with resources. `cand_c` here is that pattern in miniature.

- **Eval sets get overfitted.** Reusing the same questions as a promotion gate means the agent gradually optimizes against them. Rotate the eval set periodically and keep a fixed holdout out of the gate ([Part 9](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part9-dataset-release/index.md) made the same point).

- **The rollback point must be human-set.** `cfg_v7` is a safe target because a human confirmed it. If the agent also chooses the fallback, the seatbelt is decorative.

- **Git4Data makes no decisions.** What to propose, where the bar sits, whether to ship — your policy. What it guarantees: each proposal is tried in isolation, every change is auditable, and any version can be rolled back.

---

## Closing

This series began with "why data at scale needs Git-style version control" and ends with an agent editing its own behaviour.

It looks like a long distance, but underneath it's one thing: **as long as data changes, you need to know what it changed into, how it differs from before, and whether you can go back.** All that changed is who does the writing — from engineers to annotators, from annotators to training pipelines, and finally to the agent itself. And the more automatic and faster the writer becomes, the more valuable "you can go back" gets.

This part's measured numbers are the footnote to that sentence: **three candidates tried in parallel, zero-copy, failures discarded for free; a gate judging both quality and cost that kept out a 99%-but-57%-more-expensive proposal; and when automatic tuning ran away to 999, a single `RESTORE` returned to the human-set baseline.**

An agent can change itself. But every step it takes should be like code — **visible, reviewable, and reversible.**

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
