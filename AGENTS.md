# AGENTS.md

Guidance for AI coding agents working in this repo. This file is the single source
of truth for agent conventions; it links out rather than duplicating. Human onboarding
docs live in `docs/` (中文为主，结构文档双语 `_en`/`_zh`)。

## Project overview

source-truth 是「代码为唯一依据」的飞书游戏研发代码问答助手。端到端：策划在飞书 @机器人 →
**bot-gateway**（TypeScript 长驻网关，长连接事件订阅，按会话路由）→ **AgentCore Runtime**
（Firecracker microVM，会话隔离）→ microVM 内的 **agent-container**（Python，Claude Code Agent SDK，
`CLAUDE_CODE_USE_BEDROCK=1`）→ 通过 **index-service**（常驻 CodeGraph，MCP-over-HTTP）定位代码 +
只读挂载 **EFS** `/mnt/repo` 读最新主分支源码与配置表 → **CardKit 流式卡片**回传。

核心架构特征：AI 引擎在 microVM **内**自主运行（不是容器外的远程 MCP 客户端），并新增飞书 Bot 网关、
独立 CodeGraph 索引服务、EFS 共享代码仓三个有状态组件。架构心智模型见 `docs/agent/architecture.md`。

语言：Python（`agent-container/`）、TypeScript / Node 20（`bot-gateway/`、未来 `infra/` CDK）、
Bash（`scripts/`）。会话容器 ARM64-only。

## Setup & commands

当前已实现（init 骨架阶段）：

```bash
./scripts/check-invariants.sh   # 结构自检：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录

# 各组件依赖见其 README（agent-container: uv；bot-gateway: npm）。
./scripts/test.sh           # 已实现。离线默认：lint + unit + typecheck（pre-push 跑这个）
./scripts/test.sh --full    # 已实现。加 smoke / e2e（需 Docker / AWS；smoke/e2e 目前为占位）
# 一键部署（已实现、全新账号/区域可跑、幂等）：artifacts→IAM→network→EFS→index-service→镜像→Runtime
./scripts/deploy-all.sh --region <r> --repo <path>   # 加 --dry-run 仅打印计划；deploy.sh 已废弃→转发垫片
```

规划中的命令（**尚未实现**，阶段标注见 `scripts/README.md`；不要当作已存在去调用）：

```bash
./scripts/ops.sh status     # (p2) 运维：三组件健康 + 索引新鲜度
```

MVP 阶段 Runtime 用 `agentcore` starter toolkit / boto3 配，不强求 CDK——见
`docs/agent/architecture.md` 的 provisioning 分工。

## Project structure

完整目录树见 `docs/structure_zh.md`（权威，改顶层目录必须同步）。顶层：`agent-container/`（Python
Agent）、`bot-gateway/`（TS 网关 + CardKit）、`index-service/`（CodeGraph 索引 + MCP 桥）、
`infra/`（IaC）、`shared/`（共享日志 / 契约）、`config/`（i18n / 阈值）、`scripts/`（运维）、
`docs/`（人面向）+ `docs/agent/`（AI 面向）+ `docs/design/`（导入的设计真相源）。

**生成物 / 不可手改：** `infra/cdk.out/`、`node_modules/`、`.venv/`、构建产物。源 → 生成物映射表见
`docs/agent/invariants.md`（随 p1 补全）。

## Code style

- TypeScript（`bot-gateway/`、`infra/`）：ESLint 即格式化器，不另配 Prettier；strict 模式；未用参数前缀 `_`。
- Python（`agent-container/`、可能的 `index-service/`）：遵循 `ruff` / `black` 默认；类型标注。
- 结构化 JSON 日志（`console.log(JSON.stringify({...}))` / 等价），用户标识用 `hashUserId` 脱敏，
  见 `shared/`。
- 工具 / MCP 命名清晰、动宾式。

## Testing

`./scripts/test.sh`（**已实现**）是单一入口。离线默认安全（lint + unit + typecheck）；`--full` 才跑
需要 Docker / AWS 的 smoke / e2e（smoke/e2e 目前为占位）。pre-push 跑离线套件。结构自检
`./scripts/check-invariants.sh` 由 lint 层调用。

## Critical constraints（细节随 p1 落到 docs/agent/invariants.md）

- **代码为唯一依据**：答案必须基于 EFS 上最新主分支真实代码 + CodeGraph 取证；代码与文档 / 记忆
  冲突时以代码为准，并标注差异与文档时间；低置信度转研发。
- **会话容器 ARM64-only**；基础镜像、Claude Agent SDK、`@anthropic-ai/claude-code` CLI（agent
  microVM 内 SDK spawn 的子进程）版本钉死（pin），漂移由 `scripts/check-versions.sh`（已实现，
  `test.sh --lint` 调用）守卫。（注：lark-cli 仅是开发期手测工具，不装进任何运行镜像，也不在该守卫范围内。）
- **生成物绝不手改**——改源再重生成。
- **改顶层目录 ⇒ 同步 `docs/structure_zh.md`（及 `_en.md`）**；**新增 `docs/*_en.md` ⇒ 补 `_zh.md`**（反之亦然）。
- **MVP 边界**：仅主分支、仅只读问答、不跑引擎、不写回 / 提交。越界能力（设计文档读取、多分支、
  共享记忆、审计护栏、Codex、数值模拟）一律后置。

`scripts/check-invariants.sh`（已实现；将在 p1 接入 pre-commit）强制其中可机检的子集。

## Boundaries

**Never:**
- 提交密钥 / token（gitleaks pre-commit；密钥走 Secrets Manager / SSM，**当前需手工在 CDK 外创建**——
  编排脚本尚未自动建密钥，bot-gateway 启动需 `FEISHU_APP_ID/SECRET` 环境变量）。
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

- 架构心智模型：`docs/agent/architecture.md`
- CardKit「会生长的答案卡」调研（`bot-gateway` 核心能力）：`docs/agent/cardkit-streaming-spike.md`
- 不变量与真相源映射：`docs/agent/invariants.md`（p1）
- 变更配方：`docs/agent/playbooks.md`（p1）
- 目录结构：`docs/structure_zh.md` · `docs/structure_en.md`
- 需求 / 架构设计真相源：`docs/design/requirements_zh.md` · `docs/design/architecture-overview_zh.md`
