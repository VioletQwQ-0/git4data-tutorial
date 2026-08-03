# MatrixOne Git4Data 技术详解（十三）·Agent 篇：可回滚的记忆——当写数据的是 Agent 自己

前十二篇，我们把 Git4Data 一路带过了[数据运维](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish-zh/index.md)、[传统机器学习](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle-zh/index.md)、[深度学习的文件型数据](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part10-multimodal-zh/index.md)，以及大模型的 [SFT](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation-zh/index.md) 和 [RLHF 偏好数据](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part12-rlhf-preference-zh/index.md)。

从这一篇起，进入最后一档：**Agent**。这一档和前面所有篇章有一个根本区别——

> 前面十二篇里，**改数据的都是人**：工程师跑 ETL、标注员打标签、评审员改判、curator 下刀。哪怕节奏再快，中间总有一个人在按回车。
>
> 到了 Agent 这里，**写数据的是 Agent 自己**——它一边和用户对话，一边把"学到的东西"写进自己的长期记忆，全程没有人审。

这一篇讲的就是这份记忆：它为什么特别危险，以及怎么让它变得可审计、可回滚。

> 文中 SQL 全部在 MatrixOne `4.1.0` 上实测，且使用确定性表达式（无 `rand()`），每个数字可逐次复现；可跑版本见 [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `13-agent-memory/`。

---

## Agent 记忆和训练数据，是两种东西

先厘清概念。一个有长期记忆的 Agent，记忆里存的是它**关于世界的事实**：

```text
cust_1042 · preferred_channel · email        （这个客户偏好邮件联系）
cust_1042 · plan_tier         · pro          （他是 pro 套餐）
cust_1042 · open_issue        · ticket_8821  （有一个未结工单）
```

它和训练数据有三个关键差别，每一个都让它更危险：

| | 训练数据 | Agent 记忆 |
|---|---|---|
| **谁写的** | 人（工程师 / 标注员） | **Agent 自己**，对话中即时写入 |
| **什么时候生效** | 下一次训练时 | **下一秒**——它被立刻读进下一轮对话 |
| **写错了怎样** | 下一版训练前还能修 | **立刻在线上生效**，而且会一直生效下去 |

第三行是重点。训练数据写错了，你还有一整个 curation 环节可以拦（[第十一篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part11-sft-curation-zh/index.md)讲的就是这个）。**Agent 记忆写错了，它就是一个正在生效的线上故障**——而且比普通故障更隐蔽，因为它不会报错，只会让 Agent 在之后每一次对话里，都带着这个错误的"认知"去回答。

---

## 一个真实会发生的故障：一句误解，污染半年

某个客服 Agent 在一次对话里，把用户的一句反话理解成了字面意思，于是写下：

```text
cust_1042 · preferred_channel · 不要联系我
```

这条记忆此后被每一次对话读取。用户下次来咨询，Agent 表现得异常冷淡、拒绝主动跟进——因为它"记得"这个人不想被联系。

等到几个月后有人终于发现问题，麻烦的地方在于：

1. **这条记忆是什么时候写的？** 不知道，记忆表里只有当前值。
2. **是哪一次对话写的？** 不知道，没有溯源字段。
3. **同一次对话还写了别的什么？** 不知道，无从批量排查。
4. **能不能把那次对话写的全部撤销？** 不能，它们和几十万条正常记忆混在一起。

这四个问题，正好对应 Git4Data 的四件事：**溯源、审计、回滚、DIFF**。

---

## 贯穿全文的案例：一个客服 Agent 的记忆库

记忆就是一张表。注意除了事实本身，还有三列**溯源信息**——它们是这一篇的关键：

```sql
CREATE TABLE agent_memory (
    mem_id      BIGINT PRIMARY KEY,
    subject_key VARCHAR(64),    -- 这条事实是关于谁的（如客户 ID）
    fact_key    VARCHAR(64),    -- 哪个属性（如 preferred_channel）
    fact_value  VARCHAR(256),
    confidence  DOUBLE,         -- 写下时 Agent 有多确信
    source_run  VARCHAR(32),    -- 哪一次运行写的  ← 溯源
    written_at  DATETIME,       -- 什么时候写的    ← 溯源
    status      VARCHAR(16)     -- active / superseded
);
```

`source_run` 和 `written_at` 这两列，就把开头那两个"不知道"直接消灭了。而 `status` 这一列体现了一个重要设计选择：**记忆更新不是覆盖，而是把旧事实标记为 superseded**——历史被保留下来，而不是被抹掉。

案例规模：8,000 个客户 × 5 个属性 = **40,000 条已积累的记忆**。

---

## 第一步：Agent 的记忆写入，先进分支

这是整篇的核心动作。**不要让 Agent 直接写主记忆库**，先写进一条分支：

```sql
DATA BRANCH CREATE TABLE memory_staging FROM agent_memory;
-- 这一轮会话（run_9001）提议写入 3,000 条新记忆
INSERT INTO memory_staging SELECT ... ;

DATA BRANCH DIFF memory_staging AGAINST agent_memory OUTPUT SUMMARY;
--   实测 INSERTED 3000 —— 这一轮"想记住"什么，一目了然
```

这就是[第七篇 Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish-zh/index.md) 用在 Agent 记忆上：**先写、再审、通过才发布**。区别只是这次的"写"方是 Agent。

---

## 第二步：审计 Agent 想记住的东西

真实 Agent 会话产生的问题，主要是这三类：

### 矛盾：新事实和已有的活跃事实打架

```sql
SELECT COUNT(*) AS contradictions
FROM memory_staging s
JOIN agent_memory m ON s.subject_key = m.subject_key AND s.fact_key = m.fact_key
WHERE s.mem_id >= 500000 AND m.status = 'active' AND s.fact_value <> m.fact_value;
--   实测 300
```

### 低置信：Agent 其实是在猜

```sql
SELECT COUNT(*) AS low_confidence FROM memory_staging
WHERE mem_id >= 500000 AND confidence < 0.5;
--   实测 428
```

### 无溯源：写了，但不知道是哪次运行写的

```sql
SELECT COUNT(*) AS untraceable FROM memory_staging
WHERE mem_id >= 500000 AND source_run IS NULL;
--   实测 120
```

**处理方式对三类不一样**，这一点值得强调：

```sql
-- 低置信 + 无溯源：直接拒绝，不进记忆
DELETE FROM memory_staging
WHERE mem_id >= 500000 AND (confidence < 0.5 OR source_run IS NULL);

-- 矛盾：不删新的，而是把旧事实标记为 superseded —— 保留历史，而不是静默覆盖
UPDATE memory_staging m SET status = 'superseded'
WHERE m.mem_id < 500000 AND m.status = 'active'
  AND EXISTS (SELECT 1 FROM memory_staging s
              WHERE s.mem_id >= 500000
                AND s.subject_key = m.subject_key AND s.fact_key = m.fact_key
                AND s.fact_value <> m.fact_value);
```

**矛盾不该被当成错误删掉**。人是会变的：客户真的可能改了偏好。矛盾的正确处理是**新旧并存、旧的标记为过期**——这样既让 Agent 用上最新认知，又保留了"它曾经这么认为过"的历史。只有当你需要排查"Agent 为什么在三月份那样回答"时，才会明白这段历史有多值钱。

审计后的收据和合并：

```sql
DATA BRANCH DIFF memory_staging AGAINST agent_memory OUTPUT SUMMARY;
--   实测 INSERTED 2469 / UPDATED 206
--   （3000 条提议里，531 条因低置信或无溯源被拒；206 条旧事实被标记过期）

DATA BRANCH MERGE memory_staging INTO agent_memory;
--   实测记忆库 40,000 → 42,469；其中 active 42,263、superseded 206
```

![Agent 记忆全流程：40,000 条事实的记忆库不动，会话 run_9001 在分支上提议 3,000 条；审计出矛盾 300（标记 superseded）、低置信 428 与无溯源 120（拒绝）；合并后 DIFF 收据 INSERTED 2469 / UPDATED 206，记忆库到 42,469；run_9002 污染 5,000 条后一条 RESTORE 归零；溯源列让「谁在什么时候写了什么」都可查](./images/fig_agent-memory_zh.svg)

---

## 第三步：当一次会话把记忆写坏了

审计能挡住大部分问题，但挡不住全部——比如一次批量导入的误读。这时需要的是**回滚**。

先在已知良好的状态打一个快照（这应该是记忆库的日常操作，就像数据库备份）：

```sql
CREATE SNAPSHOT mem_v1 FOR TABLE agent_mem agent_memory;
```

然后 `run_9002` 出了问题，把 5,000 条事实覆盖成了垃圾值：

```sql
-- 损失评估：相对已知良好版本，到底动了多少
DATA BRANCH DIFF agent_memory AGAINST agent_memory {SNAPSHOT='mem_v1'} OUTPUT SUMMARY;
--   实测 UPDATED 5000
SELECT COUNT(*) AS poisoned FROM agent_memory WHERE fact_value = 'GARBAGE';   -- 实测 5000
```

整库回滚，一条语句：

```sql
RESTORE TABLE agent_mem.agent_memory {SNAPSHOT = mem_v1};
SELECT COUNT(*) AS poisoned_after_restore FROM agent_memory WHERE fact_value = 'GARBAGE';   -- 实测 0
SELECT COUNT(*) AS memory_after_restore FROM agent_memory;                                  -- 实测 42469
```

这正是[第五篇误操作救援](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part5-incident-rescue-zh/index.md)那套能力，用在 Agent 记忆上。差别在于：**普通数据事故是人造成的，频率低；Agent 记忆事故是机器造成的，可能每天都在小规模发生**——所以"能回滚"不是应急预案，而是日常基础设施。

---

## 第四步：开头那四个问题，现在都能回答了

有了溯源列和版本，开头那个"一句误解污染半年"的场景，排查路径变成这样：

```sql
-- 这一次运行到底写了多少条记忆？
SELECT source_run, COUNT(*) AS facts_written
FROM agent_memory WHERE source_run = 'run_9001' GROUP BY source_run;
--   实测 run_9001 / 2469

-- 三个月前那个版本的记忆里，这条事实是什么？
SELECT COUNT(*) AS facts_at_mem_v1 FROM agent_memory {SNAPSHOT='mem_v1'};
--   实测 42469
```

| 开头的问题 | 现在的答案 |
|---|---|
| 这条记忆什么时候写的？ | `written_at` |
| 哪一次对话写的？ | `source_run` |
| 那次对话还写了什么？ | `WHERE source_run = 'run_XXXX'`，一条 SQL 列全 |
| 能撤销那次对话的全部写入吗？ | 能——按 `source_run` 批量撤销，或整库 `RESTORE` |

---

## 边界与适用范围

- **记忆审计不是内容审核。** 置信度门槛、矛盾如何裁决、什么算"不该记住的信息"，都是你的策略。Git4Data 保证的是：这些策略作用在可控的分支上、每次写入有据可查、错了能退回。

- **不是每条记忆都值得走分支。** 高频、低风险的记忆（比如会话内的临时上下文）走分支反而累赘。**值得上这套流程的是长期记忆**——那些会被反复读取、影响后续所有交互的事实。

- **superseded 会累积。** 保留历史是有存储成本的，需要给过期事实设定清理或归档策略，否则记忆表会持续膨胀。

- **合规删除要穿透历史。** 如果用户要求删除个人数据，只删 active 行是不够的——superseded 的历史行和保留中的快照里都可能还有，这需要专门的处理流程（[第八篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle-zh/index.md)提过同类问题）。

---

## 结语

Agent 记忆是这个系列里第一份**由机器自己写入、并立刻生效**的数据。它没有训练数据那样的缓冲期——写下的一瞬间就开始影响线上行为，而且会一直影响下去。

把记忆写入放进"分支 → 审计 → 合并"的流程，再配上溯源列和定期快照之后，它就从一个黑盒变成了可管理的东西：**3,000 条提议里 531 条被挡在门外、300 条矛盾以"新旧并存"的方式化解、5,000 条被污染的记忆一条语句回滚归零**；而"这条记忆是谁在什么时候写的、那次会话还写了什么"，从此都是一条 SQL 的事。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
