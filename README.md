# source-truth

> 在飞书里 @ 机器人，用业务语言回答「这个技能 / 数值 / 规则到底怎么算」。
> 答案来自项目**最新主分支的真实代码**，并附可复核的出处。

游戏研发中，「这个技能的冷却怎么算」「负重上限和力量的关系」这类问题，答案都写在代码与配置表里，
但策划难以直接查阅代码，研发又被反复打断。source-truth 把这件事自动化：策划在飞书提问，
AI 助手读取项目真实代码、定位依据，再用业务语言给出结论。

## 系统全貌

从飞书到代码，中间是三个常驻组件：飞书客户端 → 网关 → 会话隔离的 microVM → 共享只读代码副本。
每个会话跑在各自独立的 microVM 里、互不可见，但都向同一份只读代码副本取证：隔离与共享的边界即在于此。
同一项目下的多仓库联合检索已支持，采用同机逻辑隔离（各项目独立进程与端口、各自只读自己的仓库）；
操作系统级隔离尚未实现，故互不信任的项目仍须分机器部署。

![source-truth 架构图：飞书客户端 → bot-gateway（单实例）→ 多个各自隔离的会话 microVM → 共享只读的 index-service 代码副本（持索引与术语表），答案流式回填；同一项目下多仓库联合检索已支持](docs/assets/architecture.svg)

> **会话 microVM 不挂任何文件系统**：所有源码、配置表都经 index-service 的 HTTP 接口读取
> （`codegraph_read_file` / `glob_files` / `search_files`），仓库唯一一份副本只在 index-service
> 的本地磁盘上，因此没有副本同步问题。

## 四个核心优势（均有实测支撑）

- **答得可信，且能复核**：答案以真实代码为唯一依据，每条结论都附 `文件:行号` 出处（折叠在「供研发复核」区，
  策划看结论、研发按需展开核对）；代码与文档冲突时以代码为准并标注差异，证据不足时提示转研发确认，绝不臆测。
- **代码库越大越显优势，得益于常驻索引**：常驻的 CodeGraph 索引先定位、再精准读取文件，不做全仓扫描。
  在 16 GB、7.5 万文件的工程上，定位查询稳定在 **1–5 毫秒**，几乎不随代码库体积变化（同等规模全仓扫描需上百秒）；
  整轮问答相比原生 Claude Code 快 **2.7–5.1 倍**，问答轮次减少约三分之一到一半。
- **中文提问也能命中英文代码（术语表）**：策划问「公会战怎么结算」「招募保底多少抽」，而代码里的命名未必是常规翻译。
  公会战可能写成历史代号 `LeagueWar`，保底则藏在 `pity_counter` 这类内部叫法里，直接用中文搜往往只命中注释、甚至零命中。
  术语表离线把中文业务词映射到代码里真实出现的英文符号（专门覆盖模型难以推断的项目专属命名：内部缩写、模块前缀、历史叫法），
  作为额外的检索线索；它只负责「该搜哪个英文词」，结论仍以实际查看代码为准。
- **在飞书里直接使用，没有门槛**：无需部署、下载或开账号，@ 机器人即可。答案是一张「会生长的卡片」：实时显示进度、
  结论流式展开、出处自动折叠；看完可点按钮或回复卡片，带着上下文继续追问，在手机上同样可用。

> 性能数据来源与复现见 [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) 与
> [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md)。

## 一次真实问答如何发生

下面按时间顺序，看一次问答从提问到出结论的完整过程：

| # | 你做什么 / 系统做什么 | 为什么是这一步 |
|---|----------------------|---------------|
| 1 | 你在群里 `@助手 角色的负重上限怎么算？` | 飞书长连接把消息推给网关，无需轮询 |
| 2 | 卡片立即回「正在分析…」，标题带实时计时 | 说明系统仍在处理，避免误判为无响应 |
| 3 | Agent 先对照术语表，把中文「负重」对应到代码里的英文符号 | 代码命名多为英文，直接拿中文搜常命中不到 |
| 4 | 据此用 CodeGraph 定位到相关公式文件，读出真实计算逻辑 | 先定位再读文件，不做全仓扫描 |
| 5 | 结论流式回填，先给结论再讲依据（业务语言，不堆砌代码） | 结论先行，非技术读者也能读懂 |
| 6 | 卡片底部展开「供研发复核」折叠区，列出 `文件:行号` 出处 | 研发可直接核对，非技术读者不被代码淹没 |
| 7 | 可点击「继续追问」或直接回复卡片，**带着上文**接着问 | 多轮对话复用同一会话，不丢上下文 |

> 需求与架构权威依据见 [`docs/design/`](docs/design/)；AI 协作约定见 [`AGENTS.md`](AGENTS.md)；
> 一次提问如何在系统里流转见 [`docs/agent/architecture.md`](docs/agent/architecture.md)。

## 组件一览（monorepo）

| 目录 | 职责 | 语言 |
|------|------|------|
| [`agent-container/`](agent-container/) | 会话 microVM 内运行的 Claude Code Agent：推理 + 编排 + 取证 | Python |
| [`bot-gateway/`](bot-gateway/) | 飞书 Bot 长连接事件网关 + CardKit 流式卡片渲染 | TypeScript |
| [`index-service/`](index-service/) | 常驻 CodeGraph 索引服务 + MCP-over-HTTP 接口（定位 + 读文件，持唯一代码副本） | Python |
| [`infra/`](infra/) | IaC：AgentCore Runtime / 索引服务 / 网关 | boto3 + CDK（渐进） |
| [`config/`](config/) | 集中配置：i18n 文案、告警阈值 | JSON |
| [`scripts/`](scripts/) | 部署 / 运维 / 测试生命周期 | Bash |

完整目录树见 [`docs/structure_zh.md`](docs/structure_zh.md)。

## 用到的 AWS 服务

部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。核心是一台共用的 ARM EC2（常驻索引）、
每项目一套 Bedrock AgentCore Runtime（会话隔离的 microVM）、Bedrock 模型推理、S3 / ECR。
全部 20 项服务的规格 / 数量 / 用途见 [`docs/aws-services_zh.md`](docs/aws-services_zh.md)。

## 部署与测试

交互式一键安装（全新账号 / 区域可跑、幂等），离线测试无需 Docker / AWS：

```bash
./scripts/install.sh    # 问区域 / 代码仓 / 模型 / 飞书凭证，拉起后端 + 网关
./scripts/test.sh       # 离线套件：lint + unit + typecheck
```

完整部署流程（前置条件、`deploy-all.sh` 分阶段控参、连飞书、运维、排错）见
[`docs/runbook.md`](docs/runbook.md)。飞书凭证走 Secrets Manager，不落盘、不入仓库。

## 能力边界（有意不做的事）

定位是**只读的代码问答**：只查主分支、只回答，不改动任何东西。明确**不做**：

- 不跑游戏引擎、不做数值模拟
- 不写回代码、不提交、不改任何文件（全程只读）
- 不读设计文档、不跨多分支 / worktree、不做跨会话共享记忆
- 不接第二引擎（Codex）、不做完整的审计防线

这些边界既是产品定位，也是安全保证（只读不会变成写、代码不出机器）。规划中的能力见
[`docs/agent/architecture.md`](docs/agent/architecture.md) 与设计文档。

## 代码怎么进入系统、怎么刷新

git 为唯一来源：每个仓库 `git clone` 到 index-service 本地，按项目的 systemd timer（默认 300 秒）
定时 `git pull`，常驻 codegraph 的 file-watcher 在数秒内增量重建内存图，新鲜度分钟级、无需重部署。
更新主分支代码无需手动操作。为什么必须建索引而非让 Agent 全仓搜索：实测全仓扫描一次约 127 秒，
建索引后定位查询恒为 1–5 毫秒。流程细节见
[`docs/agent/architecture.md`](docs/agent/architecture.md)。

## 安全设计（纵深防御）

安全面有三类，且不只靠提示词约束、代码本身会强制执行：**防越权**（Agent 连写工具都不在上下文里，
服务端只注册一组只读工具）、**防泄露**（进群字段全过脱敏，密钥 / 内网拓扑不进群；凭证走 Secrets Manager 不入库）、
**防注入**（工具读到的代码 / 注释一律当待分析数据，只信打包进镜像的 system prompt）。
逐条「怎么强制 / 以谁为准 / 怎么自动检查 / 违反后果」见 [`docs/agent/invariants.md`](docs/agent/invariants.md)。

## 风险与可信度

- **AI 固有风险**：模型可能幻觉，也可能被提问里夹带的指令带偏。为此做了几道约束：答案强制「以代码为唯一依据 +
  标注出处」；证据不足时给出低置信度提示并建议转研发确认；信任边界只信 system prompt，不信工具读到的内容里的指令。
- **索引新鲜度分钟级**：定时 `git pull` + watcher 增量重建跟上主分支，但非实时——刚推的提交需等一个刷新周期（默认 300 秒）才反映。
- **只读边界**：全程不写任何代码 / 文件，写类能力一律不开放。

## 文档导航

> 全部文档的入口地图见 [`docs/README.md`](docs/README.md)（按受众分类）。下表是高频入口：

| 层 | 主题 | 链接 |
|----|------|------|
| **入门** | 部署 / 连飞书 / 运维 / 排错（从零到能用） | [`docs/runbook.md`](docs/runbook.md) |
| **架构** | 一次提问如何在系统里流转（AI 必读） | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| **架构** | 目录结构（双语） | [`docs/structure_zh.md`](docs/structure_zh.md) · [`docs/structure_en.md`](docs/structure_en.md) |
| **架构** | 术语表（让中文提问命中英文代码符号） | [`docs/agent/glossary.md`](docs/agent/glossary.md) |
| **规范** | AI 协作约定 | [`AGENTS.md`](AGENTS.md) |
| **规范** | 不变量与权威依据映射（含安全不变量逐条） | [`docs/agent/invariants.md`](docs/agent/invariants.md) |
| **规范** | 变更配方（改 X 怎么做 / 怎么验 / 怎么上线） | [`docs/agent/playbooks.md`](docs/agent/playbooks.md) |
| **设计权威依据** | 需求 / 架构设计原件（导入，仅中文） | [`docs/design/`](docs/design/README.md) |
| **调研** | CardKit 流式卡片 | [`docs/agent/cardkit-streaming-spike.md`](docs/agent/cardkit-streaming-spike.md) |
| **调研** | 索引性能基准 | [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md) |
| **调研** | 代码副本与共享存储方案选型 | [`docs/agent/efs-codegraph-sharing-spike.md`](docs/agent/efs-codegraph-sharing-spike.md) |
| **调研** | 性能对比（vs 原生 Claude Code） | [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) |
