# Architecture — Mental Model for AI Agents

先读本文，再改请求如何流转、代码在哪取证、CardKit 如何回传、会话如何隔离。人面向文档（README、
structure）描述系统*是什么*；本文描述*一次提问如何穿过系统*——这是动手改之前真正需要的。

下文代码指针用「组件 + 概念锚点」表述，按名字 grep，而非信任行号（多数文件尚未落地，标注 `(p1)`）。

## 一次提问的生命周期

```
策划在飞书群 @机器人 提问
  → bot-gateway（TypeScript 长驻服务，(p1) bot-gateway/src/index.ts）
      · 通过长连接事件订阅消费 IM 事件（类比 lark-cli event consume）
      · 事件去重（飞书会重投；按 event_id 幂等）
      · 解析 @提及与问题文本，open_id → 内部 userId
      · 会话路由：(chat_id / thread_id) → runtimeSessionId（(p1) src/session-map.ts，DDB+TTL）
        —— 同一问答链复用同一 warm microVM；不同用户/会话绝不共用 session，否则上下文串扰
      · 先创建一张 CardKit 卡片（"正在思考…"），拿到 card_id 供后续流式 update
      · SigV4 签名调 AgentCore InvokeAgentRuntime（(p1) src/sigv4.ts），
        path = /runtimes/<encodeURIComponent(runtimeArn)>/invocations，带 runtimeSessionId
  → AgentCore Runtime（Firecracker microVM，每会话独立容器）
      · 秒级冷启；空闲约 15 分钟回收；Session Storage 约 14 天过期
      · microVM 内运行 agent-container（Python，(p1) agent-container/agent.py）
          · @app.entrypoint 异步流式 handler（bedrock_agentcore.runtime.BedrockAgentCoreApp）
          · Claude Code Agent SDK（claude_agent_sdk.query / ClaudeAgentOptions），
            CLAUDE_CODE_USE_BEDROCK=1 走 Bedrock 计费
          · 取证两条只读通道：
              (1) 远程 CodeGraph MCP-over-HTTP（index-service）→ 先定位"查哪个工程/哪些文件"
              (2) EFS /mnt/repo 只读挂载 → 按定位点读最新主分支源码与工程内配置表（Excel/JSON/CSV）
          · per-session 写盘走 Session Storage /mnt/workspace（microVM 级隔离的临时文件）
          · 逐步 yield 输出（AssistantMessage / ResultMessage）
  → bot-gateway 把流式输出 update 回 CardKit 卡片（src/cardkit-client.ts；SSE 解析 src/parse-stream.ts）
      · 单一 markdown 组件适配所有格式；注意飞书卡片 update 有频控与 10 分钟更新窗口
      · 流式完成后按 AI 实际输出动态追加交互组件：多方案→选项按钮、数值→VChart 图表、低置信度→"转研发"
      · 结构化日志 + hashUserId 脱敏（src/log.ts，用户/会话标识不落明文，MVP 仅防滥用）
```

## 数据面：代码如何进入 EFS、索引如何更新（NOT in README）

```
内网 GitLab ──(反向拉取 / 打包至 AWS)──▶ index-service（常驻，持 clone）
  git push → webhook → git pull (~1s) → 写 EFS worktree（MVP 仅 main）
                                          → inotify 监听 → CodeGraph 增量重建 (~3s)
                                          → 夜间 CI 全量重建兜底
index-service 以 mcp-proxy 类桥把 CodeGraph 的 stdio MCP 暴露为 streamable HTTP，
会话容器通过该 HTTP 端点远程查询（codegraph_search / callers / impact 等）。
```

**单一份代码、无副本**：EFS 卷被 index-service **可写**挂载（监听变更建索引），被每个会话 microVM
**只读**挂载到 `/mnt/repo`（读最新代码）。一份代码，没有副本同步问题。AI 通过索引定位文件后读的是
**代码最新版本**，不是索引快照。

## 会话隔离模型（NOT in README）

| | 共享只读 | per-session 独占 |
|-|-|-|
| 内容 | 项目代码（主分支 worktree）+ CodeGraph 索引 | Agent 产生的临时文件 |
| 载体 | EFS 卷只读挂载 `/mnt/repo` | AgentCore Session Storage `/mnt/workspace` |
| 可见性 | 所有会话 | 仅本 microVM |
| 生命周期 | 持久（push 增量 + 夜间兜底） | per-session（约 14 天空闲过期） |

机器人粒度：**每个游戏项目一个机器人**，机器人内**按会话隔离**。上下文挂在飞书对话上、按需拉取消息
记录；多用户不可共用 session。

## Provisioning 分工（改 Runtime 配置前必读）

基础设施**不全归 CDK**，且 MVP 阶段刻意先不 CDK 化：

- **MVP（当前）**：用 `agentcore` starter toolkit / boto3 直接配 AgentCore Runtime + 手工建 EFS /
  index-service，先跑通主流程与 POC 性能基准。CodeGraph 召回率、EFS 读性能与同卷并发挂载、NFS 上
  inotify 可靠性是三大待验证点——验证前不固化 IaC，避免返工。EFS 读性能与「为何必须建索引」已有
  实测基准，见 [`indexing-performance-spike.md`](indexing-performance-spike.md)（EFS 冷扫 grep 达 265s，索引后查询恒
  1–5ms）。
- **post-MVP（p2，渐进）**：CDK 管**稳定层**——会话容器镜像（DockerImageAsset，`Platform.LINUX_ARM64`）、
  AgentCore 执行 IAM 角色、EFS（FileSystem + AccessPoint + VPC）、index-service 常驻计算、网关基础设施；
  而 **AgentCore Runtime 本身**（其 env、idle timeout、网络模式、请求头 allowlist）由 `scripts/deploy-all.sh`
  （已实现；内部 `lib/deploy_runtime.py`）用 boto3（`bedrock-agentcore-control` create/update_agent_runtime
  + endpoint）配——因为 Runtime 是快速演进的服务，CloudFormation 支持未稳定。

**含义**：要改 Runtime 的 env / idle timeout / 请求头，编辑 `scripts/lib/deploy_runtime.py` 并重跑
`deploy-all.sh`（`deploy.sh` 为已废弃转发垫片）——改 CDK 不会生效。密钥（飞书 app secret、bot token）走
Secrets Manager / SSM，**当前需手工在 CDK 外创建**（编排脚本尚未自动建密钥），重部署不覆盖真实凭证。

## 四个核心架构选择

source-truth 不同于「在容器外把 AI 当远程 MCP 客户端」的常见托管 MCP 形态——它把 AI 引擎放进 microVM
内，并围绕代码取证新增了三个有状态组件。四个核心选择：

1. **AI 在容器内运行**——会话 microVM 内直接跑 Claude Code Agent SDK（`agent-container/agent.py` 的
   agent 循环），AI 既是推理主体也是 MCP 消费端，而非外部 MCP 客户端。
2. **飞书 Bot 网关**——机器人身份 + 长连接事件流 + 会话→runtimeSessionId 映射。MVP 不引入 per-user
   OAuth 体系；上下文挂在飞书对话上、按需拉取。
3. **独立 CodeGraph 索引服务**——常驻、持 clone、inotify 增量、stdio→HTTP 桥，对会话容器暴露只读查询。
4. **EFS 共享代码仓**——index-service 可写挂载监听、会话容器只读挂载读取，一份代码无副本。

通用运维惯例：ARM64 容器 + DockerImageAsset、CDK / boto3 混合 IaC 分工、飞书 SDK / CardKit 生态、
空闲缩零按量计费、按游戏项目隔离机器人、结构化 JSON 日志 + hashUserId 脱敏、`deploy/ops/test` 三件套。

## 待验证技术点（POC 优先，影响架构定型）

- CodeGraph 对前端 Unity 风格 C# 与后端 Node.js（及 Lua 元表等动态模式）的索引召回率；
- push→索引端到端时延 + 首次全量索引耗时（社区 13 万文件约 1 小时量级）；
- CodeGraph stdio→HTTP 桥（mcp-proxy 类）的稳定性、并发、路径对齐（工具返回路径 vs 容器挂载路径）；
- EFS 同卷并发挂载 + NFS 上 inotify 增量可靠性；
- EFS 读性能（索引定位点读 vs 全仓兜底两条路径）；
- 飞书流式卡片频控、VChart 图表组件边界、动态组件回调路由。

细节见 `docs/design/architecture-overview_zh.md` 与 `requirements_zh.md`。
