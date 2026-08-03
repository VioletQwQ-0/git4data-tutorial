# MatrixOne Git4Data Deep Dive (Part 14) · Agents — Run Traces: Logs Alone Won't Tell You Why

[Part 13](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part13-agent-memory/index.md) covered an agent's **memory**: written by the agent itself, effective immediately, and therefore needing branch audits and rollback. This part covers the other thing an agent leaves behind when it runs — its **trace**.

Let's be upfront, because this part differs from the earlier ones in an important way:

> **A trace is an append-only log. It neither needs nor suits row-level diff and merge.** You don't "edit" a run that already happened.
>
> So this part isn't about versioning logs. It's about a thornier problem: **logs alone won't tell you why.**

> All SQL is verified on MatrixOne `4.1.0` using deterministic expressions (no `rand()`); the runnable version lives in [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) under `14-agent-trace/`.

---

## Why "complete logs" still can't explain a failure

Suppose your agent observability is excellent: every step of every run is recorded — which tool was called, with what arguments, what came back, how many tokens, how long.

Now the agent goes from v1 to v2 and production feedback gets worse. You open the logs and see a run whose step 3 called `search_kb` and failed. Then what?

**You immediately hit two walls.**

**First: is this failure typical?** To answer, you need v1 and v2 to each run **the same batch of inputs** and compare. But if that eval set was itself edited or extended in the meantime, the comparison is invalid. You think you're comparing two agent versions; you're actually comparing two different exams.

**Second: why did it behave that way?** This one is more fundamental. An agent's behaviour isn't determined by code alone, but by **what it read at that moment**:

```text
a run's behaviour = code/model × config × the memory it read then × the input
```

The log faithfully records *what happened*, but the memory **keeps changing** ([Part 13](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part13-agent-memory/index.md)'s whole subject). Come back three days later and the memory store is no longer what it was. **You can see what the agent did, but you can never reconstruct what it knew.**

This part closes those two gaps: **pin the eval set** so comparison is valid, and **record which memory/config version each run read** so the cause is recoverable.

---

## The running case: investigating a v1 → v2 regression

Same support agent. 2,000 eval inputs, run under both v1 and v2 — 4,000 runs, 16,000 steps.

### First, pin the eval set and the memory

These two statements are this part's foundation:

```sql
CREATE SNAPSHOT evalset_v1 FOR TABLE agent_trace eval_inputs;   -- freeze the questions
CREATE SNAPSHOT mem_r1     FOR TABLE agent_trace agent_memory;  -- freeze the memory
```

### The trace tables — note the `memory_snapshot` column

```sql
CREATE TABLE runs (
    run_id          BIGINT PRIMARY KEY,
    agent_version   VARCHAR(16),
    input_id        BIGINT,
    memory_snapshot VARCHAR(32),   -- which memory version this run read  <- the key
    config_version  VARCHAR(16),   -- which config version
    status          VARCHAR(12),
    n_steps         INT,
    total_tokens    INT,
    latency_ms      INT
);

CREATE TABLE run_steps (
    step_id    BIGINT PRIMARY KEY,
    run_id     BIGINT,
    step_no    INT,
    step_type  VARCHAR(12),        -- llm / tool
    tool_name  VARCHAR(32),
    ok         TINYINT,
    latency_ms INT
);
```

`memory_snapshot` is just a string, but it **links** the trace to [Part 13](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part13-agent-memory/index.md)'s memory versions. Its value shows up shortly.

---

## Step 1: the headline — how much worse

```sql
SELECT agent_version,
       COUNT(*) AS runs,
       SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) AS ok_runs,
       ROUND(100.0 * SUM(CASE WHEN status='ok' THEN 1 ELSE 0 END)/COUNT(*), 1) AS ok_pct,
       ROUND(AVG(total_tokens), 0) AS avg_tokens,
       ROUND(AVG(latency_ms), 0)   AS avg_latency_ms
FROM runs GROUP BY agent_version ORDER BY agent_version;
```

Measured:

| agent_version | runs | ok_pct | avg_tokens | avg_latency_ms |
|---|---|---|---|---|
| v1 | 2000 | **97.5** | 1345 | 1100 |
| v2 | 2000 | **72.5** | 1645 | 1300 |

Success rate down 25 points, tokens up 22%. **Because the eval set is frozen by `evalset_v1`, this comparison holds** — both versions answered exactly the same questions, no more and no fewer.

But so far you only know it got worse, not where.

---

## Step 2: attribute to inputs — which questions regressed

```sql
SELECT COUNT(*) AS regressed_inputs
FROM runs a JOIN runs b ON a.input_id = b.input_id
WHERE a.agent_version = 'v1' AND b.agent_version = 'v2'
  AND a.status = 'ok' AND b.status = 'failed';
--   measured 500
```

500 inputs went from pass to fail. Break that down by category:

```sql
SELECT e.category, COUNT(*) AS regressed
FROM runs a
JOIN runs b ON a.input_id = b.input_id
JOIN eval_inputs e ON e.input_id = a.input_id
WHERE a.agent_version = 'v1' AND b.agent_version = 'v2'
  AND a.status = 'ok' AND b.status = 'failed'
GROUP BY e.category ORDER BY regressed DESC;
--   measured technical → 500, every other category 0
```

**All 500 land in `technical`.** The scope narrows sharply — this isn't broad degradation, it's a targeted failure on one class of question.

---

## Step 3: attribute to a step — which tool broke

```sql
SELECT r.agent_version, s.tool_name,
       COUNT(*) AS calls,
       SUM(CASE WHEN s.ok = 0 THEN 1 ELSE 0 END) AS failures,
       ROUND(100.0 * SUM(CASE WHEN s.ok=0 THEN 1 ELSE 0 END)/COUNT(*), 1) AS fail_pct
FROM run_steps s JOIN runs r ON s.run_id = r.run_id
WHERE s.step_type = 'tool'
GROUP BY r.agent_version, s.tool_name ORDER BY r.agent_version;
```

| agent_version | tool_name | calls | failures | fail_pct |
|---|---|---|---|---|
| v1 | search_kb | 2000 | 50 | **2.5** |
| v2 | search_kb | 2000 | 550 | **27.5** |

**The `search_kb` tool's failure rate went from 2.5% to 27.5%.** The full attribution chain now reads:

```text
v2 success rate −25 points
   └─ 500 inputs regressed
        └─ all in the technical category
             └─ search_kb tool failure rate 2.5% → 27.5%
```

From "production got worse" to "v2's new retrieval path breaks search_kb on technical questions" in three SQL statements — **no log spelunking required.**

![Agent trace attribution: snapshots pin the eval set and the memory first; the headline is v1 ok 97.5% vs v2 ok 72.5%, down 25 points; a three-SQL attribution chain runs success-rate drop → 500 regressed inputs → all concentrated in the technical category → the search_kb tool failing 2.5% to 27.5%; a fourth SQL time-travels through runs.memory_snapshot to reconstruct what the run knew at the time](./images/fig_agent-trace_en.svg)

---

## Step 4: reconstructing what it knew at the time

The first three steps rely on structured trace tables and a frozen eval set. But the more fundamental question from the start — **why** — needs one more thing.

Because every run recorded its `memory_snapshot`, months later you can reconstruct exactly the memory it read:

```sql
SELECT r.run_id, r.memory_snapshot, m.fact_key, m.fact_value
FROM runs r
JOIN agent_memory {SNAPSHOT='mem_r1'} m       -- time travel back to that memory version
  ON m.subject_key = CONCAT('cust_', r.input_id)
WHERE r.run_id = 100001;
--   measured 100001 / mem_r1 / plan_tier / basic
```

That statement is this part's crux. **It upgrades a "log" into a reconstructable scene**: the trace tells you what the agent did, and the pinned memory version tells you what it was working from. Only together do they answer *why*.

Likewise, the eval set can be checked at any time to prove the comparison was fair:

```sql
SELECT COUNT(*) AS eval_inputs_at_v1 FROM eval_inputs {SNAPSHOT='evalset_v1'};   -- measured 2000
```

---

## Being clear about what Git4Data does and doesn't do here

This part has to draw the boundary explicitly, or it's easy to oversell:

**What it doesn't do**: row-level diff / merge on append-only logs. A log should stay a log — write once, never edit, use columnar storage and partitioning for volume and TTL for retention. **There isn't a single `DATA BRANCH MERGE` in this part, and that's deliberate.**

**What it does is make traces explainable:**

| The gap | The fix |
|---|---|
| Unfair comparison (the eval set moves) | snapshot the eval set; both sides read the same version |
| Can't reconstruct what it knew | record `memory_snapshot` per run, then time-travel back |
| Attribution means reading logs | traces structured into tables — attribution is JOIN and GROUP BY |
| Evidence expires | freeze this eval round's traces together with the data versions they depended on |

In one line: **the trace itself doesn't need version control, but for a trace to mean anything, what it depended on must be version-controlled.**

---

## Boundaries and applicability

- **Traces are voluminous; plan their storage separately.** Dozens of steps per run and hundreds of thousands of production runs a day means traces grow far faster than business tables. Snapshots suit freezing the evidence of *one eval round*, not retaining every production trace forever.

- **Success rate isn't quality.** `status = 'ok'` says the flow completed, not that the answer was good. Real evaluation needs human or model scoring — and those scores should be bound to the same batch of traces.

- **Don't record `memory_snapshot` as "current."** It must be the exact version identifier at run start, not a drifting reference like `latest` — otherwise you've recorded nothing.

- **Snapshots have retention cost.** One snapshot per eval round means abandoned rounds need a cleanup policy.

---

## Closing

Agent observability is usually understood as "log everything." But logging everything only solves half: **the log tells you what happened and can't reconstruct what it was based on** — because the memory and config the agent reads keep changing.

Pin the eval set and the memory as versions, record which version each run read, and investigation shifts from reading logs to querying data: **success 97.5% → 72.5%, all 500 regressed inputs in the technical category, root cause search_kb failing 2.5% → 27.5%** — three SQL statements. And "what did this run actually know" is the fourth.

> 📎 Runnable SQL: [github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ Source & community: [github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
