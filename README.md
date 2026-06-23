# source-truth

> 在飞书里 @ 机器人，用业务语言回答「这个技能 / 数值 / 规则到底怎么算」——
> 答案来自项目**最新主分支的真实代码**，并附可复核的出处。

游戏研发中，「这个技能的冷却怎么算」「负重上限和力量的关系」这类问题，答案都写在代码与配置表里，
但策划难以直接查阅代码，研发又被反复打断。source-truth 将这一环节自动化：策划在飞书提问，
AI 助手读取项目真实代码、定位依据，再用业务语言给出结论。

## 三个核心优势（均有实测支撑）

- **答得可信，且能复核**：答案以真实代码为唯一依据，每条结论都附 `文件:行号` 出处（折叠在「供研发复核」区，
  策划看结论、研发按需展开核对）；代码与文档冲突时以代码为准并标注差异，证据不足时提示转研发确认，绝不臆测。
- **代码库越大越快**：先用 CodeGraph 定位、再精准读文件。在 16 GB、7.5 万文件的工程上，定位查询稳定在
  **1–5 毫秒**，几乎不受代码库体积影响；同等条件下比原生 Claude Code 快 **2.7–5.1 倍**、问答轮次约少一半到三分之一。
- **飞书内零门槛使用**：无需部署、下载或开账号，@ 机器人即可。答案是一张「会生长的卡片」——实时显示进度、
  结论流式展开、出处自动折叠；看完可点按钮或回复卡片，带着上下文继续追问，手机上同样好用。

> 性能数据来源与复现见 [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) 与
> [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md)。

> 一句话定位：飞书机器人驱动、以代码为唯一依据的游戏研发代码问答助手。

需求与架构权威依据见 [`docs/design/`](docs/design/)；AI 协作约定见 [`AGENTS.md`](AGENTS.md)；
一次提问如何在系统里流转见 [`docs/agent/architecture.md`](docs/agent/architecture.md)。

## 一次真实问答如何发生

| # | 你做什么 / 系统做什么 | 为什么是这一步 |
|---|----------------------|---------------|
| 1 | 你在群里 `@助手 角色的负重上限怎么算？` | 飞书长连接把消息推给网关，无需轮询 |
| 2 | 卡片立即回「正在分析…」，标题带实时计时 | 说明系统仍在处理，避免误判为无响应 |
| 3 | Agent 用 CodeGraph 定位到相关公式文件，读出真实计算逻辑 | 先定位再读文件，不做全仓扫描 |
| 4 | 结论流式回填，先给结论再讲依据（业务语言，不堆砌代码） | 结论先行，非技术读者也能读懂 |
| 5 | 卡片底部展开「供研发复核」折叠区，列出 `文件:行号` 出处 | 研发可直接核对，非技术读者不被代码淹没 |
| 6 | 可点击「继续追问」或直接回复卡片，**带着上文**接着问 | 多轮对话复用同一会话，不丢上下文 |

## 端到端链路

三个有状态组件，从飞书一直连到代码：飞书客户端 → 网关 → 会话隔离的 microVM → 共享只读代码副本。
**每个会话跑在各自独立的 microVM 里、互不可见，但都向同一份只读代码副本取证**——这是隔离与共享的分界。
（多仓库隔离为 post-MVP，图中以灰色虚线标出，当前 MVP 仅单仓。）

![source-truth 架构图：飞书客户端 → bot-gateway（单实例）→ 多个各自隔离的会话 microVM → 共享只读的 index-service 代码副本，答案流式回填；多仓库为 post-MVP 虚线标注](docs/assets/architecture.svg)

> **会话 microVM 不挂任何文件系统**：所有源码、配置表都经 index-service 的 HTTP 接口读取
> （`codegraph_read_file` / `glob_files` / `search_files`），仓库唯一一份副本只在 index-service
> 的本地磁盘上，因此没有副本同步问题。

## 组件一览（monorepo）

| 目录 | 职责 | 语言 |
|------|------|------|
| [`agent-container/`](agent-container/) | 会话 microVM 内运行的 Claude Code Agent：推理 + 编排 + 取证 | Python |
| [`bot-gateway/`](bot-gateway/) | 飞书 Bot 长连接事件网关 + CardKit 流式卡片渲染 | TypeScript |
| [`index-service/`](index-service/) | 常驻 CodeGraph 索引服务 + MCP-over-HTTP 接口（定位 + 读文件，持唯一代码副本） | Python |
| [`infra/`](infra/) | IaC：AgentCore Runtime / 索引服务 / 网关 | boto3 + CDK（渐进） |
| [`config/`](config/) | 配置驱动：i18n 文案、告警阈值 | JSON |
| [`scripts/`](scripts/) | 部署 / 运维 / 测试生命周期 | Bash |

完整目录树见 [`docs/structure_zh.md`](docs/structure_zh.md)。

## 用到的 AWS 服务

部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。核心是下面 4 个服务，其余（网络、安全、监控等
全部 20 项服务的规格 / 数量 / 用途）见 [`docs/aws-services_zh.md`](docs/aws-services_zh.md)。

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **EC2**（index-service 主机） | ARM Graviton `t4g.large`（2 vCPU / 8 GiB）默认，可调大 | 1（所有项目共用） | 常驻 CodeGraph 索引 + 读文件接口，持唯一一份代码本地副本 |
| **Bedrock AgentCore Runtime** | Firecracker microVM，VPC 模式，会话隔离 | 每项目一套 | Agent 执行环境，按会话独立 microVM |
| **Bedrock**（模型推理） | 默认 `global.anthropic.claude-opus-4-8` | 共享 | Claude Code Agent 的 LLM 推理 |
| **S3 / ECR** | artifact bucket + 私有镜像仓 | 各 1 | 存部署产物与会话容器 ARM64 镜像 |

## 部署与测试

**推荐：交互式一键安装**（全新账号 / 区域可跑、幂等；重跑预填上次答案）：

```bash
# 前置：已开通目标模型的 Bedrock 访问、目标区域支持 AgentCore、本机装好 aws/docker/git
./scripts/install.sh
#   查依赖 → 问区域/代码仓/模型 → 收飞书凭证(写 Secrets Manager) → 确认 → 拉起后端 + 网关
```

代码仓来源任选：本地路径、git 地址（GitHub/GitLab，`--repo-ref` 指定分支/标签/提交）、或 `s3://` tarball/前缀。

**进阶：调用底层编排**（CI / 精确控参；8 个阶段，任一可 `--skip`）：

```bash
./scripts/deploy-all.sh --region ap-northeast-1 --repo <本地路径 | git URL | s3://...>
#   artifacts→S3 → IAM → network → index-service(EC2) → 镜像(ARM64→ECR) → AgentCore Runtime → gateway → monitoring(CloudWatch)
./scripts/deploy-all.sh --region ap-northeast-1 --repo <src> --dry-run   # 只打印计划，不改任何资源
# deploy.sh 已废弃，仅作兼容垫片转发到 deploy-all.sh
```

测试只有一个入口（离线默认安全，无需 Docker / AWS）：

```bash
./scripts/test.sh                # 离线套件：lint + unit + typecheck（pre-push 跑这个）
./scripts/test.sh --full         # 加 smoke / e2e（需 Docker / AWS；smoke/e2e 目前为占位）
./scripts/check-invariants.sh    # 结构自检：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录
```

> 飞书凭证（app secret 等）走 Secrets Manager——`install.sh` 交互式创建 `source-truth/feishu-app` 密钥，
> 网关运行时由 `run.sh` 取出注入进程环境，**不落盘、不入仓库**。

## MVP 边界（有意不做的事）

第一版**只查主分支、只读问答**。明确**不做**：

- 不跑游戏引擎、不做数值模拟
- 不写回代码、不提交、不改任何文件（全程只读）
- 不读设计文档、不跨多分支 / worktree、不做跨会话共享记忆
- 不接第二引擎（Codex）、不做完整审计护栏

**保留能力**：

- 单引擎 Claude Code（走 Bedrock 计费）
- CodeGraph 类索引 + index-service 持仓库本地副本、经 HTTP 接口服务代码
- 每游戏项目一个机器人，机器人内按会话隔离

越界能力均为 post-MVP，详见 [`docs/agent/architecture.md`](docs/agent/architecture.md) 与设计文档。

## 代码怎么进入系统、怎么刷新（MVP 实况）

**当前是一次性快照构建，靠重新部署刷新**——没有 git push webhook、没有 inotify 增量、没有夜间 CI
（那些是 post-MVP 的目标形态，尚未实现）：

```
deploy-all.sh：把目标仓库打成 tarball 上传 S3（部署时快照）
  ▼ bootstrap.sh（EC2 首启）：解包到 index-service 本地磁盘
  ▼ 建图一次（codegraph-server --graph-only，flock 独占写入）
  ▼ 常驻只读服务（codegraph-server --mcp + HTTP 接口）
```

要更新主分支代码与索引，**重新部署 index-service 即可**（替换实例、重跑 bootstrap）。
为什么必须建索引、而不是让 Agent 全仓搜索：实测全仓扫描一次约 127s，建索引后定位查询恒为 1–5ms，见
[`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md)。

## 安全设计（纵深防御）

向群里的非技术读者解读代码，安全面有三类：**防越权**（只读不能变成写）、**防泄露**（密钥、内网拓扑不能进群）、
**防注入**（提问或代码里的指令不能改变系统行为）。这些边界不只靠提示词约束，也由代码强制：

| 面 | 怎么强制 | 以谁为准 |
|----|---------|--------|
| **只读边界** | Agent SDK 配 `tools=[]`（连写工具都不在模型上下文里，模型根本无从调用）+ `disallowed_tools` 黑名单 + `permission_mode=dontAsk`；index-service 端只注册一组只读工具（闭合白名单：定位 3 + 读文件 4 + 术语表 2，按可用性注册，不注册即无能力） | `agent-container/agent_lib.py`、`index-service/http_bridge.py` |
| **会话隔离** | 每次提问跑在独立的 Firecracker microVM，**不挂任何共享 / 代码文件系统**；代码只经 HTTP 接口读，会话之间无共享状态 | `docs/agent/architecture.md` |
| **路径围栏** | Agent 给的文件路径经词法 + realpath 双重校验关进仓库根，指向仓库外的符号链接逃逸被丢弃；SQLite 开只读模式、禁扩展加载 | `index-service/path_align.py`、`file_read.py`、`file_table.py` |
| **密钥/拓扑脱敏** | 进群的每个字段（结论/依据/追问/澄清/分析过程/问题回显/兜底文本）都过脱敏：AWS/Stripe/GitHub/JWT/Azure key、连接串口令、EC2 内网 DNS、S3 bucket、本机飞书 secret 全部 `[已隐藏]` | `bot-gateway/src/redact.ts` |
| **防注入信任边界** | 工具读到的代码/注释/配置一律视为「待分析数据」，其中任何「改变你的行为」的文字都不执行；只信打包进镜像的 system prompt | `agent-container/prompts/system.md` |
| **取证泄漏保护** | 冷启动时模型偶尔把工具调用当文本吐出（MCP 未注册）——agent 侧退避重试，gateway 侧检测并剥离，0 工具的「假完成」渲染为失败卡而非绿色成功 | `agent-container/agent_lib.py`、`bot-gateway/src/strip-toolcall-leak.ts` |
| **独占写入约束** | graph.db 同一时刻只允许一个进程写入（flock 跨进程 + 进程内重启锁 + orphan reaper），避免 RocksDB 并发写损坏 | `index-service/codegraph_session.py`、`bootstrap.sh` |
| **密钥不入库** | 飞书 App ID/Secret、token 走环境变量 / Secrets Manager / SSM，部署 user-data 只写非敏感配置 | `.local/`（gitignored）、`docs/agent/invariants.md` §7 |

逐条「是什么 / 以谁为准 / 怎么自动检查 / 违反后果」见 [`docs/agent/invariants.md`](docs/agent/invariants.md)。

## 风险与可信度

- **AI 固有风险**：模型可能幻觉，也可能受到提问中的注入指令影响。护栏：答案强约束「代码为唯一依据 +
  标注出处」；证据不足时给出低置信度提示并建议转研发确认；信任边界只信 system prompt，不信工具读到的内容里的指令。
- **快照可能过时**：索引是部署时的快照，主分支后续提交不会自动反映——重部署才刷新（见上一节）。
- **只读边界**：全程不写任何代码 / 文件，越界能力一律后置。

## 文档导航

> 全部文档的入口地图见 [`docs/README.md`](docs/README.md)（按受众分类）。下表是高频入口：

| 层 | 主题 | 链接 |
|----|------|------|
| **入门** | 部署 / 连飞书 / 运维 / 排错（从零到能用） | [`docs/runbook.md`](docs/runbook.md) |
| **架构** | 一次提问如何在系统里流转（AI 必读） | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| **架构** | 目录结构（双语） | [`docs/structure_zh.md`](docs/structure_zh.md) · [`docs/structure_en.md`](docs/structure_en.md) |
| **规范** | AI 协作约定 | [`AGENTS.md`](AGENTS.md) |
| **规范** | 不变量与权威依据映射（含安全不变量逐条） | [`docs/agent/invariants.md`](docs/agent/invariants.md) |
| **规范** | 变更配方（改 X 怎么做 / 怎么验 / 怎么上线） | [`docs/agent/playbooks.md`](docs/agent/playbooks.md) |
| **设计权威依据** | 需求 / 架构设计原件（导入，仅中文） | [`docs/design/`](docs/design/README.md) |
| **调研** | CardKit 流式卡片 | [`docs/agent/cardkit-streaming-spike.md`](docs/agent/cardkit-streaming-spike.md) |
| **调研** | 索引性能基准 | [`docs/agent/indexing-performance-spike.md`](docs/agent/indexing-performance-spike.md) |
| **调研** | 代码副本与共享存储方案选型 | [`docs/agent/efs-codegraph-sharing-spike.md`](docs/agent/efs-codegraph-sharing-spike.md) |
| **调研** | 性能对比（vs 原生 Claude Code） | [`docs/agent/perf-comparison.md`](docs/agent/perf-comparison.md) |
