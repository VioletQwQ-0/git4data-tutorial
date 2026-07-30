# MatrixOne Git4Data 技术详解（十）·深度学习篇：训练数据怎么管——lakeFS 管文件，MatrixOne 管元数据

前面九篇一直在结构化数据上打转：[前四篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part1-data-at-scale-zh/index.md)讲清了 Git4Data 是什么、怎么用、和其他方案[分别站在哪一层](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape-zh/index.md)；第五到第七篇是数据运维；第八、九篇进入 AI 训练，用一个风控模型走通了[全流程总图](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle-zh/index.md)和[数据集发布与泄漏](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part9-dataset-release-zh/index.md)。

这一篇，我们转向 **深度学习** 的数据。先厘清一点：深度学习是一个很大的范畴，并不等同于多模态——只处理文本的网络、只看图像的 CNN，都是深度学习。但它和传统机器学习在**数据形态**上有一道共同的分水岭：深度学习往往直接在**大规模非结构化数据**（图像、音频、视频、原始文本）上训练。

**本篇聚焦的，就是这一类文件型（图像、音频、视频等）非结构化训练数据该怎么管**——它是深度学习里最典型、也最难版本化的数据形态。为了不空谈，我们全程跟着一个经典任务走：**训练一个图像分类模型**。数据从“表里的行”变成“一堆文件 + 一张巨大的元数据表”，版本管理也得换一套打法。

> 这一篇把（图像等）文件型训练数据的管理整个过一遍，思路和第八篇之于传统机器学习类似：先把整张图摊开——训练数据从进入到发布，每一步的真实难题是什么，文件该交给谁、元数据该交给谁。文中元数据侧的 SQL 全部在 MatrixOne `4.1.0` 上实测；lakeFS + MatrixOne 的完整端到端脚本 [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh) 也真跑通过，见 [matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) 的 `10-multimodal-lakefs/`。

---

## 深度学习的数据，首先是一个“文件”问题

传统机器学习的一条样本，是表里的一行：几十个结构化字段，天然适合放进数据库，也天然能被 snapshot、diff、merge。

深度学习的数据不是这样。一条样本的主体是**一个文件**——一张几 MB 的图、一段几十 MB 的音频、一个上百 MB 的视频片段（说到底就是一堆字节）。整个数据集动辄上千万个文件、TB 到 PB。把这些文件塞进数据库，既不划算、也发挥不出数据库的长处（下一节展开）。

但请注意一件事：**文件本身不进数据库，关于文件的一切却高度结构化。** 每条样本都有：它存在哪（对象路径）、它的内容 hash、它的感知 hash、类别标签、来自哪个源、什么 license、宽高、质量分、属于训练还是测试、被哪个模型版本用过……这些是几千万行、还在不断增删改的结构化记录——正是最需要行级版本语义的地方。

于是这类数据的版本管理，天然分成**两个世界**：

- **文件世界**：图像 / 音频 / 视频本体。放对象存储或 lakeFS，版本化的是“对象 / 文件的版本”。
- **元数据世界（metadata）**：谁指向哪个文件、label、split、各种 hash、来源、license…… 一张（或几张）巨大的结构化表，版本化的是“行”。

一份真正可复现的训练集，是这样一个乘积：

```text
可复现训练集 = 一个确定的元数据版本（metadata snapshot）
             × 一组确定的文件版本（lakeFS commit）
```

两个世界必须**一起被钉住、并且保持一致**：只钉元数据，文件可能已被覆盖；只钉文件，你不知道当时哪些样本、什么标签、怎么切分。这正是 lakeFS（管文件）和 MatrixOne 的 Git4Data 能力（管元数据）各司其职、再组合起来的地方。

### 为什么文件交给 lakeFS，而不是也塞进数据库？

一个自然的疑问：既然 MatrixOne 能版本化数据，为什么不干脆把图片文件也放进去、一个系统全管了？前面几篇其实已经把答案铺好了。

- **git4data 的低成本快照，前提是“结构化 + 元数据目录”。** [第三篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part3-under-the-hood-zh/index.md)讲过，MatrixOne 的快照近乎与数据量无关，靠的是不可变对象加元数据目录去版本化**行级结构化数据**。把 PB 级不可解析的图片文件灌进去，这个前提就不成立了——数据库会退化成一个又贵又慢的对象存储。

- **文件没有可 diff 的结构。** git4data 的价值在[第二篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part2-hands-on-zh/index.md)就立住了：行级的 diff / merge / query。可一张 JPEG 没有行、没有主键、没有列——对两张图做“行级 diff”毫无意义。[第四篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part4-landscape-zh/index.md)划过的边界也正是这条：git4data 管的是“同一 schema 下的结构化数据演进”，而文件根本没有 schema。

- **文件是整体、不可变地被写入的。** 一张图不会被逐行 `UPDATE`，它只会被整体替换。lakeFS 把对象整体写入、底层对象不可变，branch 是零拷贝的元数据操作、未改动的对象跨版本复用——这种“整块对象 + 廉价分支”的版本化，正是对象存储 + lakeFS（git-over-objects）最擅长的；硬套数据库的行级 MVCC 反而别扭。

- **更划算的是让数据库只存指针。** MatrixOne 也能存 BLOB，但把 PB 级文件放进去是成本与架构上的取舍；[第八篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part8-ml-lifecycle-zh/index.md)的总览给的更实际的分工是：不可解析文件交给对象存储 / lakeFS，MatrixOne 存目录、hash、URI 和 commit。而且数据库快照只能冻结**指针字段的取值**，冻不住外部文件本身（`datalink` 那条边界）——所以文件的版本，交给 lakeFS 更顺。

一句话：**数据库最擅长的是“结构化元数据的行级版本化”，lakeFS 最擅长的是“大文件的整体版本化”。让各自做各自最强的事，再把两者钉在一起，就是这一篇的全部主张。**

---

## 一张总图：训练数据全流程，文件归 lakeFS，元数据归 MatrixOne

先给结论。这类文件型训练数据的整个生命周期，可以清晰地劈成“文件侧”和“元数据侧”两条线，各自版本化、在发布时对齐。

![深度学习训练数据全流程：接入→去重→去污染→完整性→重标注→curation→发布→训练，每一站文件侧交给 lakeFS、元数据侧交给 MatrixOne，发布时用一个元数据快照 × 一个 lakeFS commit 钉在一起](./images/fig_multimodal-lifecycle_zh.svg)

| 环节 | 真实问题 | 文件侧（lakeFS） | 元数据侧（MatrixOne Git4Data） |
|---|---|---|---|
| 数据接入 | 新一批图片质量未知，不能污染主集 | 落到一条 ingest 分支 | 元数据行进入元数据分支，审计通过再 `MERGE` |
| 去重 | 上千万文件里有精确重复和感知近重复 | 对象照存 | `content_hash` / `phash` 上 `GROUP BY`，纯 SQL 找重复 |
| 去污染 | 训练集混进了评测 / 基准样本 | —— | 元数据对基准 hash 表做反连接，`DELETE` 掉重合 |
| 完整性检查 | 每个样本都要有标签、指针要解析到真文件 | 对象存在性由 lakeFS 保证 | 查缺标签；对 commit 的对象清单反连接验存在 |
| 重标注 | 类别标签、安全分要迭代 | 文件不变 | 每人一条分支、`MERGE` 冲突、`DIFF` 出改动 |
| data curation | 按质量 / 安全 / license 筛出干净子集 | —— | 版本化的 `dataset_membership` 子集 |
| 数据集发布 | 冻结“这次训练到底用了哪些文件的哪一版” | 一个 lakeFS commit | 一个库级元数据快照，并把 commit 记进注册表 |
| 训练与评估 | 模型要能反查到确切的数据现场 | commit 定位文件 | 快照 + 注册表建立 `model → metadata snapshot × lakeFS commit × code/env` 血缘 |
| 监控与再训练 | 新数据累积，何时触发下一轮 | 新 commit | 元数据上跑分布统计 + 跨版本 `DIFF` |

一句话分工：

> **lakeFS 让文件可回溯、可回滚；MatrixOne 的 Git4Data 能力让元数据可查询、可行级比对、可原子发布。两者用“元数据快照里记一个 lakeFS commit”对齐成一个可复现的整体。**

下面用一个完整案例把这张图跑通。

---

## 贯穿全文的案例：给一个图像分类模型准备训练数据

假设我们要训练一个**图像分类模型**——一个内容安全分类器，把图片分成 `safe` / `nsfw` 两类（换成商品类目、场景分类也是一样的套路）。训练数据就是**大量图片文件 + 每张图的类别标签**，从多个源采集而来，需要去重、去污染、检查完整性、修正标签，最后做 data curation，得到一个干净、可复现的训练集。

元数据就是一张 `samples` 表——**注意它不存文件，只存指向文件的指针，加上所有你真正要查询的东西**：

```sql
CREATE TABLE samples (
    sample_id     BIGINT PRIMARY KEY,
    object_uri    VARCHAR(512),   -- lakeFS 路径（一个指针，不是文件本身）
    object_commit VARCHAR(64),    -- 钉住这个文件的 lakeFS commit
    content_hash  VARCHAR(64),    -- 文件的 sha256（精确去重键）
    phash         VARCHAR(64),    -- 感知哈希（近重复键）
    label         VARCHAR(16),    -- 类别标签（safe / nsfw；NULL = 尚未标注）
    source        VARCHAR(32),    -- 来源 / 溯源
    license       VARCHAR(16),
    ingest_batch  VARCHAR(32)
);
```

一份可复现的训练记录，至少要绑定这些：

```text
run = 元数据快照（metadata snapshot）
    + lakeFS commit（文件版本）
    + data curation 与切分规则
    + 预处理 / 数据增强版本
    + 代码 commit + 运行镜像 digest
    + 超参数与随机种子
    + 模型产物 URI 与 hash
    + 评估指标
```

**元数据快照负责“哪些样本、什么标签、怎么切”，lakeFS commit 负责“文件是哪一版”——缺一个，这份记录都复现不出来。**

### 第一站：数据接入——WAP 跨两个世界

星期一，上游送来一批新图片。两个世界同时动，各走各的 WAP。

**文件侧（lakeFS）**：新对象先上传到一条 ingest 分支，做完文件层校验（能否解码、尺寸、safety 预扫，可挂 pre-merge hook）再 commit、合并到 main——拿到的这个 commit 就是这批文件的版本（下面的 lakeFS 命令与 commit 值取自可跑脚本 [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh)，`$L` 是它的 API 地址、`$KEY:$SECRET` 是凭证）：

```bash
# 上传对象到 ingest 分支后，提交并合并到 main
curl -u $KEY:$SECRET -H 'Content-Type: application/json' \
     -X POST $L/repositories/media/branches/ingest/commits -d '{"message":"ingest 2026w30"}'
curl -u $KEY:$SECRET -H 'Content-Type: application/json' \
     -X POST $L/repositories/media/refs/ingest/merge/main   -d '{"message":"publish 2026w30"}'
#   -> main commit（文件版本）= ba1693908b37…（示例，每次运行不同）
```

**元数据侧（MatrixOne）**：同一批样本的元数据行——指针指向 lakeFS 对象、`object_commit` 填刚拿到的那个 commit——进入一条分支，先审计、通过才合并。这正是[第七篇 Write-Audit-Publish](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part7-write-audit-publish-zh/index.md) 那套，只是现在跨了两个世界：

```sql
DATA BRANCH CREATE TABLE samples_stage FROM samples;
-- 新批次只进 staging 分支，每行 object_commit = 'ba1693908b37…'
INSERT INTO samples_stage SELECT ... FROM ...;

-- 元数据侧门禁：指针完整？标签齐不齐？license 明不明？
SELECT
  SUM(CASE WHEN object_uri IS NULL OR object_commit IS NULL THEN 1 ELSE 0 END) AS missing_pointer,
  SUM(CASE WHEN label IS NULL THEN 1 ELSE 0 END)                               AS missing_label,
  SUM(CASE WHEN license = 'unknown' THEN 1 ELSE 0 END)                         AS unknown_license
FROM samples_stage WHERE ingest_batch = '2026w30';
--   实测 missing_pointer 0 / missing_label 250 / unknown_license 1000

DATA BRANCH DIFF samples_stage AGAINST samples OUTPUT SUMMARY;   -- 实测 INSERTED 5000
DATA BRANCH MERGE samples_stage INTO samples;                    -- 全部通过才发布
```

**两侧各自审计、各自在本系统内原子合并。** 但要说清楚：lakeFS 和 MatrixOne 之间**没有跨系统事务**——本例是文件侧先合并、元数据侧后合并，若元数据侧失败，lakeFS main 已经动了。真要做到“任一侧不过、两侧都不发布”，需要一层发布协调：两侧先各自形成不可变候选版本，联合校验通过后，再统一以版本化 registry 对外发布可见版本。

### 第二站：去重——精确 + 感知，纯 SQL，不碰一个文件

上千万文件里，一定有精确重复（同一张图在不同 URL 被爬了两次）和感知近重复（裁剪、压缩、加水印后的“同一张图”）。这两类都能在元数据上用 SQL 查出来，**完全不需要把文件拉回来**：

```sql
-- 精确重复：一个 content_hash 被多条样本共用
SELECT COUNT(*) AS exact_dup_groups FROM (
  SELECT content_hash FROM samples GROUP BY content_hash HAVING COUNT(*) > 1
) t;   -- 实测 3000 组

-- 感知近重复（不是精确重复）：同一个 phash，却有不止一个 content_hash
SELECT COUNT(*) AS near_dup_groups FROM (
  SELECT phash FROM samples GROUP BY phash HAVING COUNT(DISTINCT content_hash) > 1
) t;   -- 实测 2000 组
```

文件的 hash 是离线算好、写进元数据的；一旦进了元数据，去重就是几条 `GROUP BY` 的事，而不是一场跨 PB 对象存储的扫描。

### 第三站：去污染——把评测集从训练集里挖出去

这是深度学习、尤其基础模型的命门：**一张测试 / 基准图漏进训练集，下游每一个指标都会虚高**。做法是拿元数据去和已知的评测集 hash 做反连接：

```sql
-- 训练样本里，有多少和评测基准（按内容）重合？
SELECT COUNT(*) AS contaminated FROM samples s
WHERE EXISTS (SELECT 1 FROM eval_hashes e WHERE e.content_hash = s.content_hash);
--   实测 1000（对应 500 个 benchmark 内容 hash：每张基准图 + 它被重新爬到的那份精确副本）
```

这条反连接命中的 1000 行，全是 `content_hash` 精确相等的命中（500 个唯一 benchmark hash，每个对上原件和它的精确副本各一行）。**注意它只覆盖“精确内容重复”**：裁剪、压缩、加水印后的近重复（`content_hash` 不同、`phash` 相近）并不会被命中——要连近重复一起去污染，得像去重那样，再对 benchmark 的 `phash` 做一次反连接。本文的实现只做了精确去污染。

### 第四站：完整性检查——每个样本都要有标签，指针要真能解析到文件

训练一个图像分类模型，每个样本至少要满足两条：**有一个类别标签**、**指针能解析到一个真实存在的文件**。

第一条在元数据上一条 SQL 就能查：

```sql
-- 缺标签：有图却没有类别标签，本轮不能进训练
SELECT COUNT(*) AS unlabeled FROM samples WHERE label IS NULL;
--   实测 550
```

第二条要小心：**只查 `object_uri` / `object_commit` 是否非空，只能证明字段填了值，并不能证明文件真的存在**（commit 不存在、path 写错、对象被删，这种检查都发现不了）。真正的存在性检查得去问 lakeFS——最简单的做法是把那个 commit 下的对象清单拉进来，和指针做一次反连接：

```sql
-- 先把 commit 的对象清单导入一张表 lakefs_objects(path)，再反连接
SELECT COUNT(*) AS dangling FROM samples s
WHERE NOT EXISTS (
  SELECT 1 FROM lakefs_objects o
  WHERE s.object_uri = CONCAT('lakefs://media/main/', o.path)
);
--   配套 run_practice.sh 里这一步是真跑的：从 lakeFS 列出 commit 的对象、导进来反连接，实测 dangling = 0
```

这也点出文件世界和元数据世界之间的陷阱：**删掉 lakeFS 里的一个对象，不会自动删掉元数据里指向它的行；反过来删元数据行，也不会删文件。** 两个世界各自版本化，一致性要靠这类跨世界的校验来兜底。

### 第五站：重标注——元数据在演进，文件纹丝不动

类别标签会被修正，安全分会被重新评估——这些都只动**元数据**，文件完全不变。于是又回到了[第六篇](https://github.com/matrixorigin/matrixorigin-blog/blob/main/matrixorigin/git4data-part6-collaborative-dev-zh/index.md)那套并行协作：每人一条分支，冲突自动暴露，改动有据可查。

```sql
DATA BRANCH CREATE TABLE samples_review FROM samples;
UPDATE samples_review SET label = 'nsfw'
WHERE sample_id BETWEEN 1000 AND 1999 AND label = 'safe';
DATA BRANCH DIFF samples_review AGAINST samples OUTPUT SUMMARY;   -- 实测 UPDATED 980
DATA BRANCH MERGE samples_review INTO samples;
```

重标注一轮到底改了什么，是一条 `DIFF` 说清的事；而这一切都没有产生任何一份文件副本。

### 第六站：data curation 与发布——元数据快照 × lakeFS commit

到了发布时刻。先在元数据上做一次 **data curation**，整出一个干净子集：去掉精确重复（每个 `content_hash` 只留 `sample_id` 最小的一条）、去掉评测重合、去掉缺标签的、只保留 license 明确的样本，并写入切分：

```sql
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
--   实测 train 38474 / valid 4934 / test 4935
```

然后是关键一步——**先把 lakeFS commit 登记进注册表，再打快照，让这条绑定被冻进快照里**。顺序很重要：先写 registry、后打 snapshot，绑定才落在被冻结的元数据版本里，而不是只躺在可变的活库里：

```sql
-- 先登记“元数据版本 × 文件版本”的绑定（快照名提前定好，行里可以先写上它）
INSERT INTO dataset_registry
SELECT 'ic_v1', 'ic_dataset_v1', 'media', 'ba1693908b37…',
       COUNT(*), 'metadata snapshot × lakeFS commit = reproducible training set'
FROM dataset_membership;

-- 再打快照，把 samples / dataset_membership / dataset_registry 一起冻结
CREATE SNAPSHOT ic_dataset_v1 FOR DATABASE img_cls;

-- 现在这条绑定就在快照里了（不只在活库里）：
SELECT lakefs_commit FROM dataset_registry {SNAPSHOT='ic_dataset_v1'} WHERE dataset_version = 'ic_v1';
--   -> ba1693908b37…
```

从此，“ic_v1 到底用了哪些数据”不再是一句口头描述，而是一个乘积：`ic_dataset_v1`（元数据快照）指明了样本、标签、切分，`ba1693908b37…`（lakeFS commit）指明了文件。而复现也不止是数出行数——可以把**确切的文件**取回来：从快照读出一条训练样本的指针和 commit，再回 lakeFS 按那个 commit 取文件（下面这段在配套 [`run_practice.sh`](https://github.com/matrixorigin/git4data-tutorial/blob/main/10-multimodal-lakefs/run_practice.sh) 里是真跑的）：

```sql
SELECT s.object_uri, s.object_commit
FROM samples {SNAPSHOT='ic_dataset_v1'} s
JOIN dataset_membership {SNAPSHOT='ic_dataset_v1'} m ON s.sample_id = m.sample_id
WHERE m.split_name = 'train' ORDER BY s.sample_id LIMIT 1;
--   -> lakefs://media/main/img/000003.jpg  @  ba1693908b37…
```

```bash
curl -u $KEY:$SECRET "$L/repositories/media/refs/ba1693908b37…/objects?path=img/000003.jpg"
#   -> "img-3-bytes"   ← 元数据快照 × lakeFS commit，把确切的文件复现了出来
```

---

## lakeFS 与 MatrixOne：两个版本世界怎么分工、怎么组合

这一篇必须把两者的边界讲清楚，否则很容易误以为“有一个就够了”。

**lakeFS 管文件。** 它是对象存储上的 git 式版本控制：在 S3 / GCS / Azure 之上提供 branch / commit / merge，把“对象存储在某个时刻的状态”钉成一个可回到的 commit；还能用 pre-merge hook 在合并前做文件层校验。它擅长的是**大文件本体**的版本化与回滚。它不做的是：把上千万条元数据当成一张表来跑 SQL、JOIN、聚合，或者告诉你“这两版之间，哪些**行**的标签变了”。

**MatrixOne 的 Git4Data 能力管元数据。** 它把元数据当成活的、可查询的表：行级 snapshot / branch / diff / merge / restore，随时能 JOIN、聚合、反连接。它擅长的是**结构化元数据**的版本化、行级比对和原子发布。它不适合承担的是：存储和版本化图音视频的文件本体（能存 BLOB，但不划算）。

**两者怎么组合？** 靠“元数据快照里记一个 lakeFS commit”。发布时，MatrixOne 侧打一个库级元数据快照，同时把当时的 lakeFS commit 写进注册表；复现时，两个 ID 一起用。

| 对象 | 更适合谁 | 它负责什么 | 它不负责什么 |
|---|---|---|---|
| 图 / 音 / 视频等大文件 | **lakeFS / 对象存储** | 文件的版本、回滚、pre-merge 校验 | 行级元数据查询与 diff |
| 元数据：指针、label、hash、split、来源 | **MatrixOne（Git4Data 能力）** | 行级快照 / 分支 / diff / merge / 恢复，可 JOIN 可聚合 | 存文件本体（能存 BLOB，但不划算） |
| 两者的对齐 | **注册表里的一条绑定** | 元数据快照 × lakeFS commit = 可复现训练集 | —— |

这比“指望一个工具同时管好文件和元数据”更贴近现实。文件有文件的最优解，元数据有元数据的最优解，关键是把它们**显式地钉在一起**。

---

## 一个可以直接采用的最小闭环

1. 文件进 lakeFS，元数据进 MatrixOne 的一张 `samples` 表，每行记指针 + `content_hash` + `phash` + label + 来源 + license。
2. 新批次先上分支：文件上 lakeFS 分支、元数据上 MatrixOne 分支，两侧各自审计，通过才合并。
3. 在元数据上用 SQL 做去重、去污染、完整性检查，把可疑样本挡在 data curation 之外。
4. 做 data curation，把干净子集写进 `dataset_membership`，打一个库级元数据快照。
5. **把 lakeFS commit 和元数据快照一起登记进注册表**——这是可复现的锚点。
6. 训练时绑定 `model → metadata snapshot × lakeFS commit × code/env`；下一轮用 `DIFF` 看元数据变化、用新 commit 看文件变化。

---

## 结语

深度学习把训练数据从“表里的行”变成了“对象存储里的文件 + 一张巨大的元数据表”。这两样东西的最优管理方式不一样：文件要的是整体的版本与回滚，元数据要的是行级的查询、比对和原子发布。把它们硬塞进同一个工具，总有一头别扭。

更现实的架构，是让 **lakeFS 管文件、MatrixOne 的 Git4Data 能力管元数据**，再用“元数据快照 × lakeFS commit”把两个版本世界钉成一个可复现的整体。去重、去污染、完整性、重标注、data curation——这些真正决定训练数据质量的操作，几乎都发生在元数据上，而元数据，恰好是一张可以用 SQL 版本化管理的表。

> 📎 可运行 SQL：[github.com/matrixorigin/git4data-tutorial](https://github.com/matrixorigin/git4data-tutorial) ｜ 源码与社区：[github.com/matrixorigin/matrixone](https://github.com/matrixorigin/matrixone)
