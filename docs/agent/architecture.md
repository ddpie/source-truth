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
          · 取证只读通道（全部经 index-service 的 MCP-over-HTTP 桥；microVM 不挂任何文件系统）：
              (1) CodeGraph 定位 → 先查"哪个工程/哪些文件"（symbol_search / get_callers / analyze_impact）
              (2) 文件读取 → 按定位点读最新主分支源码与工程内配置表（Excel/JSON/CSV）：
                  codegraph_read_file / codegraph_glob_files / codegraph_search_files（仓库相对路径）
          · per-session 写盘走 Session Storage /mnt/workspace（microVM 级隔离的临时文件）
          · 逐步 yield 输出（AssistantMessage / ResultMessage）
  → bot-gateway 把流式输出 update 回 CardKit 卡片（src/cardkit-client.ts；SSE 解析 src/parse-stream.ts）
      · 单一 markdown 组件适配所有格式；注意飞书卡片 update 有频控与 10 分钟更新窗口
      · 流式完成后按 AI 实际输出动态追加交互组件：多方案→选项按钮、数值→VChart 图表、低置信度→"转研发"
      · 结构化日志 + hashUserId 脱敏（src/log.ts，用户/会话标识不落明文，MVP 仅防滥用）
```

## 数据面：代码如何进入 index-service、索引如何更新（MVP 实况）

**当前 MVP 的真实管线**（一次性快照构建，靠重部署刷新——**没有** webhook / git pull / inotify
增量 / 夜间 CI；那是 post-MVP 目标形态，未实现）：

![数据面五段管线：deploy-all 打包→S3，bootstrap 解包，index-build 建图，index-bridge 常驻只读，会话 microVM 远程取证](../assets/data-plane.svg)

**唯一一份代码、本地副本**：仓库只在 index-service 的**本地磁盘** `/data/repo/<subdir>`；codegraph-server
索引该本地副本，文件读取工具也直接读它。**会话 microVM 不挂任何文件系统**——既无 EFS、也无 `/mnt/repo`
共享挂载，全部源码经 index-service 的 HTTP 桥读取，故没有副本同步问题。**刷新方式**：代码与索引都冻结在
部署时的 S3 tarball 快照，**要更新主分支代码 / 索引必须重新部署**（替换 index-service 实例重跑 bootstrap）——
当前没有随 git push 自动刷新的链路。注：codegraph-server 的 `--serve` 带 file-watcher 增量是已实测的
引擎能力，但 MVP 用 `--mcp` 未启用，留作 post-MVP。

## 会话隔离模型（NOT in README）

| | 共享只读 | per-session 独占 |
|-|-|-|
| 内容 | 项目代码（主分支）+ CodeGraph 索引 | Agent 产生的临时文件 |
| 载体 | index-service 本地副本，经 HTTP 桥服务给所有会话 | AgentCore Session Storage `/mnt/workspace` |
| 可见性 | 所有会话 | 仅本 microVM |
| 生命周期 | 持久（部署时构建一次，重部署刷新） | per-session（约 14 天空闲过期） |

![会话隔离：多个 per-session microVM（各自独占 /mnt/workspace 临时文件）共享同一个只读 index-service 代码副本](../assets/session-isolation.svg)

机器人粒度：**每个游戏项目一个机器人**，机器人内**按会话隔离**。上下文挂在飞书对话上、按需拉取消息
记录；多用户不可共用 session。

## Provisioning 分工（改 Runtime 配置前必读）

基础设施**不全归 CDK**，且 MVP 阶段刻意先不 CDK 化：

- **MVP（当前）**：用 `agentcore` starter toolkit / boto3 直接配 AgentCore Runtime + 手工建 index-service，
  先跑通主流程与 POC 性能基准。CodeGraph 召回率、经 HTTP 桥读文件的延迟是主要待验证点——验证前不固化 IaC，
  避免返工。「为何必须建索引而非让 Agent 逐文件 grep」已有实测基准，见
  [`indexing-performance-spike.md`](indexing-performance-spike.md)（全仓冷扫 grep 本地盘约 127s、已废弃 EFS 方案最坏 265s，索引后查询恒 1–5ms）。
- **post-MVP（p2，渐进）**：CDK 管**稳定层**——会话容器镜像（DockerImageAsset，`Platform.LINUX_ARM64`）、
  AgentCore 执行 IAM 角色、index-service 常驻计算（含其本地仓库副本卷）、网关基础设施；
  而 **AgentCore Runtime 本身**（其 env、idle timeout、网络模式、请求头 allowlist）由 `scripts/deploy-all.sh`
  （已实现；内部 `lib/deploy_runtime.py`）用 boto3（`bedrock-agentcore-control` create/update_agent_runtime
  + endpoint）配——因为 Runtime 是快速演进的服务，CloudFormation 支持未稳定。

**含义**：要改 Runtime 的 env / idle timeout / 请求头，编辑 `scripts/lib/deploy_runtime.py` 并重跑
`deploy-all.sh`（`deploy.sh` 为已废弃转发垫片）——改 CDK 不会生效。密钥（飞书 app secret、bot token）走
Secrets Manager / SSM，**当前需手工在 CDK 外创建**（编排脚本尚未自动建密钥），重部署不覆盖真实凭证。

## 四个核心架构选择

source-truth 不同于「在容器外把 AI 当远程 MCP 客户端」的常见托管 MCP 形态——它把 AI 引擎放进 microVM
内，并围绕代码取证新增了两个有状态组件。四个核心选择：

1. **AI 在容器内运行**——会话 microVM 内直接跑 Claude Code Agent SDK（`agent-container/agent.py` 的
   agent 循环），AI 既是推理主体也是 MCP 消费端，而非外部 MCP 客户端。
2. **飞书 Bot 网关**——机器人身份 + 长连接事件流 + 会话→runtimeSessionId 映射。MVP 不引入 per-user
   OAuth 体系；上下文挂在飞书对话上、按需拉取。
3. **独立 CodeGraph 索引服务**——常驻单写者会话（部署时建图一次）、stdio→streamable-HTTP 桥，对会话容器暴露只读**定位 + 读文件**查询。（持 clone / inotify 增量为 post-MVP，未实现）
4. **代码仓只在 index-service 本地**——它在本地磁盘持唯一一份代码副本（部署时落代码+建索引），既供 codegraph 索引、又经 HTTP 桥的文件工具服务给会话容器；会话 microVM 不挂任何文件系统（无 EFS、无共享挂载）。

通用运维惯例：ARM64 容器 + DockerImageAsset、CDK / boto3 混合 IaC 分工、飞书 SDK / CardKit 生态、
空闲缩零按量计费、按游戏项目隔离机器人、结构化 JSON 日志 + hashUserId 脱敏、`deploy/ops/test` 三件套。

## 待验证技术点（POC 优先，影响架构定型）

- CodeGraph 对前端 Unity 风格 C# 与后端 Node.js（及 Lua 元表等动态模式）的索引召回率；
- push→索引端到端时延 + 首次全量索引耗时（社区 13 万文件约 1 小时量级）；
- CodeGraph stdio→HTTP 桥（mcp-proxy 类）的稳定性、并发、路径对齐（工具返回仓库相对路径，如 `Assets/Scripts/Foo.cs`）；
- 本地仓库副本上 inotify 增量索引的可靠性（post-MVP）；
- 经 HTTP 桥读文件的延迟（索引定位点读 vs 全仓文本检索兜底两条路径）；
- 飞书流式卡片频控、VChart 图表组件边界、动态组件回调路由。

细节见 `docs/design/architecture-overview_zh.md` 与 `requirements_zh.md`。
