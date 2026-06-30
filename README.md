# source-truth

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Runtime](https://img.shields.io/badge/AWS-Bedrock%20AgentCore-orange.svg)
![Engine](https://img.shields.io/badge/Claude-Code%20Agent%20SDK-7c5cff.svg)

[中文](#source-truth) | [English](#english)

> 在飞书里 @ 机器人，用业务语言回答「这个技能 / 数值 / 规则到底怎么算」。答案来自项目**最新主分支的真实代码**，并附可复核的出处。

「这个技能的冷却怎么算」「负重上限和力量是什么关系」——答案都写在代码和配置表里，但策划查不动代码，研发被反复打断。source-truth 让策划在飞书直接问，AI 读真实代码、定位依据，再用业务语言回答。

## 四个特点

- **答得可信，且能复核**：以真实代码为唯一依据，每条结论附 `文件:行号` 出处（折叠在「供研发复核」区，策划看结论、研发按需展开）。代码与文档冲突时以代码为准并标注差异；证据不足时提示转研发，不猜不编。
- **大代码库不拖慢定位**：常驻 CodeGraph 索引先定位、再精准读取，不全仓扫描。16 GB、7.5 万文件的工程上，定位查询稳定在 **1–5 毫秒**；整轮问答比原生 Claude Code 快 **2.7–5.1 倍**。
- **中文提问也能命中英文代码**：策划问「公会战怎么结算」，代码里却可能写成历史代号 `LeagueWar`；「招募保底」藏在 `pity_counter` 这类内部叫法里，直接用中文搜常只命中注释、甚至零命中。术语表离线把中文业务词映射到代码里真实出现的英文符号，作为额外检索线索——只负责「该搜哪个英文词」，结论仍以查看代码为准。
- **答案是会生长的交互卡片**：在飞书 @ 机器人即可（免部署、下载、开账号）。卡片实时显示进度、结论先行边写边展开、能画图表 / 表格、出处自动折叠（策划看结论、研发按需展开）；看完点按钮或回复卡片就能带上下文继续追问，手机上同样可用。

> 性能数据来源与复现见 [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) 与
> [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md)。

## 一次真实问答如何发生

下面是飞书群里的一次真实问答（接入的是一套魔兽风格 C++ 服务端代码）：策划问「默认背包有多少格子、怎么扩展」，又追问了仓库格子。卡片实时计时、结论流式展开、出处自动折叠：

![飞书群里一次真实问答的录屏：策划 @机器人提问背包格子，卡片实时显示分析进度与计时，结论先行流式展开，底部「供研发复核」折叠区列出代码出处，可点按钮继续追问](docs/assets/demo-qa.gif)

> 录屏为 3 倍速；卡片标题里的计时是真实耗时（首问 45 秒、追问 1 分 4 秒）。

下面按时间顺序拆解这次问答从提问到出结论的每一步：

![一次问答的端到端时序图：飞书客户端、bot-gateway、AgentCore microVM、index-service、CardKit 五方泳道，从 @机器人提问到流式回填结论卡片](docs/assets/sequence-qa.svg)

| # | 你做什么 / 系统做什么 | 为什么是这一步 |
|---|----------------------|---------------|
| 1 | 你在群里 `@助手 默认背包有多少格子？如何扩展？` | 飞书长连接把消息推给网关，无需轮询 |
| 2 | 卡片立即回「正在分析…」，标题带实时计时 | 说明系统仍在处理，避免误判为无响应 |
| 3 | Agent 用 CodeGraph 定位到背包槽位相关代码，并行查术语表补检索线索 | 术语表是旁路辅助：代码命名多为英文，中文「背包」可能对应别的英文符号 |
| 4 | 读出文件里的真实槽位定义与扩展逻辑 | 先定位再读，不做全仓扫描 |
| 5 | 结论流式回填，先给结论再讲依据（业务语言，不堆砌代码） | 结论先行，非技术读者也能读懂 |
| 6 | 卡片底部展开「供研发复核」折叠区，列出 `文件:行号` 出处 | 研发可直接核对，非技术读者不被代码淹没 |
| 7 | 可点击「继续追问」或直接回复卡片，**带着上文**接着问 | 多轮对话复用同一会话，不丢上下文 |

> 需求与架构权威依据见 [`docs/design/`](docs/design/)；AI 协作约定见 [`AGENTS.md`](AGENTS.md)；
> 一次提问如何在系统里流转见 [`docs/agent/architecture.md`](docs/agent/architecture.md)。

## 能力边界

定位是**只读的代码问答**：只查主分支、只回答，不改动任何东西。明确**不做**：

- 不跑游戏引擎、不做数值模拟
- 不写回代码、不提交、不改任何文件
- 不读设计文档、不跨多分支 / worktree、不做跨会话共享记忆
- 不接第二引擎（Codex）、不做完整的审计防线

这些边界既是产品定位，也是安全保证。规划中的能力见
[`docs/agent/architecture.md`](docs/agent/architecture.md) 与设计文档。

## 系统全貌

飞书客户端 →（经飞书开放平台长连接）网关 → 会话隔离的 microVM → index-service 上的只读代码副本，中间是三个常驻组件。每个会话在各自的 microVM 里互不可见，又都向本项目那份只读副本读代码核对。同一项目下的多仓库联合检索已支持，一台 index-service 主机可承载多个项目（各自独立进程与端口；会话各自跑在独立 microVM 上）。

![source-truth 架构图，按机器分三层：飞书侧 → 一台 EC2（每个项目的 bot-gateway 与 index-bridge 同机，都在 index-service 主机上）→ AgentCore 会话 microVM；事件经长连接推给网关，网关 invoke 会话，会话再经 HTTP 向 bridge 只读访问（定位代码 / 读文件·配置表 / 查术语表）](docs/assets/architecture.svg)

> **会话 microVM 不挂任何文件系统**：源码与配置表都经 index-service 的 HTTP 接口读取（`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files`），代码副本只在 index-service 本地磁盘（每项目各一份，不进 microVM、无第二处）。

## 组件一览（monorepo）

| 目录 | 职责 | 语言 |
|------|------|------|
| [`agent-container/`](agent-container/) | 会话 microVM 内运行的 Claude Code Agent：推理 + 编排 + 查代码 | Python |
| [`bot-gateway/`](bot-gateway/) | 飞书 Bot 长连接事件网关 + CardKit 流式卡片渲染 | TypeScript |
| [`index-service/`](index-service/) | 常驻 CodeGraph 索引服务 + MCP-over-HTTP 接口（定位 + 读文件） | Python |
| [`infra/`](infra/) | IaC：AgentCore Runtime / 索引服务 / 网关 | boto3 + CDK（渐进） |
| [`config/`](config/) | 集中配置：i18n 文案、告警阈值 | JSON |
| [`scripts/`](scripts/) | 部署 / 运维 / 测试生命周期 | Bash |

完整目录树见 [`docs/structure_zh.md`](docs/structure_zh.md)。

## 用到的 AWS 服务

部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。核心是一台共用的 ARM EC2（常驻索引）、
每项目一套 Bedrock AgentCore Runtime（会话隔离的 microVM）、Bedrock 模型推理、S3 / ECR。
全部 21 项服务的规格 / 数量 / 用途见 [`docs/aws-services_zh.md`](docs/aws-services_zh.md)。

## 部署与测试

交互式一键安装（全新账号 / 区域可跑、幂等）。在已配好 AWS 凭证的机器上，一行命令拉起。

仓库公开时，裸 `curl` 即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)
```

仓库私有时，本机先 `gh auth login`（一次），再用 `gh` 取引导脚本（带认证，无需公开仓库）：

```bash
bash <(gh api repos/ddpie/source-truth/contents/scripts/get.sh --jq '.content' | base64 -d)
```

它把仓库克隆到当前目录的 `source-truth/`（私有仓自动走 `gh` 认证克隆），再进入交互式安装。`codegraph-server` 索引引擎缺失时由部署脚本自动下载，无需手动准备二进制。

已克隆仓库则直接跑脚本即可，离线测试无需 Docker / AWS：

```bash
./scripts/install.sh    # 问区域 / 代码仓 / 模型 / 飞书凭证，拉起后端 + 网关
./scripts/test.sh       # 离线套件：lint + unit + typecheck
```

完整部署流程（前置条件、`deploy-all.sh` 分阶段控参、连飞书、运维、排错）见
[`docs/runbook.md`](docs/runbook.md)。飞书凭证走 Secrets Manager，不落盘、不入仓库。

## 代码怎么进入系统、怎么刷新

每个仓库 clone 到 index-service 本地，file-watcher 增量重建索引。两种代码来源：

- **git 仓**（默认）：systemd timer 定时 `git pull`，新鲜度分钟级、无需重部署、无需手动操作。
- **本地仓**（推不到 git 远端时）：用 `scripts/push-local-repo.sh` 经 rsync 直推到主机的快照，手动刷新——代码变更后重跑一次上传命令。

刷新机制与「为何必须建索引」的实测见 [`docs/agent/architecture.md`](docs/agent/architecture.md) 的「数据面」；本地仓上传与单台 EC2 自举（`--local`）见 [`docs/runbook.md`](docs/runbook.md)。

## 安全设计

安全面有三类，且不只靠提示词约束、代码本身会强制执行：**防越权**（Agent 连写工具都不在上下文里，
服务端只注册一组只读工具）、**防泄露**（进群字段全过脱敏，密钥 / 内网拓扑不进群；凭证走 Secrets Manager 不入库）、
**防注入**（工具读到的代码 / 注释一律当待分析数据，只信打包进镜像的 system prompt）。

![安全设计图：防越权、防泄露、防注入三道由代码强制执行的防线，三栏并列](docs/assets/security-defense.svg)

逐条「怎么强制 / 以谁为准 / 怎么自动检查 / 违反后果」见 [`docs/agent/invariants.md`](docs/agent/invariants.md)。

## 风险与可信度

- **AI 固有风险**：模型可能幻觉，也可能被提问里夹带的指令带偏。约束见上面的「答得可信」与「安全设计」——以代码为唯一依据、标注出处、证据不足转研发，信任边界只信 system prompt。
- **索引非实时**：刷新是分钟级，刚推的提交需等一个刷新周期才反映。

## 文档导航

> 全部文档的入口地图见 [`docs/README.md`](docs/README.md)（按受众分类）。下表是高频入口：

| 层 | 主题 | 链接 |
|----|------|------|
| **入门** | 部署 / 连飞书 / 运维 / 排错（从零到能用） | [`docs/runbook.md`](docs/runbook.md) |
| **架构** | 一次提问如何在系统里流转（AI 必读） | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| **架构** | 目录结构（双语） | [`docs/structure_zh.md`](docs/structure_zh.md) · [`docs/structure_en.md`](docs/structure_en.md) |
| **架构** | 术语表怎么来的：构建 / 产物 / 可信依据（面向人） | [`docs/glossary.md`](docs/glossary.md) |
| **规范** | AI 协作约定 | [`AGENTS.md`](AGENTS.md) |
| **规范** | 不变量与权威依据映射（含安全不变量逐条） | [`docs/agent/invariants.md`](docs/agent/invariants.md) |
| **规范** | 变更手册（改 X 怎么做 / 怎么验 / 怎么上线） | [`docs/agent/playbooks.md`](docs/agent/playbooks.md) |
| **设计权威依据** | 需求 / 架构设计原件（导入，仅中文） | [`docs/design/`](docs/design/README.md) |
| **调研** | CardKit 流式卡片 | [`docs/agent/cardkit-streaming-spike.md`](docs/agent/cardkit-streaming-spike.md) |
| **调研** | 索引性能基准 | [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md) |
| **调研** | 代码副本与共享存储方案选型 | [`docs/agent/efs-codegraph-sharing-spike.md`](docs/agent/efs-codegraph-sharing-spike.md) |
| **调研** | 性能对比（vs 原生 Claude Code） | [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) |

## 许可证

[MIT](LICENSE)。

---

<a id="english"></a>

# source-truth

[中文](#source-truth) | [English](#english)

> @-mention the bot in Feishu and ask, in plain business language, "how is this skill / number / rule actually computed?" Answers come from the project's **real code on the latest main branch**, with verifiable sources attached.

"How is this skill's cooldown computed?" "How does carry weight relate to strength?" — the answers live in the code and config tables, but designers can't read code and engineers keep getting interrupted. source-truth lets designers ask straight from Feishu: the AI reads the real code, locates the evidence, and answers in business language.

## Highlights

- **Trustworthy and verifiable**: real code is the only source of truth; every conclusion carries a `file:line` source (collapsed into a "for engineers to verify" panel — designers read the conclusion, engineers expand on demand). When code and docs conflict, code wins and the difference is flagged; when evidence is insufficient it says so and defers to engineers, never guessing or fabricating.
- **Stays fast on large codebases**: a resident CodeGraph index locates first, then reads precisely — no whole-repo scans. On a 16 GB, 75k-file project, a locate query stays at **1–5 ms**; a full round-trip Q&A is **2.7–5.1× faster** than native Claude Code.
- **Chinese questions hit English code**: a designer asks about "公会战" (guild war) settlement, but the code may call it by a legacy codename `LeagueWar`; "招募保底" (pity) hides under internal names like `pity_counter`. Searching in Chinese directly tends to match only comments, or turn up nothing at all. An offline glossary maps Chinese business terms to the English symbols that actually appear in the code, as an extra search hint — it only suggests "which English term to search"; the conclusion still comes from reading the code.
- **The answer is a living, interactive card**: just @-mention the bot in Feishu (no deploy, download, or account needed). The card shows live progress, streams the conclusion first as it's generated, can draw charts / tables, and collapses the sources into a panel (designers see the conclusion, engineers expand on demand); when done, tap a button or reply to the card to keep asking with context carried over — works on mobile too.

> Performance data sources and reproduction: [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) and [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md).

## How one real Q&A happens

Below is a real Q&A from a Feishu group (connected to a WoW-style C++ server codebase): a designer asks "how many slots does the default backpack have, and how is it expanded?", then follows up about the bank. The card times itself live, streams the conclusion, and auto-folds the sources:

![Screen recording of a real Q&A in a Feishu group: a designer @-mentions the bot asking about backpack slots; the card shows live analysis progress with a timer, streams the conclusion first, lists code sources in a collapsed "for engineers to verify" panel at the bottom, and offers a follow-up button](docs/assets/demo-qa.gif)

> The recording is 3× speed; the timer in the card title is the real elapsed time (first question 45s, follow-up 1m4s).

Step by step, in time order, from question to conclusion:

![End-to-end sequence of one Q&A: Feishu client, bot-gateway, AgentCore microVM, index-service, CardKit across five swimlanes, from @-mention to the streamed conclusion card](docs/assets/sequence-qa.en.svg)

| # | What happens | Why this step |
|---|--------------|---------------|
| 1 | You post `@bot how many slots does the default backpack have? how to expand?` in the group | Feishu pushes the message to the gateway over a persistent connection — no polling |
| 2 | The card instantly replies "analyzing…", with a live timer in the title | Shows the system is still working, so it doesn't look frozen |
| 3 | The agent uses CodeGraph to locate the backpack-slot code, querying the glossary in parallel for extra search hints | The glossary is a side aid: code names are mostly English, and Chinese "背包" may map to a different English symbol |
| 4 | It reads the real slot definitions and expansion logic out of the files | Locate first, then read — no whole-repo scan |
| 5 | The conclusion streams back, conclusion first then the basis (business language, no code dumps) | Conclusion-first, so non-technical readers can follow |
| 6 | The card expands a collapsible "for engineers to verify" panel listing `file:line` sources | Engineers can check directly; non-technical readers aren't drowned in code |
| 7 | Tap "follow up" or just reply to the card to keep asking **with the prior context** | Multi-turn reuses the same session, no lost context |

> Authoritative requirements and architecture: [`docs/design/`](docs/design/); AI collaboration conventions: [`AGENTS.md`](AGENTS.md); how a question flows through the system: [`docs/agent/architecture.md`](docs/agent/architecture.md).

## Scope

It is a **read-only code Q&A**: main branch only, answers only, changes nothing. Explicitly **not** doing:

- No game engine, no numeric simulation
- No writing back code, no commits, no file changes
- No reading design docs, no multi-branch / worktree, no cross-session shared memory
- No second engine (Codex), no full audit guardrails

These boundaries are both product positioning and a security guarantee. Planned capabilities: [`docs/agent/architecture.md`](docs/agent/architecture.md) and the design docs.

## At a glance

A question flows through three resident components: the **bot-gateway** (subscribed to Feishu events over a persistent connection), one **session-isolated microVM** per conversation, and **index-service**, which holds a read-only copy of your code. The client talks to the gateway, the gateway routes to a microVM, and the microVM reads code through index-service. Each session is invisible to the others inside its own microVM, yet all read against this project's read-only copy to check the code. A single query can search across multiple repos in one project, and one index-service host can serve several projects (each gets its own process and port, and every session still runs in its own microVM).

![source-truth architecture across three tiers: Feishu side → one EC2 (each project's bot-gateway and index-bridge co-located on the index-service host) → AgentCore session microVMs; events are pushed to the gateway over a persistent connection, the gateway invokes a session, and the session reaches the bridge over HTTP read-only (locate code / read files & config tables / glossary lookup)](docs/assets/architecture.en.svg)

> **Session microVMs don't mount any filesystem**: source and config tables are read through index-service's HTTP interface (`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files`); the code copy lives only on index-service's local disk (one copy per project, kept off the microVM entirely — there is never a second copy).

## Components (monorepo)

| Directory | Responsibility | Language |
|-----------|----------------|----------|
| [`agent-container/`](agent-container/) | Claude Code Agent running inside the session microVM: reasoning + orchestration + reading code | Python |
| [`bot-gateway/`](bot-gateway/) | Feishu bot persistent-connection event gateway + CardKit streaming-card rendering | TypeScript |
| [`index-service/`](index-service/) | Resident CodeGraph index service + MCP-over-HTTP interface (locate + read files) | Python |
| [`infra/`](infra/) | IaC: AgentCore Runtime / index service / gateway | boto3 + CDK (incremental) |
| [`config/`](config/) | Central config: i18n copy, alarm thresholds | JSON |
| [`scripts/`](scripts/) | Deploy / ops / test lifecycle | Bash |

Full directory tree: [`docs/structure_en.md`](docs/structure_en.md).

## AWS services used

Deployed in a single account, single region (Tokyo `ap-northeast-1` by default). The core is one shared ARM EC2 (resident index), one Bedrock AgentCore Runtime per project (session-isolated microVMs), Bedrock model inference, and S3 / ECR. Specs / counts / purposes of all 21 services: [`docs/aws-services_en.md`](docs/aws-services_en.md).

## Deploy and test

Interactive one-shot install (works on a fresh account / region, idempotent). On a machine with AWS credentials configured, bring it up with one line.

When the repo is public, a plain `curl` works:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)
```

When the repo is private, run `gh auth login` once locally, then fetch the bootstrap script via `gh` (authenticated, no public repo needed):

```bash
bash <(gh api repos/ddpie/source-truth/contents/scripts/get.sh --jq '.content' | base64 -d)
```

It clones the repo into `source-truth/` in the current directory (private repos clone via `gh` auth automatically), then enters the interactive install. If the `codegraph-server` index engine is missing, the deploy script downloads it automatically — no manual binary prep.

With the repo already cloned, just run the scripts; offline tests need no Docker / AWS:

```bash
./scripts/install.sh    # asks for region / repos / model / Feishu credentials, brings up backend + gateway
./scripts/test.sh       # offline suite: lint + unit + typecheck
```

Full deployment flow (prerequisites, `deploy-all.sh` staged options, connecting Feishu, ops, troubleshooting): [`docs/runbook.md`](docs/runbook.md). Feishu credentials go through Secrets Manager — never written to disk, never committed.

## How code enters the system and refreshes

Each repo is cloned to index-service locally and a file-watcher rebuilds the index incrementally. Two code sources:

- **git repos** (default): a systemd timer runs `git pull` periodically — freshness is minute-level, with no redeploy and no manual steps.
- **local repos** (when there's no git remote to push to): a snapshot pushed to the host via `scripts/push-local-repo.sh` over rsync, refreshed manually — re-run the upload command after the code changes.

The refresh mechanism and the measured "why an index is required" are in the "data plane" section of [`docs/agent/architecture.md`](docs/agent/architecture.md); local-repo upload and single-host bootstrap (`--local`) are in [`docs/runbook.md`](docs/runbook.md).

## Security design

Three classes of security, and not by prompt constraints alone — the code enforces them: **anti-privilege-escalation** (the agent doesn't even have write tools in context; the server registers only a read-only tool set), **anti-leak** (all fields sent into the group are de-identified, secrets / internal topology never enter the group; credentials go through Secrets Manager, never stored in the repo), **anti-injection** (any code / comment read via tools is treated as data to analyze, trusting only the system prompt baked into the image).

![Security design: anti-privilege-escalation, anti-leak, anti-injection — a code-enforced guard for each of three risks, three columns side by side](docs/assets/security-defense.en.svg)

Per-item "how it's enforced / source of truth / how it's auto-checked / consequence of violation": [`docs/agent/invariants.md`](docs/agent/invariants.md).

## Risks and trustworthiness

- **Inherent AI risk**: the model can hallucinate, and can be swayed by instructions smuggled into a question. The mitigations are in "Trustworthy and verifiable" and "Security design" above — code as the only basis, sources cited, defer to engineers when evidence is thin, and a trust boundary that trusts only the system prompt.
- **The index isn't real-time**: refresh is minute-level, so a just-pushed commit takes one refresh cycle to show up.

## Docs

> The full entry map of all docs is in [`docs/README.md`](docs/README.md) (organized by audience). The table below lists high-traffic entries:

| Layer | Topic | Link |
|-------|-------|------|
| **Getting started** | Deploy / connect Feishu / ops / troubleshooting (from zero to usable) | [`docs/runbook.md`](docs/runbook.md) |
| **Architecture** | How a question flows through the system (must-read for AI) | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| **Architecture** | Directory structure (bilingual) | [`docs/structure_en.md`](docs/structure_en.md) · [`docs/structure_zh.md`](docs/structure_zh.md) |
| **Architecture** | Where the glossary comes from: build / artifacts / trust basis (for humans) | [`docs/glossary.md`](docs/glossary.md) |
| **Conventions** | AI collaboration conventions | [`AGENTS.md`](AGENTS.md) |
| **Conventions** | Invariants and source-of-truth mapping (incl. each security invariant) | [`docs/agent/invariants.md`](docs/agent/invariants.md) |
| **Conventions** | Change playbooks (how to change X / verify / ship) | [`docs/agent/playbooks.md`](docs/agent/playbooks.md) |
| **Design authority** | Requirements / architecture originals (imported, Chinese only) | [`docs/design/`](docs/design/README.md) |
| **Research** | CardKit streaming card | [`docs/agent/cardkit-streaming-spike.md`](docs/agent/cardkit-streaming-spike.md) |
| **Research** | Indexing performance benchmark | [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md) |
| **Research** | Code-copy & shared-storage option selection | [`docs/agent/efs-codegraph-sharing-spike.md`](docs/agent/efs-codegraph-sharing-spike.md) |
| **Research** | Performance comparison (vs native Claude Code) | [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) |

## License

[MIT](LICENSE).
