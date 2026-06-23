# Spike：AgentCore Runtime 共享 CodeGraph 索引 + 只读挂载客户 EFS 的可行性

> ⚠️ **已被取代（历史记录，保留）**：本 spike 论证的「会话容器只读挂载客户 EFS 读源码」方案**已被移除**。
> 现行架构不再使用 EFS、也无 `/mnt/repo` 共享挂载：仓库副本只存在 index-service 本地磁盘，会话 microVM
> 不挂任何文件系统，全部源码经 index-service 的 MCP-over-HTTP 桥读取（`codegraph_read_file` /
> `codegraph_glob_files` / `codegraph_search_files`）。本文保留作设计历史；当前实现以
> [`architecture.md`](architecture.md) 为准。

> 技术调研报告（Technical Spike）。结构遵循 Microsoft Engineering Playbook 的 Technical Spike 模板
> （Goal → Method → Evidence → Conclusions → Next Steps），并入技术报告通用骨架（含 Limitations）。

| 项 | 内容 |
|---|---|
| **日期** | 2026-06-16（初版）· 2026-06-17（端到端实测更新） |
| **更新** | 2026-06-17：原 §6 多项「⚠️待验证」已在 **ap-northeast-1（东京）真实部署**验证：EFS 挂载到 `/mnt/repo`（agent 读取到源码）、Model B 桥的 stdio 侧已验证、`InvokeAgentRuntime` 已实测。落地要点：须 botocore≥1.43（含 `efsAccessPoint` 模型）、`networkMode=VPC`；VPC microVM 无公网 IP，出站（Bedrock/CLI）须 NAT Gateway。见 §7 更新表。 |
| **关联** | source-truth MVP；待验证点「会话容器只读挂载客户 EFS」「CodeGraph 索引能否被会话共享 / 实时同步」（[`architecture.md`](architecture.md) 存储与索引方案） |
| **环境** | AWS EC2（aarch64 ARM）；本地盘 NVMe EBS；Ubuntu 24.04，kernel 6.17；botocore 1.42.96（仓库固定）与 1.43.30（PyPI 最新）；codegraph-server v0.18.5（ARM aarch64，RocksDB 后端）；AWS 仅只读权限（可 Describe，未部署） |
| **证据等级** | ✅实测（本机实测）/ 📄文档（官方文档 / API 模型 / 源码印证）/ ⚠️待验证 |

---

## 1. Executive Summary（执行摘要）

本方案要回答两问：会话容器能否**只读挂载客户 EFS**读最新源码；CodeGraph 索引能否被各会话**共享并实时同步**。
本 spike 用 API 模型核验 + 本机实测 + 源码取证 + 对抗式交叉验证，对这两问逐一下结论。

> **结论一分为二：唯一已实测验证的是「容器各自打开同一份只读索引文件」不可行；另一条路（EFS 只读挂源码 + 远程引擎共享索引）有 API/文档支持，但尚未端到端验证。**
> CodeGraph(v0.18.5) 用 RocksDB、**open 即写**，只读挂载会直接失败并退化为空索引（✅实测，证据最充分）。客户 EFS **可**被会话容器
> 只读挂载（AgentCore 2026-05 GA 的 bring-your-own file system 能力，📄文档，未部署实测），承载源码；索引复用改为
> **「索引常驻 index-service、会话经网络查询」**的远程引擎模型（Model B）——实时同步由常驻引擎自带的 file-watcher 增量提供（✅实测），
> 唯一一份索引、无副本、无多进程并发写入损坏；但会话经桥远程查询的**完整通路尚未在本机完成端到端验证**（见 §6），属架构推断。

据此，把 [`architecture.md`](architecture.md) 原方案「EFS 同时放代码+索引、会话只读挂同一卷本地查」修正为：**EFS 只放源码；
索引留 index-service 本机盘，经一层 stdio→HTTP 桥对会话暴露**。

---

## 2. Goal（调研目标）

1. AgentCore Runtime 会话容器能否**只读挂载客户自带 EFS 卷**？所需的网络 / 挂载 / 权限形态是什么？
2. 一个独立 index-service 在共享卷上建好的 **CodeGraph 索引，能否被会话容器只读复用**（容器内运行 CodeGraph 直读索引文件）？
3. 若不能只读复用，存在什么**可行的共享 + 实时同步方案**？代价与风险是什么？

---

## 3. Method（方法）

1. **API 模型核验（问题 1）**：解包 boto3/botocore 的 `bedrock-agentcore-control` 服务模型（gzip JSON），
   逐字段查 `CreateAgentRuntime` 的 `filesystemConfigurations`；对照仓库固定版本与 PyPI 最新版本，定位差异；
   再 WebFetch AWS 官方 What's New / devguide / VPC 文档核对措辞（不凭记忆）。
2. **索引引擎取证（问题 2）**：识别 codegraph-server 的索引存储引擎（`file` / strings / `--info`）；
   读 `~/.codegraph` 实际布局；枚举 `--help` flag 与 env，查是否有只读 / secondary 打开模式。
3. **只读复用实测（问题 2，决定性）**：把真实 graph.db **复制**一份（不修改原数据），`chmod -R a-w` 模拟只读挂载，
   用最小 MCP stdio 驱动启动 codegraph-server 指向它，观察 open 行为与查询结果。
4. **共享方案实测（问题 3）**：启动 `--serve` 常驻引擎，改动 workspace 文件观察是否自动增量；
   核对 `--serve/--connect` 的传输形态（socket 类型）与其能否跨 microVM 边界。
5. **对抗式交叉验证**：对「第 1 步失败」「第 2 步失败」两个关键判断各派独立 agent 尝试**证伪**
   （含 clone CodeGraph 源码逐行审计、`nm`/strings 二进制符号核对、官方文档反查），再综合判断。

> ⚠️ 方法教训：问题 1 一度因只看仓库固定的 botocore 1.42.96（旧模型无 EFS 字段）误判为「不可行」；
> 对抗验证发现 2026-05 的新能力后，**下载最新 botocore 解包核验**（可复核的机器事实）才修正结论。
> **API 能力结论必须对照实时模型 / 官方文档，固定的旧依赖会误导。**

---

## 4. Evidence（实测证据）

### 4.1 AgentCore `filesystemConfigurations` 模型：旧版 vs 最新版 📄文档（机器级核验）

> ⚠️ 留痕说明：本机固定的 botocore **1.42.96** 实装中 union **仅** `sessionStorage`（与下表「旧版」一致，本机直接可核）；
> 「最新版」一行来自一次性 `pip download botocore`（拉到 **1.43.30**）解包其服务模型，**本机现有依赖不含该字段**，
> 须按附录 A 命令复现。下方贴出解包得到的 union 原文以便离线复核。

| 版本 | `FilesystemConfiguration` union 成员 | list 上限 |
|---|---|---|
| botocore 1.42.96（仓库固定，本机可核） | 仅 `sessionStorage` | `max:1` |
| **botocore 1.43.30（最新，须按附录 A 复现）** | `sessionStorage` / `s3FilesAccessPoint` / **`efsAccessPoint`** | **`max:5`** |

从 1.43.30 的 `bedrock-agentcore-control/2023-06-05/service-2.json.gz` 解包得到（节选）：

```json
"FilesystemConfiguration": { "type": "structure", "union": true, "members": {
  "sessionStorage":     { "shape": "SessionStorageConfiguration" },
  "s3FilesAccessPoint": { "shape": "S3FilesAccessPointConfiguration" },
  "efsAccessPoint":     { "shape": "EfsAccessPointConfiguration" } } }
"FilesystemConfigurations": { "type": "list", "member": {...}, "max": 5, "min": 0 }
"EfsAccessPointConfiguration": { "type":"structure", "required":["accessPointArn","mountPath"], ... }
"EfsAccessPointArn": { "pattern": "arn:aws[-a-z]*:elasticfilesystem:...:access-point/fsap-[0-9a-f]{8,40}" }
```

`MountPath` 正则 `/mnt/[a-zA-Z0-9._-]+/?`（单层）。`ContainerConfiguration` 仅 `containerUri`（没有透传 volume/privileged 的字段）。

### 4.2 AWS 官方文档要点 📄文档（WebFetch 于 2026-06-16 抓取核验）

> 来源（抓取日期 2026-06-16）：What's New `.../whats-new/2026/05/amazon-bedrock-agentcore-runtime/`；
> devguide `runtime-filesystem-configurations.html` 与 `agentcore-vpc.html`。下表「原文要点」中**带引号者为逐字引用**，
> 未加引号者（如「只读靠 IAM，非内核 ro flag」）为本报告对文档语义的**转述/推断**，已显式标出。

| 维度 | 文档原文要点 |
|---|---|
| 能力与状态 | What's New（2026-05-06）："now supports bring-your-own file system from Amazon S3 Files and Amazon EFS"；GA（发布时称 15 个区域，区域数易变，以该日 What's New 为准） |
| 只读做法 | devguide 原文 "Omit `ClientWrite` if your agent only needs read access"；*（转述）* → 只读靠 IAM，非内核 ro flag |
| 挂载机制 | NFSv4.1 over TLS（2049）；`amazon-efs-utils` 预装；**no privileged containers**；AgentCore 在 microVM 内自动挂 |
| 共享语义 | EFS = "Shared – multiple sessions and agents access the same data"、"Customer-managed (permanent)"、close-to-open 一致性 |
| 前提 | 必须 `networkMode: VPC`；EFS mount target 与 runtime **同账号 / 同 VPC / AZ 重叠**；不支持跨账号 VPC |
| 失败语义 | 挂载失败 `InvokeAgentRuntime` 返回 **HTTP 424**；每挂载 30s 超时；并行挂载任一失败则整次失败 |

### 4.3 CodeGraph 索引引擎与只读复用 ✅实测 + 📄源码

- 引擎：`~/.codegraph/graph.db/` 是标准 **RocksDB** 目录（`*.sst`/`CURRENT`/`LOCK`/`LOG`/`OPTIONS`/`.log` WAL）；
  二进制 strings 命中 `codegraph::storage::rocksdb_backend`。`--help` 全集**无只读 / secondary flag**，env 无只读项。
- **只读挂载实测（决定性）**：副本 `chmod -R a-w` 后启动 codegraph-server，STDERR：

  ```
  RocksDB graph.db open failed: Failed to write graph.generation: Permission denied (os error 13)
        — running in-memory only ...
  ```
  随即退化为**空内存索引、从头重扫**（查询 `total_matches=0`，未读既有索引）。

- **源码佐证**（对抗验证 clone 源码）：codegraph-server 9 处 RocksDB open 全是读写（`open()`/`open_with_stale_lock_recovery()`）；
  `nm`/strings 仅引用 `rocksdb_open`（读写），**无** `rocksdb_open_for_read_only`/`rocksdb_open_as_secondary` 符号。
  库 crate 里**实现了** `open_as_secondary`（只读、不抢锁、有单测）但**未被调用，二进制零调用**。v0.18.5 即仓库当前版本。

### 4.4 共享 + 实时同步方案（`--serve` 常驻引擎）

- ✅实测 — `--serve` 启动后**自带 file-watcher 实时增量**：改动 workspace 文件，serve 日志即
  `[file-watcher] Processing 1 changes ... indexes rebuilt`，**无需另行运行 `--watch`**（避免两个进程同时写入）。
- ✅实测 — `--serve` 启动后在 `--socket` 路径创建一个 **Unix domain socket**（默认 `~/.codegraph/cg-engine.sock`，本机观察到该 socket 文件存在、为 UDS 类型）。
- 📄文档（`--help` / 源码）— `--connect` 是瘦客户端，中继本进程 stdio 到该 socket、**不加载图与模型**。
  此运行时行为**本机未实测验证**（见 §6），仅据 `--help` 与源码描述。
- ✅实测 — project slug 由 workspace 路径派生（观察到 `ws-9543` / `tmp-fa5b` / `<旧目录名>-9f9e`；末者为改名前目录名所派生的历史实测值，目录改名后会变）。

---

## 5. Discussion（分析）

### 5.1 源码方案成立，且与 AWS 模型结构吻合
客户 EFS 只读挂载是 AgentCore 2026-05 GA 的一等能力，它这套二分——「共享只读 BYO-FS」对「每会话独占的 managed session storage」——
恰好对应 source-truth 的两类存储：`/mnt/repo` 共享只读源码、`/mnt/workspace` 每会话独占临时盘。源码是普通文件 + 独占写入
（仅 index-service 的 git pull 写、会话只读），NFS 对此安全。**问题 1 = 可行**。

### 5.2 索引只读复用为何失败：RocksDB open 即写
RocksDB 在 open 时必须写目录（建 LOCK / 新 MANIFEST / CURRENT / `graph.generation`），这是设计使然，与「数据文件是否只读」无关。
只读挂载（IAM 省略 `ClientWrite`）必然令这些写失败，而 codegraph-server 的失败分支是**静默退化为空索引重建**——
最坏情况：答案基于空索引，违背「代码为唯一依据」。**问题 2 = 不可行（针对 v0.18.5 当前行为）**。

> ⚠️ 限定：本机实测用 `chmod -R a-w` 副本模拟只读（触发 **EACCES**, errno 13）；真实 NFS 只读挂载产生 **EROFS**(errno 30)。
> RocksDB 在两者下的失败分支预期一致（无法写入 = 退化），但「真实 EROFS 下行为」归入 §6 端到端待测，本判定不替代该实测。

### 5.3 为何只能走 Model B（远程常驻引擎）
「共享 + 实时同步」三要素——单一份索引、跨会话可见、秒级跟随 push——恰好是常驻引擎的原生形态：
唯一一份 graph.db 由 index-service 的 `--serve` 进程独占读写（放本机 EBS，不放 EFS，回避 RocksDB-over-NFS 多进程写入损坏），
file-watcher 提供实时增量；会话容器不持有索引、经网络查询。

但有一道**硬约束**：v0.18.5 的 `--connect` 走本地 Unix socket（`--help` 确证 `--socket` 仅 UDS），**跨不出 Firecracker microVM**。
故会话容器无法直接 `--connect`，传输层**须加一层 stdio→streamable-HTTP 桥**——这正是 [`architecture.md`](architecture.md) 标注的主要风险，
本方案把它显式化为独立常驻组件。VPC 模式（4.2 已确认 EFS 挂载本就要求 VPC）也让 microVM 能经 TCP 连到 index-service。
（注：「须加桥」是 v0.18.5 现状所迫——若未来 `--connect` 支持 TCP/streamable-HTTP，可绕过自建桥；属版本敏感面，见 §6。）

### 5.4 路径对齐风险在 Model B 中收敛为单进程内部约束
project slug 由 workspace 路径 hash 派生（§4.4 实测 `ws-9543` 等）；过去它会卡在跨进程上——要求容器与 index-service 的挂载点完全一致。
Model B 下只有 index-service 打开 graph.db、会话从不碰，故该风险**收敛为 index-service 单进程内部约束**（其 `-w` 路径须与建库时一致，
否则 slug 不匹配会另起空图），不再跨 microVM 暴露——更可控，但并未消失。

---

## 6. Limitations（边界与未覆盖项，诚实标注）

- **Model B 查询通路尚未在本机完成端到端验证** ⚠️待验证（主要风险）：本 spike **尚未完成一次成功的 `--serve` ← `--connect` 往返查询**
  （本机最小 stdio 驱动未验证通过 `--connect`，疑似 framing 差异），更未验证跨 microVM 的桥。即「会话经远程引擎查到结果」这一 Model B 核心通路
  **目前仍是架构推断**（依据是 §4.4 实测到的 socket 本地性 + `--help`/源码描述），尚无端到端证据。**不应**把 §6 下文「桥未实现」误读为「仅缺桥实现、往返已验证」：
  往返本身也未验证通过。首次端到端验证须在「桥 spike」完成。
- **初版未部署 AgentCore Runtime** ⚠️待验证：问题 1 结论来自 API 模型 + 官方文档（无本机部署），AWS 为只读权限，
  **未端到端实测**「IAM 省略 ClientWrite 时容器内写 `/mnt/repo` 是否返回明确 EROFS」「close-to-open 下 push 后会话多久读到 / 能否读到半写态」「冷启 ENI + 挂载延迟 vs 30s 超时」。这三项触及只读边界与一致性，文档无法确认，须在部署阶段补实测。
- **stdio→HTTP 桥未实现 / 未压测** ⚠️待验证：本 spike 确认了「须有桥」与传输约束，但桥的具体实现、并发、超时、流式、microVM 内可达性均未验证——这是 Model B 的主要待验证点。
- **CodeGraph 召回率 / 增量删除语义** ⚠️待验证：本 spike 聚焦存储与共享机制，未测后端 Node.js/Lua 召回率与 push 后旧符号残留（另见 [`indexing-performance-spike.md`](indexing-performance-spike.md) 的相关待办）。
- **版本绑定** ⚠️待验证：问题 2 结论绑定 codegraph-server v0.18.5；未来版本若接通 `open_as_secondary`（已实现但未启用）或令 `--connect` 支持 TCP/streamable-HTTP，可能改变结论与「须自建桥」的判断，版本守卫须监测漂移。

---

## 7. Conclusions（结论 — 回答 §2 的提问）

| 问题 | 结论 |
|---|---|
| 1. 会话容器能否只读挂载客户 EFS？ | **能，已通过真实部署验证**（✅实测 2026-06-17，东京 ap-northeast-1）。Runtime `source_truth_agent-3nxWGkGA86` 挂载 EFS `fsap-0749...` 到 `/mnt/repo`，agent 经 Glob/Read 读取到源码。需 botocore≥1.43（含 `efsAccessPoint` 模型）、`networkMode=VPC`、mountPath `/mnt/<单层>`、出站经 NAT。 |
| 2. 共享卷上的 CodeGraph 索引能否被会话只读复用？ | **不能**（✅实测 + 📄源码，证据最充分）。RocksDB open 即写，只读挂载写失败并静默退化为空索引重建 |
| 3. 可行的共享 + 实时同步方案？ | **Model B，stdio 侧已验证**（✅实测 2026-06-17）：`index-service/codegraph_client.py` 用 `mcp` 包驱动 codegraph-server stdio MCP（42 工具、查询到符号）。索引常驻 `--serve`（file-watcher 实时增量 ✅）、EFS 只放源码。HTTP 侧（暴露给 microVM）+ 跨容器往返仍待实现。 |

**总判断（分级校准）**：

- **索引只读复用 = 确定性否决**（✅实测，证据最充分）——这是本 spike 唯一被端到端验证的结论。
- **源码 EFS 只读挂载 = 有条件成立**——依赖 §6 部署阶段三项实测（EROFS 只读边界 / close-to-open 新鲜度 / 冷启挂载延迟）。
- **Model B 远程查询 = 架构自洽，依赖桥 spike**——查询通路尚未在本机完成端到端验证（见 §6），实时同步部分（`--serve` 自带增量）已实测。

因此方向可行，但支持材料仍以「文档 + 推断」为主：唯一强实测是「容器本地直读索引不可行」。下一步把风险收敛到 **stdio→HTTP 桥** 与 **EFS 部署实测** 两个后续 spike。

---

## 8. Next Steps（后续）

- [x] **AgentCore + EFS 端到端实测** ✅ 2026-06-17：东京（ap-northeast-1）真实部署，EFS 挂 `/mnt/repo`、agent 读取到源码。**要点**：须 botocore≥1.43；VPC microVM 无公网 IP，出站须 **NAT Gateway**（VPC Endpoint 只覆盖单服务，不足以覆盖 claude-code CLI 全部出站）。
- [x] **CodeGraph stdio MCP 驱动** ✅ 2026-06-17：`index-service/codegraph_client.py` 已验证（42 工具 + 查询到符号）。
- [ ] **stdio→HTTP 桥的 HTTP 侧**：把 `codegraph_client` 暴露为 streamable-HTTP 供 microVM 远程查询（并发/超时/流式/鉴权）+ 跨容器往返。
- [ ] **只读边界 / 新鲜度实测**：写 `/mnt/repo` 是否 EROFS、close-to-open 下 push 后会话多久读到、冷启挂载延迟。
- [ ] **依赖版本守卫**：`scripts/check-versions.sh` 加 botocore/boto3 下限（须含 `efsAccessPoint`，即 **≥1.43**）。
- [ ] **修订 [`architecture.md`](architecture.md)**：EFS 职责缩为「只放源码」；索引段改 Model B；补 VPC + NAT + 区域限制（仅东京）三条前提。

---

## 附录 A：复现命令

```bash
# 问题1：核验最新 botocore 模型是否有 efsAccessPoint（可复核的机器事实）
pip download botocore --no-deps -d /tmp/btc
unzip -o /tmp/btc/botocore-*.whl 'botocore/data/bedrock-agentcore-control/*' -d /tmp/btc/ext
python3 -c "import gzip,json,glob; \
  j=json.load(gzip.open(glob.glob('/tmp/btc/ext/**/service-2.json.gz',recursive=True)[0])); \
  print(json.dumps(j['shapes']['FilesystemConfiguration'],indent=1))"

# 问题2：只读复用实测（在副本上，不要修改真实 ~/.codegraph）
cp -r ~/.codegraph/graph.db /tmp/cgtest/.codegraph/graph.db
chmod -R a-w /tmp/cgtest/.codegraph            # 模拟只读挂载（ClientMount 无 ClientWrite）
HOME=/tmp/cgtest codegraph-server --mcp --graph-only -w <repo>   # 经最小 MCP stdio 驱动 initialize+查询
#  预期 STDERR: "Failed to write graph.generation: Permission denied" → 退化空索引

# 问题3：常驻引擎实时增量
HOME=/tmp/cgserve codegraph-server --serve --graph-only -w <ws> --socket /tmp/cg.sock &
#  改动 <ws> 下某文件 → serve 日志出现 [file-watcher] ... indexes rebuilt
```

## 附录 B：测试资源清理

本 spike 未创建云资源（AWS 仅只读调用）。本地临时数据：`/tmp` 下的 graph.db 副本与 `--serve` 测试目录、
最小 MCP 驱动脚本；测试用 `--serve` 进程。清理：终止测试 `--serve` 进程（不要误停真实 `--mcp` 服务）→ 删 `/tmp` 临时目录。
