# agent-container 组件设计

> 设计概览，给人读。工作原理见 [`../agent/architecture.md`](../agent/architecture.md)，MVP 边界见
> [`requirements_zh.md`](requirements_zh.md)。**实现细节**（运行时骨架、完整 env、方案对比、逐条 gotcha、
> 全部开放问题）见工作态全稿 `.claude/specs/2026-06-16-agent-container-design.md`（gitignored，本机）。

## 是什么

会话 microVM 内运行的 **Claude Code Agent（Python）**——source-truth 的推理与编排核心。收到飞书来的问题后，
在 AgentCore Firecracker microVM 内跑一个**只读问答**的 agent 循环：经远程 index-service 定位并读取
最新主分支源码 → 流式产出答案。microVM 本身不挂任何文件系统，全部取证经 index-service 的 MCP-over-HTTP 接口。

```
bot-gateway ──InvokeAgentRuntime──▶ agent-container（本组件，microVM 内）
                                       claude_agent_sdk.query 循环
                                       └─ index-service MCP-over-HTTP
                                            ├─ CodeGraph 定位（symbol_search / callers / impact）
                                            └─ 读文件（read_file / glob_files / search_files）
                                       逐步 yield → 回 CardKit 流式卡片
```

## 关键决策

- **AI 在容器内**：用 `claude_agent_sdk`（`query` + `ClaudeAgentOptions`）跑 agent 循环，是推理主体也是 MCP
  消费端，不是容器外的远程客户端。宿主是 `bedrock_agentcore.runtime.BedrockAgentCoreApp`，`@app.entrypoint`
  异步流式 handler。
- **模型走 Bedrock**：`CLAUDE_CODE_USE_BEDROCK=1`，microVM 内用 IAM role 鉴权（不传 bearer token）。模型 id
  钉死为 `global.anthropic.claude-*:0`（具体版本待定）。
- **只读边界靠工具白名单**：agent 内建 `Read`/`Glob`/`Grep` 全部禁用（`tools=[]`、不设 `cwd`），不放
  `Bash`/`Write`/`Edit`；读文件只能经 index-service 的 `codegraph_*` 工具（`read_file`/`glob_files`/`search_files`
  + 定位类）。落实「不跑引擎、不写回、不提交」。
- **代码为唯一依据**：系统 prompt（`prompts/system.md`）规定答案必经真实代码 + CodeGraph 取证；与文档冲突
  以代码为准并标注差异与时间；低置信度转研发。
- **语言 Python，容器 ARM64-only**，依赖与基础镜像 exact pin，漂移由 `scripts/check-versions.sh`（p1）守卫。

## 对外契约

| 项 | 约定 |
|----|------|
| 入参 | `{ "prompt", "session" }`（bot-gateway 注入；agent 只依赖 `prompt`，`session` 当不透明上下文） |
| 出参 | 流式 `yield` `AssistantMessage` / `ResultMessage`，由网关渲染回 CardKit |
| 代码/配置 | 经 index-service 文件工具读取（仓库副本只在 index-service 本地磁盘；microVM 不挂文件系统；路径为仓库相对，如 `Assets/Scripts/Foo.cs`） |
| 临时文件 | Session Storage 可写挂载 `/mnt/workspace`（每会话，约 14 天过期） |
| CodeGraph + 文件读取 | index-service 暴露的 MCP-over-HTTP 端点（env 注入）；定位与读文件都走此接口 |
| 会话标识 | 经头 `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` 到达，仅用于审计关联 |

## 文件布局（p1 落地）

```
agent-container/
  README.md         职责 + 契约（已存在）
  Dockerfile        ARM64 + sha256 锁定，pin SDK/CLI，非 root
  agent.py          @app.entrypoint 薄封装：收 payload、跑 query、yield
  agent_lib.py      纯函数（option 构造 / prompt 加载 / 消息适配），可单测
  prompts/system.md 系统 prompt + 问答规范 + 高频问题清单
  requirements.txt  exact pin
  tests/            agent_lib 单测 + smoke
```

## 部署

MVP 用 `agentcore` toolkit（`configure --disable-memory` → `deploy --env CLAUDE_CODE_USE_BEDROCK=1` → `invoke`
→ `destroy`），不强求 CDK。Runtime 的 env / idle timeout / 请求头由 `scripts/lib/deploy_runtime.py`（boto3，
由 `scripts/deploy-all.sh` 调用）配；`deploy.sh` 为已废弃兼容垫片。

## 待验证点（已定型 / 剩余）

**已真实验证定型（2026-06-17，东京 ap-northeast-1 实测）：**

1. **CodeGraph MCP 接入形态 → 方案 A**：真实 `claude-agent-sdk 0.2.103` 的 `ClaudeAgentOptions.mcp_servers`
   原生支持 `McpHttpServerConfig`（`{type:"http", url, headers?}`，`type` 必填）。**不需** streamablehttp + `@tool` 转换层。
   `agent_lib.build_options_dict` 已据此实现并与真 SDK 一致性测试通过。
2. **路径对齐**：codegraph-server 0.18.5 真实返回 `./`-前缀相对路径（workspace 用 `.` 时）或 workspace 绝对路径；
   `index-service/path_align.py`（`to_container_path` + `format_location`）已据真实输出实现并测试通过。当前
   `mount_root` 默认 `""`（输出仓库相对路径，如 `Assets/Scripts/Foo.cs`）。
3. **代码读取经 HTTP 接口**：仓库副本只在 index-service 本地磁盘，agent 经其文件工具
   （`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files`）读到源码；microVM 不挂任何文件系统。
   Runtime 仍 `networkMode=VPC`（为在 VPC 内经 HTTP `:8080` 访问 index-service）+ NAT 出站；模型用 `global.anthropic.*`。
4. **真实 invoke**：`InvokeAgentRuntime`（`CLAUDE_CODE_USE_BEDROCK=1`）跑通，返回真实流式响应。

**剩余待验证：** 经 HTTP 接口读文件的延迟 / 冷启动延迟 / CodeGraph 召回率 / 流式卡片频控对接 / index-service 的 HTTP 接口常驻部署。

> 逐条 gotcha 与开放问题（`session` schema、`HookContext` 语义、Bedrock 配额等）见全稿
> `.claude/specs/2026-06-16-agent-container-design.md`；真实部署资源见 `.local/deploy-config`。
