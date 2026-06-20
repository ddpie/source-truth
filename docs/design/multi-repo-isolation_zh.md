# 多项目 / 多仓库的索引与隔离设计

> 设计权威依据：回答「客户环境里一个机器人对应多个代码仓时，怎么索引、怎么路由、怎么保证机器人之间
> 不互相看到不相关代码」。这是 **post-MVP 能力**（当前 MVP 仅单仓、仅主分支，见
> [`requirements_zh.md`](requirements_zh.md) 与 [`../../AGENTS.md`](../../AGENTS.md) 的 MVP 边界）——
> 本文先把方案与不变量定下来作为权威依据，**先行文档、不动代码**，落地时机另议。
> 架构总览见 [`architecture-overview_zh.md`](architecture-overview_zh.md)；当前单仓实现见
> `index-service/bootstrap.sh` 与 `index-service/http_bridge.py`。
>
> **拓扑前提（commit 88ad623 起）**：bot-gateway 现与 index-service **同机部署（co-located）**——同一台
> EC2、默认同一 OS 用户、无 systemd 沙箱，仅 gateway 单元有 `MemoryHigh/MemoryMax` cgroup 限额（那是
> *OOM 隔离*，不是*安全隔离*）。这对下面的内存预算（§3/§7）与隔离强度（§4）都有直接影响，相关处已标注。
> 另：`--repo` 的多来源解析（local/git/s3）已由 `scripts/lib/resolve_repo.sh` 实现，但那是**单仓多来源**，
> 不等于多仓（见 §6）。

## 1. 需求与现状

### 1.1 客户侧的真实模型

客户环境不是「一个机器人查一个仓」，而是：

```
机器人 (bot)  ──1:1──→  游戏项目 (project)  ──1:N──→  代码仓 { 前端, 后端, 依赖库, 微服务A, 微服务B, ... }
```

- **一个飞书机器人对应一个游戏项目**；
- **一个项目对应多个代码仓**（前后端、依赖库、若干微服务）；
- 一次问答**常常跨同一项目的多个仓**（前端调后端 API、微服务之间的调用），所以项目内必须能联合检索；
- 不同项目之间**必须隔离**：机器人 A 绝不能看到机器人 B（另一个项目）的代码。

### 1.2 当前实现是单仓假设

`bootstrap.sh` / `http_bridge.py` 现在把「单仓」钉死在三处：

1. 单个 `REPO_SUBDIR` → 单一 `LOCAL_WORKSPACE=/data/repo/<subdir>`；
2. 一个 `graph.db`（`$HOME/.codegraph`）+ 一把 `flock` 写锁——**独占写入约束是每张图各自的**；
3. bridge 一个常驻会话、一个 `--workspace`，工具返回该仓的仓库相对路径。

多仓不是「加个 for 循环」就能成，它会冲击上述不变量；隔离更不能靠在工具上加参数糊弄过去（见 §4）。

## 2. 核心设计抉择：每仓独立图，不合并

CodeGraph 支持 `index_directory` 把多个目录塞进同一张图，但对本场景是**坑**，明确不采用：

1. **跨仓符号污染**：多个仓里重名的符号会串、路径不再唯一、产生假的跨仓调用边；
2. **刷新粒度被绑死**：独占写入锁 每图，合并图意味着任一仓更新都要锁住并重建**整张**图；
   微服务仓更新频率天差地别，合并会互相拖累；
3. **合并并不带来想要的跨仓能力**：前端→后端是 HTTP/RPC 的跨进程、跨语言调用，CodeGraph 的静态
   调用图本来就连不起这种边。**「跨仓」靠的是扇出查询 + 文本检索，不是合并图。**

因此底层一律：**每个仓库 = 一张独立 `graph.db` + 独立 workspace + 独立写锁 + 独立的时效戳。**
好处：独占写入约束对每个仓库都自然成立、刷新/重建单个仓库不影响其他仓库、无跨仓符号污染、路径加 `repo` 前缀即可消歧。

## 3. 拓扑选型：项目间用进程边界硬隔离

有两种部署拓扑，代码主体几乎同一套，差别在「别项目的图，本项目的 agent 够不够得到」：

| | 拓扑 A：单 bridge 进程，多图 | 拓扑 B：每项目一个 bridge 进程（**推荐**） |
|-|-|-|
| 进程模型 | 一个 `http_bridge` 进程同时持有所有项目的所有图 | 一项目一个 `http_bridge` 进程，各自只 `--workspace` 本项目的仓 |
| 选仓方式 | 工具加 `repo` 入参，由模型填 | endpoint 即作用域；`repo` 只在本项目仓集合内选 |
| 项目间隔离 | **弱**：别项目的图就在同一进程里，越权/注入/bug 都可能跨界 | **强**：连上的进程里根本不存在别项目的图——模型够不到 |
| 同台主机 | 可 | 可（多进程、多端口） |
| 代价 | 最省资源 | 进程数 = 项目数，内存随项目线性增长（每个常驻 codegraph 会话有固定开销） |

**结论：一旦「机器人不能看不相关代码」是硬需求，必须走拓扑 B。** 拓扑 A 的「`repo` 入参」是
**便利与可解释性**机制，不是安全边界（§4 详述）。同台主机用多进程多端口即可，不必多实例；项目内的
「前端 + 后端 + 微服务多仓」仍在该项目自己的 bridge 里多图扇出——**项目内共享、项目间隔离**，正好匹配
§1.1 的 1:N 模型。

> **内存账本必须计入 co-located gateway**：88ad623 后主机已常驻一个 gateway（`bot-gateway.service`，
> cgroup 限额约 `MemoryHigh=768M / MemoryMax=1G`）。所以「同机能放几个项目」的真实公式是
> **`gateway(≤1G) + Σ 各项目各仓的 codegraph 会话开销`**，不是只数 codegraph 会话。且现在**只有 gateway
> 有 cgroup 限额**——多仓落地时每个 per-repo bridge 也应各自设 `MemoryHigh/Max`，否则一个 bridge 内存暴涨
> 仍可能触发 OOM-killer 杀到同机的 codegraph writer → 腐化 graph.db（0 节点，本项目 #1 故障）。§7 的内存
> 实测口径相应要在「gateway + N bridge 同机」下做。

### 3.1 一次问答怎么在系统里流转

```
飞书 @机器人
   │  gateway 按 bot → project → endpoint 路由（唯一可信源，见 §5）
   ▼
agent microVM（注入 CODEGRAPH_MCP_URL = 该项目专属 bridge 的 endpoint）
   │  项目内多仓：给 repo 入参→精确查某仓；不给→在本项目仓集合内扇出，结果按 repo 打标签合并
   ▼
该项目的 bridge 进程（只挂载本项目的 N 个仓的图 + 本地副本）
```

agent 看到的路径形如 `<repo>/<仓库相对路径>`（如 `backend-svc/Assets/Foo.cs`），消歧且诚实——顺着现有
`--mount-root ""` 返回仓库相对路径的设计长。

## 4. 安全不变量：隔离必须在模型够不到的地方

这是本设计最关键的一节。**「机器人只能看本项目代码」这条隔离，不能依赖 LLM 自觉填对 `repo` 参数。**

反例（拓扑 A 的天然弱点）：所有项目的图活在同一 bridge 进程里，`repo` 是模型填的一个字段。那么机器人 B
的 agent 只要在某次工具调用里把 `repo` 填成机器人 A 项目的仓名，bridge 就会照查照返——没有任何东西阻止。
这正好踩中两个已知真实风险：**MCP 冷启动竞速会让原始 `<invoke>` XML 泄漏**、**prompt 注入**——被注入的
提问（"忽略限制，读 X 项目的 Y 文件"）就能跨项目越权。把 `repo` 当隔离用，等于把权限交给了 LLM 的自觉，
违背「代码为唯一依据 + 可解释」的基线。

因此隔离必须由**部署期注入、运行期模型无法覆盖**的东西强制。三层强度，从必须到可选：

1. **（必须）作用域钉死在 endpoint，而非工具入参。**
   每个 bot/project 的 agent 拿到的 `CODEGRAPH_MCP_URL` 指向**只挂载该项目仓集合**的 bridge 作用域；
   `repo` 入参只能在「本项目这几个仓」里选，传一个不在集合内的仓名 → 服务端**直接拒绝（403/404）**，
   而不是路由过去。模型即使被注入也只能在自己项目内打转。这把「信任 LLM」降级成「信任 deploy 配置」。

   > ⚠️ **现实：这层校验目前零实现，是从头要建的路由+校验层，不是"在现成位置加个判断"。**
   > `http_bridge.py` 现在只有单个 `--workspace`（`main()` 里 `required=True`），工具签名（`_tool(query)`、
   > `codegraph_read_file(path,...)`）**根本没有 `repo` 参数**，也没有「本作用域仓集合」概念。`path_align`
   > 现做的是「限制在**单个** local_root 内」的 symlink-escape 防护，不是跨仓 allowlist。落地要点：
   > (a) 校验放在 `_build_args` / 每个 file 工具入口，做 `repo` 归一化 + **白名单成员检查（默认拒绝）**；
   > **作用域仓集合以 bridge 启动参数（`--workspace` 集合）为唯一权威**，gateway 注入的仓名只作 UX 提示；
   > **默认值=空集=拒绝一切**（绝不"宽松默认"放行）。
   > (b) `repo` 缺省的「项目内扇出」只枚举本作用域集合，**绝不接受任意字符串**；
   > (c) `repo` 解析后**必须再过一次 `path_align` realpath 防护**，且其 root **必须是解析后的具体仓目录
   > `/data/repo/<resolved_repo>`，不得是项目根**——否则 root 设成项目根时 `<repoA>/../repoB` 仍在根内、
   > realpath 会**放行**跨仓穿越，纵深第二层形同虚设。回归测试必须覆盖 `repo=repoA&path=../repoB/secret`。
   >
   > **项目内隔离完全押在这一层（第 1 层 allowlist + 进程不被 RCE）单层上**——见第 2/3 层对"项目内多仓"
   > 为何无效。故第 1 层未落地并通过上述回归前，多仓绝不可对多项目环境放量。

2. **（推荐）进程级隔离 = 拓扑 B。** 一项目一 bridge 进程，连上的进程里根本不存在别项目的图，
   越权/注入/未来工具变更都无法跨界。这是「够不到」而不仅是「不该够」。

3. **（同主机多项目的必做）OS 用户 / 文件系统边界。**
   **进程边界 ≠ 主机边界。** co-location（88ad623）后 gateway + 各项目 bridge + codegraph writer 全在
   **同主机、默认 root、无 systemd 沙箱**（`bootstrap.sh` 的三个单元都没有 `User=`/`DynamicUser=`/
   `ProtectSystem=`——现状即 root，比"未做隔离"更需优先降权）——「连上的进程里没有别项目的图」只挡住
   *经 MCP 工具的逻辑越权*，挡不住*主机级威胁*：任一 bridge 或 gateway 被 RCE，同 uid 即可直接 `open()` 读
   `/data/<其它项目>/...` 的全部源码；gateway 与 writer 同 uid 时被攻破还能写 `graph.db`、破坏「代码为唯一
   依据」的取证完整性。故同主机多项目至少要：(a) 每项目用**独立 OS 用户**跑其 bridge，各自 `/data/<repo>`
   `chmod 0700`，且**第一步是让 bridge 不再以 root 跑**；(b) 给 index 服务单独的低权用户（与 gateway 分离）。
   **跨信任域 / 跨客户的项目不可同主机**——那必须走第 4 层。

   > ⚠️ **0700 / per-uid 边界只在「跨项目」生效，对「项目内多仓」无效。** 拓扑 B 是「一项目一 bridge 进程、
   > **项目内 N 仓在同一进程同一 uid**」。所以 uid/0700 把项目 A 与项目 B 隔开（A 进程 uid ≠ B 进程 uid，
   > 即便 RCE 也读不到对方目录）；但**同项目的多个仓共进程共 uid，彼此无任何文件系统隔离**——同进程内 RCE
   > 可直接读其他 workspace 的闭包变量、用同 uid `open()` 同项目任意仓。**推论**：若某仓含只该被部分 agent
   > 看到的敏感内容（如只后端该读的密钥配置），同进程拓扑给不了保护，必须把该仓拆成**独立进程**（牺牲扇出），
   > 即「项目内若存在不可互信的仓，也按跨信任域处理」。**项目内隔离的唯一边界 = 第 1 层服务端 allowlist +
   > 进程不被 RCE**，0700 帮不上忙。
   >
   > 安全注意：§7 原则 7 要"据 manifest 自动生成 OS 用户 / 0700 / cgroup"——这是**特权操作生成特权配置**，
   > repo 名进入 `useradd`/路径/单元名前必须过严格白名单（`^[a-z0-9-]+$`，与空值删根防护同级逐仓校验），
   > 且生成后要有**机器可验证的事后断言**（核对每个 bridge 进程 uid 确为 per-project 专用且 ≠ root、
   > `/data/<repo>` 确 0700 owner 正确），不能停在"自动 = 默认正确"。

4. **（强隔离场景）网络层 + 实例层隔离。** 每项目 index-service 单独实例 + 安全组只允许对应会话
   microVM 访问。客户提出强隔离合规要求、或跨信任域多项目时走这一档。

> 与现有只读边界的关系：当前「只读」的权威保证是**服务端闭合 allowlist**——bridge 只 `add_tool`
> 注册若干只读工具，mutating 工具根本没有 MCP 描述符供模型命名（见 `agent_lib.py` 的
> `CODEGRAPH_WRITE_TOOLS` 注释）。**项目隔离应当复用同一套「服务端强制」哲学**：越界仓名由服务端拒绝，
> 不靠 agent 侧自律。

## 5. 配置与运营模型

真正要管理的状态很少：一张映射表 + 两个动作。

```
bot → project → { repo 集合 }
repo → 来源（git URL / 分支 / S3 tar / 本地目录）
```

- 动作一：**改映射**（加项目、给项目加/减仓、换分支）；
- 动作二：**刷新某个仓的索引**（重新拉代码 + 重建该仓的图）。

> **来源解析已实现一半**：`scripts/lib/resolve_repo.sh`（88ad623）已能把 `--repo` 的 local dir / git URL /
> s3:// 统一落成本地目录再走 tar→S3 路径（`classify_repo_source` / `fetch_repo_source`）。但这是**单仓多
> 来源**——多仓不必重写来源解析，只需对 `REPO_SUBDIRS` 列表**循环复用** `fetch_repo_source`、并 per-subdir
> 戳 `ARTIFACT_SIG`。下面 §6 的改动按"复用而非新建"理解。

「谁来做这两个动作、多久做一次、是否客户自助」决定运营形态。**Web 管理后台不是做本功能的前置条件**，
按需求强度分三档演进，每档的安全责任不同：

| 档位 | 形态 | 适用 | 安全责任 |
|------|------|------|----------|
| **① 配置文件即权威依据**（起步） | `config/projects.yaml` 钉死 bot→project→repos→endpoint；gateway 读它路由，deploy 读它决定建哪些图；改完重部署 / 局部刷新 | 你们工程团队自己运维 | 走 git review + 回滚，无新攻击面 |
| **② 飞书内管理指令** | 管理员 @机器人 发 `/项目 列表`、`/索引刷新 <project>` 等，复用现有网关通道 | 客户要轻量自助，但不想碰 YAML / 脚本 | 指令级权限校验（谁是管理员）；复用已有通道，不引入新前端 / 鉴权栈——**性价比最高的中间档** |
| **③ Web 管理后台** | 独立前端，项目 / 仓 / 索引的可视化自助管理 | 交给客户非技术人员大规模自管 | **本身是有安全面的新组件**：登录鉴权、操作审计、Secrets 处理；且它是**能打破项目隔离的入口**（改映射表 = 改谁能看什么），必须连带把鉴权 + 审计 + 变更流程一起设计 |

**判据**：改映射 / 触发刷新的人是工程团队 → 停在 ①；是客户非技术人员且操作频繁 → 才上 ③，否则 ②
往往就够。这与 AGENTS.md「审计护栏后置」「增删身份行为需先问」一致——③ 不是给现有功能加壳，而是一个
独立的、有安全面的新组件，等需求真出现再按新组件立项，不能顺手加。

## 6. 对现有代码的改动面（拓扑 B，落地时参考）

> 仅为评估改动范围，**当前不实施**。

| 位置 | 现状 | 多仓 / 隔离改成 |
|------|------|------------------|
| `config/`（gateway） | 按会话路由 | 新增 `projects.yaml`：bot→project→repos→endpoint 映射（§5 ① 的权威依据） |
| `index-service.env` | 单个 `REPO_SUBDIR` + 单标量 `ARTIFACT_SIG` | `REPO_SUBDIRS`（列表）+ **每仓一个时效戳**。⚠️ **env 编码踩过雷**：`ARTIFACT_SIG` 含多段 ETag 的 `\|`，裸写进 `.env` 被 `source` 当管道炸 bootstrap（见项目记忆「deploy env 文件必须单引号」）。多仓后是「N 个含特殊字符的 sig + N 个 subdir」，**建议用单个 JSON 变量承载**（`REPO_MANIFEST_JSON`）而非多 shell 变量，规避 source 注入；沿用单引号写入约定 |
| `bootstrap.sh` | 单 workspace、单 build/serve 单元 | 循环每个 subdir：**独立 `HOME=/data/<repo>`**（必须——codegraph 把 `graph.db` 和 `projects/<hash>/memory` 都放 `$HOME/.codegraph`，多图共用 `/data/.codegraph` 会**互相覆盖**）、**per-subdir flock 路径** `/data/<repo>/.codegraph/.writer.lock`（现在是全局单锁 `/data/.codegraph/.writer.lock`）；build/serve 单元参数化（systemd template `index-build@.service` / `index-bridge@.service`，各自 `--port`） |
| `http_bridge.py` | 单 session、单 `--workspace`、进程级 `_SINGLETON_FD` 单锁 | 该项目内启动 N 个常驻会话（各自 worker 线程 + 写锁，**独占写入约束每仓成立**）；锁从「进程单例 fd」改成**每 workspace 一把**；工具加 `repo` 路由 / 项目内扇出；**越界仓名服务端拒绝**（§4 第 1 层）。⚠️ **`codegraph_session.py` 的 orphan reaper 跨 session 误杀**：`_scan_orphan_servers` 用 `pgrep codegraph-server.*--workspace <ws>` 锚定，`re.escape` 只防元字符——`code-5x` 与 `code-5x-svc` 会**前缀误匹配**，一个 session 重启时可能 SIGKILL 另一个健康 session 的 codegraph-server（直接违背「刷新单仓不影响其他仓」）。必须改成**末尾精确锚定**（`--workspace <ws>(\s\|$)`） |
| `path_align.py` | 仓库相对路径 | 加 `repo` 前缀（如 `backend-svc/Assets/Foo.cs`） |
| root volume | 单仓副本 + 单图 | 按「项目内所有仓副本 + 所有 graph.db」之和放大；`require_disk_headroom` 改为按仓累计校验 |

### 6.1 必须警惕的坑

1. **空值删根**：`bootstrap.sh` 的 `: "${REPO_SUBDIR:?...}"` 空值保护（防止空 subdir 让
   `rm -rf "$LOCAL_WORKSPACE"` 误删整棵 `/data/repo`）在多仓循环里**每个 subdir 都要单独保**——多仓最容易
   在这里写出「空元素 → 删根」的事故。
2. **per-repo HOME 隔离**：见上表，多图共用 `$HOME/.codegraph` 会互相覆盖 graph.db / memory，**必须**
   每仓独立 `HOME=/data/<repo>`，这是文档只说「graph.db 独立」时隐含的连锁必改点。
3. **orphan reaper 误杀**：见上表，pgrep workspace 前缀误匹配会让一个仓重启杀掉另一个仓的 server。
   阶段 0 spike 就要先验「N session 同进程、其中一个崩溃重启不波及其他」——这比「内存 ×N」更该先验。

## 7. 运维友好（一等设计目标，不是事后补）

多仓最大的运维风险是「仓越多，加一个仓/刷一个仓/排一个仓的故障越痛」。下列原则把"运维友好"钉成硬约束，
落地时每条都要有对应实现，否则多仓在生产会以"改一处牵全身、出事说不清哪个仓"的形式反噬。

1. **单一可信源，声明式**：所有「项目→仓→来源」只在一处声明（§5 ① 的 `projects.yaml` / `REPO_MANIFEST_JSON`）。
   运维改这一处即代表全部意图，deploy 据它收敛——**不在多个脚本/env 里重复维护仓清单**。

2. **加/减一个仓 = 改一行 + 一条命令**：加仓不该需要手写 systemd 单元、手挑端口、手算磁盘。bootstrap 据
   manifest **自动**为每个 subdir 实例化 `index-build@<repo>` / `index-bridge@<repo>`、**自动分配端口**、
   按累计需求校验磁盘。运维只声明仓，不碰机制。

3. **单仓刷新不波及其他仓（增量、隔离）**：刷新某个仓只重抽+重建**那一张图**（per-subdir `ARTIFACT_SIG`
   只命中变了的仓），其余仓的 bridge 会话**不停服、不重建、不被 reaper 误杀**（§6.1 第 3 点是其硬前提）。
   提供 `--refresh-repo <project>/<repo>` 粒度，而非只能整机重部署。

4. **每个仓的健康与新鲜度可一眼看清**：运维要能一条命令看到「每个仓：图节点数、上次索引时间、对应源 ETag、
   bridge 端口/存活、内存占用」。对接规划中的 `ops.sh status`（见 `scripts/README.md`），把单仓的健康面
   **按仓平铺**——哪个仓是 0 节点 / 索引过期 / OOM 重启，一眼定位。

5. **故障可归因到具体仓，失败要响**：任何 build/serve 失败的日志、systemd 单元名、健康探针都带 `<repo>`
   维度（沿用现有 `BOOTSTRAP_FAILED:` 风格的 greppable 标记 + per-repo 单元名），**不允许**一个仓的故障表现成
   "整个 index-service 不正常"这种说不清的状态。

6. **幂等、可重跑、可回滚**：deploy / 刷新对已就绪的仓是 no-op（ETag 未变不重建），中途失败重跑不产生半成品；
   manifest 走 git，改错能 `git revert` 回滚。沿用现有 deploy 的幂等与确定性 tar（88ad623 已 pin sort/mtime
   保证 ETag 稳定）。

7. **安全默认不增加运维负担**：§4 的 per-project OS 用户 + `0700` 数据目录、per-repo cgroup 限额，应由
   bootstrap 据 manifest **自动生成**，不要求运维逐项目手配——隔离是默认产物，不是手工清单。

> 一句话：**运维只声明「哪个项目有哪些仓、各从哪来」，其余（建图、起服务、分端口、限内存、隔离、刷新、
> 健康面）全部由 deploy/bootstrap 据 manifest 自动收敛。** 这是多仓能不能在客户现场长期跑下去的关键。

### 7.1 与现状的差距（这些"自动收敛"是新建能力，不是改参数）

上面 7 条是**目标**；对照现状代码，落地前要补的关键能力（按运维痛感排序）：

1. **单仓 in-place 刷新 vs 现状整机蓝绿（最关键）**：现在 `--refresh-index` 是**整台 EC2 蓝绿替换**
   （`deploy-all.sh` 据**单标量 `ArtifactSig` EC2 tag** 整机匹配，user-data 不重跑、reused 实例不重 bootstrap）。
   改 10 个仓里的 1 个，现状会重建全部 10 个图、整机替换、其余 9 仓 bridge 全部冷启。`--refresh-repo
   <project>/<repo>` 要落地 = **新造一条 in-place 单仓重建路径**（经 SSM 进实例 → 单仓重抽 → per-repo flock
   → 重建该图 → 仅重启 `index-bridge@<repo>`），与现整机蓝绿并存。**它的硬前提是 reaper 末尾锚定（§6.1#3）+
   per-repo cgroup（下条）**——否则 in-place 单仓操作反而触发跨仓误杀/OOM 外溢。这三项绑成「运维友好最小
   可用集」，齐备前不放量。
2. **per-repo cgroup 是隔离的内存维度（升为硬要求）**：现在**只有 gateway 单元有 `MemoryHigh/Max`**，
   index-build/bridge 无限额。多仓不设 per-repo cgroup，则一个仓 OOM 会让内核 OOM-killer 杀到**别仓的
   writer** → 0 节点损坏，叠加 reaper 误杀 → **单仓故障外溢成整机故障**。per-repo `MemoryHigh/Max` 必须由
   bootstrap 据 manifest 自动生成（与"自动分端口"并列，不是可选注记）。
3. **端口 / 磁盘 / 安全组的隐藏手工步骤**：现 bridge 端口写死 `8080`、安全组只开 8080 单端口、root volume
   默认 30G 按单仓算且**扩容需整机替换**（EBS 大小 launch 时定）。多仓后端口随仓数增长 ⇒ 安全组 ingress
   需自动 reconcile；磁盘累计极易超 30G。"改一行 + 一条命令"若伴随扩容/端口变化，应诚实写成"改一行 +
   一次整机蓝绿"，并把这些都纳入 manifest 驱动的自动 reconcile，否则就是隐藏手工负担。
4. **过渡期排障手段（`ops.sh status` 落地前）**：`ops.sh status` 现未实现（`scripts/README.md` 标 p2）。
   per-repo 单元名（`index-bridge@<repo>`）+ greppable `<repo>` 标记应是**阶段 2/3 的附带产物、先于 `ops.sh`**，
   并在 runbook 补过渡手段：`systemctl status index-bridge@<repo>` / `journalctl -u index-bridge@<repo>` /
   `curl /health?repo=<repo>`——否则 7.4/7.5 在 `ops.sh` 到来前是纸面承诺。
5. **容量可观测**：运维要能看到「主机内存/磁盘水位 + 每仓占用 + 按当前 cgroup 预算还能加约 N 仓」并有换机
   阈值告警（如剩余内存 < 1 个 bridge 预算即报警），否则往往 OOM/磁盘满才发现该换机。
6. **manifest ↔ 持久化的权威关系**：实例选择器要从「单标量 `ArtifactSig` tag」改为「manifest 内容哈希
   tag（整机一个稳定哈希）」，per-repo sig 存实例内 per-repo stamp 文件（沿用现 `.artifact_sig` 模式改 per-repo）。
   EC2 tag 有长度上限，N 个仓 sig 塞不进一个 tag。
7. **多仓安装入口**：`install.sh` 交互式当前只问单 `REPO_SRC`/`REPO_REF`；多仓一律走 manifest + `deploy-all.sh`，
   或扩 install.sh 支持 manifest 录入——二者衔接需在运营档位①写明。

## 8. 待验证 / 待确认

| 项 | 关注点 |
|----|--------|
| 单台主机内存上限（**含 co-located gateway**） | 公式 = `gateway(≤1G) + Σ codegraph 会话`；实测必须在「gateway + N bridge 同机」下做，并据此给每个 per-repo bridge 设 cgroup 上限，确认「少量项目（≤约 10）同台主机」的可行边界 |
| **多 session 崩溃隔离**（先于内存验） | N session 同进程，其中一个 codegraph-server 崩溃重启时，orphan reaper 不得误杀其他健康 session（pgrep 末尾锚定）；这是不变量「刷新单仓不影响其他仓」的硬验证 |
| 项目内扇出的延迟与召回 | N 个仓并行查询 + 按相关度合并的耗时；跨仓文本检索（前端找后端 API 字符串）的召回质量 |
| 越界仓名拒绝的实现位置 | 在 bridge 路由层校验 `repo ∈ 本作用域仓集合`（白名单默认拒绝）+ realpath 二次防护，确认 403/404 而非静默路由；与冷启动竞速泄漏的交互 |
| gateway 路由表的可信源与热更 | `projects.yaml` 变更后是否需重启 / 重部署；与 §5 各运营档位的衔接 |
