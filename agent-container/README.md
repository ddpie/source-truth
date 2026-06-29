# agent-container

会话 microVM 内运行的 **Claude Code Agent**（Python）——source-truth 的推理与编排核心。

## 职责

在 AgentCore Runtime 的 Firecracker microVM 内，用 **Claude Code Agent SDK**（`claude_agent_sdk`）+
**bedrock-agentcore** runtime（`@app.entrypoint` 异步流式 handler）执行 agent 循环：理解策划的问题 →
调远程 CodeGraph MCP 定位代码 → 经 index-service 的文件工具读最新主分支源码与配置表（含 Excel/CSV/SQLite 数值表）→
生成结构化答案并流式 `yield`。

模型走 Bedrock 计费（`CLAUDE_CODE_USE_BEDROCK=1`）。MVP 单引擎 Claude Code（Codex 第二引擎后置）。

## 对外契约

| 项 | 约定 |
|----|------|
| 入参 payload | `{ "prompt": <问题文本>, "session": <会话上下文> }`（由 bot-gateway 注入） |
| CodeGraph + 文件读取 | 远程 MCP-over-HTTP 端点（由 index-service 暴露），通过 env / option 注入；定位与读文件（`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files` / `codegraph_read_table`）都走此接口 |
| 代码与配置 | 经 index-service 文件工具读取（**仓库副本只在 index-service 本地磁盘**；microVM 不挂文件系统）；路径为仓库相对（如 `Assets/Scripts/Foo.cs`） |
| 临时文件 | Session Storage 可写挂载在 `/mnt/workspace`（每会话隔离） |
| 出参 | 流式 `yield` AssistantMessage / ResultMessage，由网关渲染回 CardKit |

## 取证原则（代码为唯一依据）

- 答案必须基于 index-service 提供的真实代码，并经 CodeGraph 取证；
- 代码与文档 / 记忆冲突时**以代码为准**，并标注差异与文档时间；
- 低置信度时在答案中标注并建议转研发确认。

## 约束

- **ARM64-only** 容器；基础镜像与 Claude Agent SDK 版本固定（pin，`claude-agent-sdk==0.2.103`）。
  （lark-cli 仅是开发期手测工具，不装进任何运行镜像，不在该 pin 范围内。）
- **只读边界**：MVP 仅问答，不跑引擎、不写回、不提交。agent 内建 `Read`/`Glob`/`Grep` 全部禁用
  （`tools=[]`，不设 `cwd`），读文件只能经 index-service 的 `codegraph_*` 工具。强制手段不止 `tools=[]`：还有
  `disallowed_tools` 黑名单 + `permission_mode="dontAsk"` + `strict_mcp_config=True` + `setting_sources=[]`。
- **模型 ID 按区域**：东京 ap-northeast-1 **不认 `us.anthropic.*`**（US cross-region），当前默认
  `global.anthropic.claude-opus-4-8`（全球路由，资源最足；运维可通过 `ANTHROPIC_MODEL` env 调整）；`apac.*`/`jp.*` 亦可。
- **VPC 出站**：Runtime 须 `networkMode=VPC`（为在 VPC 内经 HTTP `:8080` 访问 index-service），而 VPC 内的
  microVM 无公网 IP，出站（Bedrock/CLI）**须经 NAT Gateway**。

## 参考惯例

本地样例：`amazon-bedrock-agentcore-samples/03-integrations/agentic-frameworks/claude-agent/claude-sdk/`
（`agent.py` + `requirements.txt`，用 `agentcore configure` / `agentcore launch` 部署）。

## 设计文档

实现前必读 [`../docs/design/agent-container_zh.md`](../docs/design/agent-container_zh.md)——组件级实现契约
（运行时形态、取证通道、鉴权、挂载契约、部署、待验证点），每条 API 论断锚定本地 SDK / 样例真实符号。

## 模块构成

- `Dockerfile`（ARM64）、`agent.py`（流式 entrypoint 薄封装）、`agent_lib.py`（纯函数
  `build_options` / `run_agent`，可单测）、`prompts/system.md`。
- `requirements.txt`（写明依赖意图，`claude-agent-sdk==0.2.103` 固定）+ `requirements.lock`（完整传递依赖锁，
  Dockerfile 按它 `uv pip install --no-deps` 安装）。

CodeGraph 接入直接用 `ClaudeAgentOptions.mcp_servers` 原生支持的 `McpHttpServerConfig`
（`{type:"http", url, headers?}`，对照 SDK 0.2.103 核实），不需 streamable-http 转换层。

## 测试

单测见 `agent-container/tests/`，经 `./scripts/test.sh`（离线套件）运行。部署见 `scripts/deploy-all.sh` + `.local/deploy-config`。
