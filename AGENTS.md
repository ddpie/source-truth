# AGENTS.md

Guidance for AI coding agents working in this repo. This file is the single source
of truth for agent conventions; it links out rather than duplicating. Human onboarding
docs live in `docs/` (中文为主，结构文档双语 `_en`/`_zh`)。

## Project overview

source-truth 是「代码为唯一依据」的飞书游戏研发代码问答助手。完整链路：策划在飞书 @机器人 →
**bot-gateway**（TypeScript 长驻网关，长连接事件订阅，按会话路由）→ **AgentCore Runtime**
（Firecracker microVM，会话隔离）→ microVM 内的 **agent-container**（Python，Claude Code Agent SDK，
`CLAUDE_CODE_USE_BEDROCK=1`）→ 通过 **index-service**（常驻 CodeGraph，MCP-over-HTTP）定位代码，并用
文件工具（`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files`）读取最新主分支源码与配置表
（仓库副本只在 index-service 本地磁盘，会话 microVM 不挂任何文件系统）→ **CardKit 流式卡片**回传。

核心架构特征：AI 引擎在 microVM **内**自主运行（不是容器外的远程 MCP 客户端），并新增飞书 Bot 网关与
独立 CodeGraph 索引服务两个有状态组件——后者持有唯一一份代码仓本地副本，定位代码和读文件也全部走
HTTP 接口（不挂任何共享文件系统）。架构工作原理见 `docs/agent/architecture.md`。

语言：Python（`agent-container/`）、TypeScript / Node 20（`bot-gateway/`、未来 `infra/` CDK）、
Bash（`scripts/`）。会话容器 ARM64-only。

## Setup & commands

当前已实现（init 骨架阶段）：

```bash
./scripts/check-invariants.sh   # 结构自检：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录

# 各组件依赖见其 README（agent-container: uv；bot-gateway: npm）。
./scripts/test.sh           # 已实现。离线默认：lint + unit + typecheck（pre-push 跑这个）
./scripts/test.sh --full    # 已实现。加 e2e（对已部署 Runtime 跑真实问答，缺部署自动 skip）+ smoke（仍占位）
# 一键部署（已实现、全新账号/区域可跑、幂等）：artifacts→IAM→network→index-service→镜像→Runtime→gateway
# 仓库不再走命令行，改由 .local/projects.json 配置（推荐 install.sh 交互式添加项目）
./scripts/deploy-all.sh --region <r>   # 加 --dry-run 仅打印计划；deploy.sh 已废弃→转发垫片
```

规划中的命令（**尚未实现**，阶段标注见 `scripts/README.md`；不要当作已存在去调用）：

```bash
./scripts/ops.sh status     # (p2) 运维：三组件健康 + 索引时效
```

MVP 阶段 Runtime 用 `agentcore` starter toolkit / boto3 配，不强求 CDK——见
`docs/agent/architecture.md` 的 provisioning 分工。

## Project structure

完整目录树见 `docs/structure_zh.md`（权威，改顶层目录必须同步）。顶层：`agent-container/`（Python
Agent）、`bot-gateway/`（TS 网关 + CardKit）、`index-service/`（CodeGraph 索引 + MCP 接口）、
`infra/`（IaC）、`config/`（i18n / 阈值）、`scripts/`（运维）、
`docs/`（面向人）+ `docs/agent/`（面向 AI）+ `docs/design/`（导入的设计权威依据）。

**生成物 / 不可手改：** `infra/cdk.out/`、`node_modules/`、`.venv/`、构建产物。源 → 生成物映射表见
`docs/agent/invariants.md`。

## Code style

- TypeScript（`bot-gateway/`、`infra/`）：ESLint 即格式化器，不另配 Prettier；strict 模式；未用参数前缀 `_`。
- Python（`agent-container/`、可能的 `index-service/`）：遵循 `ruff` / `black` 默认；类型标注。
- 结构化 JSON 日志（`console.log(JSON.stringify({...}))` / 等价），用户标识用 `hashUserId` 脱敏，
  实现见 `bot-gateway/src/log.ts`。
- 工具 / MCP 命名清晰、动宾式。

## Testing

`./scripts/test.sh`（**已实现**）是单一入口。离线默认安全（lint + unit + typecheck）；`--full` 才跑
需要 AWS 的 e2e（`scripts/e2e-probe.py`：对已部署 Runtime 跑真实问答，缺部署自动 skip）与 smoke（仍占位）。
pre-push 跑离线套件。结构自检 `./scripts/check-invariants.sh` 由 lint 层调用。

## Critical constraints（详见 docs/agent/invariants.md）

- **代码为唯一依据**：答案必须基于 index-service 服务的最新主分支真实代码 + CodeGraph 取证；代码与文档 / 记忆
  冲突时以代码为准，并标注差异与文档时间；低置信度转研发。
- **会话容器 ARM64-only**；基础镜像、Claude Agent SDK 版本固定（pin），漂移由
  `scripts/check-versions.sh`（已实现，`test.sh --lint` 调用）守卫。**例外：`@anthropic-ai/claude-code`
  CLI（agent microVM 内 SDK spawn 的子进程）按运维决定（2026-06-19）改用 `@latest` 跟最新**——以可复现性换取
  更快获得上游修复；守卫对 `@latest` 放行（仅告警），出现回归时改回 `@<version>` 即可。（注：lark-cli 仅是
  开发期手测工具，不装进任何运行镜像，也不在该守卫范围内。）
- **生成物绝不手改**——改源再重生成。
- **改顶层目录 ⇒ 同步 `docs/structure_zh.md`（及 `_en.md`）**；**新增 `docs/*_en.md` ⇒ 补 `_zh.md`**（反之亦然）。
- **MVP 边界**：仅主分支、仅只读问答、不跑引擎、不写回 / 提交。越界能力（设计文档读取、多分支、
  共享记忆、审计护栏、Codex、数值模拟）一律后置。
- **「不跑引擎」的一处明确例外——构建期引擎（术语表生成，2026-06-22）**：「不跑引擎」约束的是**按用户提问
  实时回答的引擎**（处理用户输入、需会话隔离，必须在 microVM 内）。**术语表生成**是另一类：在 **index 主机**
  上用本地 `claude` (cc) CLI 离线扫自己已持有的代码副本、产出「中文词→英文符号」对照表（`/data/glossary/<项目>/`），
  **无用户输入、无会话、不在请求路径上**。这是有意纳入的构建期引擎，受三重约束：
  - ① cc 被锁定：`--disallowed-tools` 去掉 Bash/Write/WebFetch/Task 等、`--setting-sources ""` 不加载 repo 的 `.claude`（见 `glossary_build.run_cc`）；
  - ② 产物仅供只读服务，写盘在 index 主机本地，代码不出机器；
  - ③ cc 臆造的中文别名会被 `extract_entries` 的 grounding 校验拦下丢弃（要求中文必须真实出现在源文件里）。

  扫描**不限文件类型**（代码 + 文档/README/设计案等任意文本，只排除二进制/资源），因为中文术语常在文档里；
  但**文档与代码冲突时以代码为准**——文档来源的条目置信度降一档（`glossary.is_code_source` / `demote_confidence`），
  同概念下代码来源恒高于文档来源，文档术语因此落到按需 `glossary_lookup` 层而非显眼的 index，且结论仍须实读代码取证。
  问答引擎仍只在 microVM 内。需 index 主机 `bedrock-invoke` IAM 权限。

`scripts/check-invariants.sh`（已实现；将在 p1 接入 pre-commit）强制其中可自动检查的子集。

## Boundaries

**Never:**
- 提交密钥 / token（gitleaks pre-commit；飞书凭证走 Secrets Manager——`install.sh` 交互式创建
  `source-truth/feishu-app` 密钥，bot-gateway 的 `run.sh` 启动时取出注入进程环境，不落盘、不入仓库）。
- 手改生成物。
- 让 MVP 越过只读边界（写回代码、跑引擎、提交）。

**Ask first:**
- 增删 OAuth scope 或改机器人身份行为。
- 破坏性基础设施变更（删资源、`teardown.sh`）。
- bump Claude Agent SDK / lark-cli / 基础镜像版本。
- 把任何 post-MVP 能力提前纳入。

## Commit / PR

- Conventional Commits 前缀（`feat:`、`fix:`、`docs:`、`chore(deps):`）。
- 分支命名 `<type>/<short-kebab-summary>`，与 commit 前缀一致。
- **不要**加 `Co-Authored-By` 或任何 AI 署名 trailer。
- pre-push 跑 `./scripts/test.sh`，通过再推。

## Key resources

- 架构工作原理：`docs/agent/architecture.md`
- 术语表（把中文提问映射到英文代码符号）：`docs/agent/glossary.md`
- CardKit 流式答案卡调研（`bot-gateway` 核心能力）：`docs/agent/cardkit-streaming-spike.md`
- 不变量与权威依据映射：`docs/agent/invariants.md`
- 变更手册：`docs/agent/playbooks.md`
- 部署 / 连飞书 / 运维 / 排错：`docs/runbook.md`
- 目录结构：`docs/structure_zh.md` · `docs/structure_en.md`
- 需求 / 架构设计权威依据：`docs/design/requirements_zh.md` · `docs/design/architecture-overview_zh.md`
