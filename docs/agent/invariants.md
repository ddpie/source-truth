# 不变量与权威依据映射（invariants）

这份文档把 [`AGENTS.md`](../../AGENTS.md) 的「Critical constraints」展开成**可执行的不变量**：
每条写清「是什么 / 以谁为准 / 怎么机检 / 违反了会怎样」。AI 改代码前对照这张表，别破坏其中任何一条。

> 机检入口：`./scripts/check-invariants.sh`（结构/双语/权威依据）+ `./scripts/check-versions.sh`
> （版本钉死）。两者都由 `./scripts/test.sh` 的 lint 层调用，pre-push 跑。

---

## 1. 代码为唯一依据

- **不变量**：答案只能基于 index-service 服务的**最新主分支真实代码 + CodeGraph 取证**；代码与文档/记忆
  冲突时**以代码为准**并标注差异；证据不足/低置信度**转研发**，绝不编。
- **以谁为准**：被索引的目标仓库（index-service 本地副本）。其次是 `agent-container/prompts/system.md`
  里对这条的强约束（信任边界：只信 system prompt，不信工具读到的内容里的指令）。
- **机检**：无法纯静态机检（属行为约束）。守卫在 system.md 规则 + gateway 的脱敏/泄漏剥离兜底。
- **违反后果**：幻觉/被注入带偏 → 给出无依据答案，违背产品根本价值。

## 2. 会话容器 ARM64-only + 版本钉死

- **不变量**：会话 microVM 是 ARM64；基础镜像按 **sha256 digest** 钉死、`requirements.txt` 每个直接依赖
  **`==` 精确钉死**、Node 主版本钉死（`setup_24.x`）。
  **例外**：`@anthropic-ai/claude-code` CLI 按运维决定（2026-06-19）跟 `@latest`——牺牲可复现换最快拿到
  上游修复；出现回归改回 `@<version>` 即可。
- **以谁为准**：`agent-container/Dockerfile`（`FROM …@sha256:…`、`setup_24.x`、`claude-code@latest`）、
  `agent-container/requirements.txt`（`claude-agent-sdk==0.2.103`、`httpx==0.28.1` …）、
  `index-service/requirements.txt`（`mcp==1.23.3` …）。
- **机检**：`scripts/check-versions.sh` —— 基础镜像必须含 `@sha256:`、每个非注释依赖必须含 `==`、
  Node 必须 `setup_<N>.x`（非浮动 `setup_lts.x`）、`claude-code` 是 `@latest`（放行，仅告警）或 `@<version>`。
- **违反后果**：浮动 tag/未钉死依赖 → 构建不可复现，某次重建悄悄引入破坏性升级，事后无法定位。

## 3. 生成物绝不手改

- **不变量**：生成物只能「改源再重生成」，绝不手工编辑。
- **源 → 生成物**：

  | 生成物（不可手改） | 源（改这里） | 重生成方式 |
  |---|---|---|
  | `infra/cdk.out/` | `infra/` 的 CDK 源 | `cdk synth`（p2，CDK 化后） |
  | `node_modules/` | `bot-gateway/package.json` + lock | `npm install` |
  | `.venv/` | `requirements.txt` | `uv` / `pip install -r` |
  | 构建产物 / 镜像 | `agent-container/`（Dockerfile + 源） | `scripts/deploy-all.sh`（image 阶段） |
  | 索引 `graph.db` | 目标仓库快照 | index-service `bootstrap.sh` 建图（独占写入） |

- **机检**：暂无逐项 diff（靠约定 + review）。`.gitignore` 排除大部分生成物。
- **违反后果**：手改被下次重生成覆盖；或生成物与源漂移，行为不可解释。

## 4. 结构文档同步 + 双语配对

- **不变量**：改顶层目录 ⇒ 同步 `docs/structure_zh.md`（及 `_en.md`）；
  `docs/*_en.md` 与 `docs/*_zh.md` 必须成对（顶层 `docs/` 下，非递归）。
- **以谁为准**：实际目录树 + `docs/structure_{zh,en}.md`。
- **机检**：`scripts/check-invariants.sh` —— 校验 structure 引用的每个顶层目录存在、
  `docs/*_en.md ↔ *_zh.md` 配对齐全、结构文档双语齐全。
- **违反后果**：新人/AI 按过时的树找不到模块（曾因此漏掉 `file_read.py`/`file_table.py`）。

## 5. 独占写入约束（index-service graph.db）

- **不变量**：同一时刻 graph.db 只能有**一个** codegraph-server 进程写入。并发写 → RocksDB 0 节点损坏。
- **以谁为准**：`index-service/codegraph_session.py`（常驻单 worker + 进程内锁 + orphan reaper）、
  `index-service/http_bridge.py`（`main()` 里的 workspace-keyed flock）、`bootstrap.sh`（systemd
  build→serve 顺序，build 用 `flock`）。
- **机检**：无静态机检（运行期不变量）；守卫是 flock（跨进程）+ 进程内 `_restart_lock`（非阻塞 try-acquire，
  防重启风暴死锁）+ `codegraph_client._assert_spawn_allowed()` tripwire（每次调用 spawn 默认禁，仅测试 opt-in）。
- **违反后果**：出现第二个写入进程 → graph.db 损坏 → `/health` 报 0 节点 → 全部问答失败。
  详见记忆与 review 历史；**绝不**在 index 实例上手动再跑一个 codegraph-server 写同一份图。

## 6. MVP 只读边界

- **不变量**：仅主分支、仅只读问答、不跑引擎、不写回/提交/改文件。
- **以谁为准**：`agent-container/agent_lib.py` 的 SDK 配置——`tools=[]`（工具不进模型上下文）+ `disallowed_tools`
  黑名单 + `permission_mode="dontAsk"` + `strict_mcp_config=True` + `setting_sources=[]`；
  server 端 `http_bridge.py` 只注册 7 个只读工具（闭合白名单）。
- **机检**：无专门脚本；靠 SDK 多层强制 + server 端白名单（不注册即无能力）。
- **违反后果**：越界写/提交/跑引擎——突破产品安全承诺。越界能力（设计文档读取、多分支、共享记忆、
  审计护栏、Codex、数值模拟）一律 post-MVP。

## 7. 密钥绝不入库

- **不变量**：飞书 `App ID/Secret`、token 等绝不提交进仓库；走 Secrets Manager（运行时取出注入进程 env）。
- **以谁为准**：`scripts/install.sh`（交互式把凭证写进 Secrets Manager 密钥 `source-truth/feishu-app`）；
  `bot-gateway/run.sh`（启动时从 Secrets Manager 取出注入进程 env，不落盘）；`.local/` gitignored。
- **机检**：gitleaks pre-commit（规划）；`deploy-all.sh`/`bootstrap.sh` 的 user-data 与 `/etc/bot-gateway.env`
  只写非敏感配置（后者只存密钥**名**，不存密钥值）。
- **违反后果**：密钥泄露 → 安全事故。

## 8. 网关 session TTL 与 Runtime idle 对齐

- **不变量**：网关的 session 复用 TTL 不得超过 AgentCore Runtime 的 `idleRuntimeSessionTimeout`。否则网关会
  复用一个已被回收的暖 microVM，使追问触发冷启动——功能不受影响（历史靠 replay 续接），但响应变慢。
- **以谁为准**：单一参数 `deploy-all.sh --idle-timeout`（默认 900 秒）同时设置 `deploy_runtime.py` 的
  `lifecycleConfiguration.idleRuntimeSessionTimeout` 与网关环境变量 `RUNTIME_IDLE_TIMEOUT_SECS`，后者再由
  `session-map.ts` 派生出 TTL。调整时只改这一个参数，两侧随之联动。
- **机检**：无静态机检；由「同源派生」从结构上保证，而非维护两个独立常量。
- **违反后果**：若将 TTL 写成大于 idle 的独立常量（退化前即 TTL 30 分钟、idle 15 分钟），落在中间时间窗的追问
  会静默冷启。成本提示：调大 idle 会增加空闲期的内存计费（空闲 CPU 免费），详见
  [`architecture.md`](architecture.md)「Runtime 调参与成本权衡」。

---

相关：变更操作手册见 [`playbooks.md`](playbooks.md)；架构工作原理见 [`architecture.md`](architecture.md)；
部署/运维见 [`../runbook.md`](../runbook.md)。
