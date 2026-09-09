# agent-container

会话 microVM 内运行的 **OpenAI / Claude Agent SDK**（Python）——source-truth 的推理与编排核心。
部署配置与切换见 [`docs/dual-sdk_zh.md`](../docs/dual-sdk_zh.md)。

## 职责

在 AgentCore Runtime 的 Firecracker microVM 内，用所选 **OpenAI Agents SDK / Claude Agent SDK** +
**bedrock-agentcore** runtime（`@app.entrypoint` 异步流式 handler）执行 agent 循环：理解策划的问题 →
调远程 CodeGraph MCP 定位代码 → 经 index-service 的文件工具读最新主分支源码与配置表（含 Excel/CSV/SQLite 数值表）→
生成结构化答案并流式 `yield`。

模型走 Bedrock Runtime。新项目默认 OpenAI；旧项目保持 Claude。Codex SDK 仍后置。

## 对外契约

| 项 | 约定 |
|----|------|
| 入参 payload | `{ "prompt": <问题文本>, "traceId": <贯通两侧日志>, "repos": <项目所属仓库列表，可选> }`（由 bot-gateway 注入；runtimeSessionId 走 AgentCore header，不在 payload 里） |
| CodeGraph + 文件读取 | 远程 MCP-over-HTTP 端点（由 index-service 暴露），通过 env / option 注入；定位与读文件（`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files` / `codegraph_read_table`）都走此接口 |
| 代码与配置 | 经 index-service 文件工具读取（**仓库副本只在 index-service 本地磁盘**；microVM 不挂仓库文件系统）；路径为仓库相对（如 `Assets/Scripts/Foo.cs`） |
| 临时文件 | Session Storage 可写挂载在 `/mnt/workspace`（每会话隔离） |
| 出参 | `engine_runner` 输出版本化文本/工具/终态事件，由网关渲染回 CardKit |

## 取证原则（代码为唯一依据）

- 答案必须基于 index-service 提供的真实代码，并经 CodeGraph 取证；
- 代码与文档 / 记忆冲突时**以代码为准**，并标注差异与文档时间；
- 低置信度时在答案中标注并建议转研发确认。

## 约束

- **ARM64-only** 容器；基础镜像与 Claude Agent SDK 版本固定（pin，`claude-agent-sdk==0.2.103`）。
  （lark-cli 仅是开发期手测工具，不装进任何运行镜像，不在该 pin 范围内。）
- **只读边界**：MVP 仅问答，不跑引擎、不写回、不提交。两条路径都只开放 index-service 的只读
  `codegraph_*` 工具。OpenAI 使用 MCP 工具白名单，不注册本地文件或 shell 工具；Claude 禁用内建
  `Read`/`Glob`/`Grep`（`tools=[]`，不设 `cwd`），并使用 `disallowed_tools`、
  `permission_mode="dontAsk"`、`strict_mcp_config=True` 和 `setting_sources=[]`。
- **模型 ID 按区域**：部署按实际 system inference profile 列表解析，不跨模型降级。
  运行时配置为 `AGENT_SDK` / `AGENT_MODEL`；Claude 兼容 `ANTHROPIC_MODEL`。
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
- `agent_settings.py`（部署配置）、`engine_runner.py`（分派与统一事件）、
  `openai_runner.py`（OpenAI MCP 循环）、`openai_backend.py`（模型构造和 trace 接入）、
  `bedrock_converse.py`（ConverseStream、SigV4、工具与推理上下文转换，术语表复用）。
- `requirements.txt`（写明依赖意图，`claude-agent-sdk==0.2.103` 固定）+ `requirements.lock`（完整传递依赖锁，
  Dockerfile 按它 `uv pip install --no-deps` 安装）。

CodeGraph 接入由所选 SDK 在 microVM 内完成：Claude 使用
`ClaudeAgentOptions.mcp_servers` 的 `McpHttpServerConfig`（`{type:"http", url, headers?}`），
OpenAI 使用 `MCPServerStreamableHttp` 与工具过滤器。两者使用同一只读工具清单，
事件由 `engine_runner.py` 统一后交给网关。

## 测试

单测见 `agent-container/tests/`，经 `./scripts/test.sh`（离线套件）运行。部署见 `scripts/deploy-all.sh` + `.local/deploy-config`。
