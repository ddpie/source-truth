# agent-container 组件设计

> 设计概览，给人读。心智模型见 [`../agent/architecture.md`](../agent/architecture.md)，MVP 边界见
> [`requirements_zh.md`](requirements_zh.md)。**实现细节**（运行时骨架、完整 env、方案对比、逐条 gotcha、
> 全部开放问题）见工作态全稿 `.claude/specs/2026-06-16-agent-container-design.md`（gitignored，本机）。

## 是什么

会话 microVM 内运行的 **Claude Code Agent（Python）**——source-truth 的推理与编排核心。收到飞书来的问题后，
在 AgentCore Firecracker microVM 内跑一个**只读问答**的 agent 循环：调远程 CodeGraph 定位代码 → 读 EFS 上的
最新主分支源码 → 流式产出答案。

```
bot-gateway ──InvokeAgentRuntime──▶ agent-container（本组件，microVM 内）
                                       claude_agent_sdk.query 循环
                                       ├─ CodeGraph MCP-over-HTTP  ← 定位代码
                                       └─ EFS /mnt/repo（只读）     ← 读真实代码/配置
                                       逐步 yield → 回 CardKit 流式卡片
```

## 关键决策

- **AI 在容器内**：用 `claude_agent_sdk`（`query` + `ClaudeAgentOptions`）跑 agent 循环，是推理主体也是 MCP
  消费端，不是容器外的远程客户端。宿主是 `bedrock_agentcore.runtime.BedrockAgentCoreApp`，`@app.entrypoint`
  异步流式 handler。
- **模型走 Bedrock**：`CLAUDE_CODE_USE_BEDROCK=1`，microVM 内用 IAM role 鉴权（不传 bearer token）。模型 id
  钉死为 `global.anthropic.claude-*:0`（具体版本待定）。
- **只读边界靠工具白名单**：`allowed_tools` 只放 `Read`/`Glob`/`Grep` + CodeGraph 工具，不放 `Bash`/`Write`/
  `Edit`；`/mnt/repo` 内核级只读兜底。落实「不跑引擎、不写回、不提交」。
- **代码为唯一依据**：系统 prompt（`prompts/system.md`）规定答案必经真实代码 + CodeGraph 取证；与文档冲突
  以代码为准并标注差异与时间；低置信度转研发。
- **语言 Python，容器 ARM64-only**，依赖与基础镜像 exact pin，漂移由 `scripts/check-versions.sh`（p1）守卫。

## 对外契约

| 项 | 约定 |
|----|------|
| 入参 | `{ "prompt", "session" }`（bot-gateway 注入；agent 只依赖 `prompt`，`session` 当不透明上下文） |
| 出参 | 流式 `yield` `AssistantMessage` / `ResultMessage`，由网关渲染回 CardKit |
| 代码/配置 | EFS 只读挂载 `/mnt/repo`（最新主分支） |
| 临时文件 | Session Storage 可写挂载 `/mnt/workspace`（per-session，约 14 天过期） |
| CodeGraph | index-service 暴露的 MCP-over-HTTP 端点（env 注入） |
| 会话标识 | 经头 `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id` 到达，仅用于审计关联 |

## 文件布局（p1 落地）

```
agent-container/
  README.md         职责 + 契约（已存在）
  Dockerfile        ARM64 + sha256 锁定，pin SDK/CLI，非 root
  agent.py          @app.entrypoint 薄壳：收 payload、跑 query、yield
  agent_lib.py      纯函数（option 构造 / prompt 加载 / 消息适配），可单测
  prompts/system.md 系统 prompt + 问答规范 + 高频问题清单
  requirements.txt  exact pin
  tests/            agent_lib 单测 + smoke
```

## 部署

MVP 用 `agentcore` toolkit（`configure --disable-memory` → `deploy --env CLAUDE_CODE_USE_BEDROCK=1` → `invoke`
→ `destroy`），不强求 CDK。Runtime 的 env / idle timeout / 请求头由 `scripts/deploy.sh`（p1，boto3）配。

## 待验证点（已定型 / 剩余）

**已真实验证定型（2026-06-17，东京 ap-northeast-1 实测）：**

1. **CodeGraph MCP 接入形态 → 方案 A**：真实 `claude-agent-sdk 0.2.103` 的 `ClaudeAgentOptions.mcp_servers`
   原生支持 `McpHttpServerConfig`（`{type:"http", url, headers?}`，`type` 必填）。**不需** streamablehttp + `@tool` 桥。
   `agent_lib.build_options_dict` 已据此实现并与真 SDK 一致性测试通过。
2. **路径对齐**：codegraph-server 0.18.5 真实返回 `./`-前缀相对路径（workspace 用 `.` 时）或 workspace 绝对路径；
   `index-service/path_align.py`（`to_container_path` + `format_location`）已据真实输出实现并测试通过。
3. **EFS 挂载**：真实挂载 `/mnt/repo` 成功，agent 真读到源码。**仅东京支持**（us-east-1 服务端返回
   `SDK_UNKNOWN_MEMBER`）；须 botocore≥1.43、`networkMode=VPC` + NAT 出站；模型用 `global.anthropic.*`。
4. **真实 invoke**：`InvokeAgentRuntime`（`CLAUDE_CODE_USE_BEDROCK=1`）跑通，返回真实流式响应。

**剩余待验证：** EFS 读性能 / 冷启动延迟 / CodeGraph 召回率 / 流式卡片频控对接 / index-service 桥的 HTTP 半边常驻部署。

> 逐条 gotcha 与开放问题（`session` schema、`HookContext` 语义、Bedrock 配额等）见全稿
> `.claude/specs/2026-06-16-agent-container-design.md`；真实部署资源见 `.local/deploy-config`。
