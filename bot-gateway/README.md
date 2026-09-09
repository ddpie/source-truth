# bot-gateway

飞书 Bot 长连接事件网关 + CardKit 流式渲染（**TypeScript / Node 24 长驻服务**）。

## 职责

每个游戏项目一个机器人。网关通过**长连接事件订阅**消费飞书 IM 事件（@助手提问、卡片回调），按会话
路由到 AgentCore Runtime 的对应 session，并把 Agent 的流式输出实时渲染 / 更新到 CardKit 卡片。
支持普通文本和富文本消息中的文字；图片、音视频和附件不作为问答输入。群聊仍需 @对应机器人，
原提问人直接回复其答案卡片也可继续追问。

## 子模块

| 文件 | 职责 |
|------|------|
| `src/index.ts` | 事件消费入口（长连接订阅，类比 `lark-cli event consume`）；事件去重、@提及解析 |
| `src/session-map.ts` | 会话 (chat_id / thread_id) → runtimeSessionId 映射（MVP 为进程内内存 Map + 滑动 TTL，复用仍存活的会话；多进程扩展时再换 DDB） |
| `src/sigv4.ts` | SigV4 签名调 AgentCore `/runtimes/<arn>/invocations`（按会话注入 runtimeSessionId） |
| `src/cardkit-client.ts` | CardKit 卡片构建 + 流式 create/update 循环；动态追加停止按钮 / 图表 / 追问按钮 / 「供研发复核」出处面板 |
| `src/log.ts` | 结构化日志 + `hashUserId` 脱敏（用户/会话/消息标识不落明文） |
| `src/health.ts` | 健康端点 HTTP 服务（只绑 `127.0.0.1`）：`/health` 存活、`/ready` 就绪。见下方「健康端点」 |
| `src/handle-event.ts` · `src/sdk-event.ts` | IM 事件核心：去重、@提及解析 / 群里 @ 门控、会话路由 |
| `src/parse-stream.ts` · `src/redact.ts` · `src/extract-charts.ts` · `src/extract-followups.ts` | SSE 解析（含错误传播）/ 敏感信息脱敏 / 图表块抽取 / 追问抽取 |

## 关键约束

- **长驻在线**：长连接需常在线、不能空闲缩零；当前由 index-service 主机上的 systemd 实例
  `bot-gateway@<项目>` 承载，每项目一个。独立托管形态为 post-MVP。
- **会话隔离**：每次调用创建独立 SDK 会话，仅回放当前追问链；不同会话可串行复用空闲 microVM，
  不共享对话历史。
- **卡片频控**：飞书卡片 update 有频率限制与 10 分钟更新窗口，流式更新需做节流。
- **卡片宽度**：Card 2.0 使用 `width_mode: "fill"`，随聊天区可用宽度调整；创建与完成卡片均保留该设置。
- **事件幂等**：飞书事件会重投，按 event_id 去重。

## 健康端点

网关另起一个只绑 `127.0.0.1` 的 HTTP 服务，两条路由分工明确：

| 路由 | 语义 | 何时非 200 |
|------|------|-----------|
| `GET /health`（等价 `/healthz`） | **存活**：进程还能应答就 200，长连接在做什么都不影响 | 进程没了才连不上 |
| `GET /ready` | **就绪**：长连接已连上且不在优雅退出中才 200 | 启动中（还没 onReady）、重连中、退出中都是 503 |

响应体带 `status` / `uptimeSeconds` / `wsState` / `draining` / `lastEventTs` / `lastEventAgoSeconds` / `memoryMB`。
挂重启动作的探针请用 `/health`：SDK 正常重连只要两秒，若拿 `/ready` 去触发重启会打断所有在飞的卡片、
把自愈变成重启循环。要判断「飞书长连接到底通不通」看 `/ready` 或响应体里的 `wsState`。

端口默认由本项目的 bridge 端口推导：**bridge 端口 + 10000**（8080 → 18080）。一台索引主机每个项目跑一个
网关，固定单一端口会让除第一个之外的网关都没有健康端点，所以按项目推导；`HEALTH_PORT` 可显式覆盖，部署
时 `activate_gateway.sh` 会按项目把它写进 `/etc/bot-gateway-<项目>.env`，systemd 单元的启动探针读同一个值。
端口被占用或取值非法时只记一条 `health_server_unavailable` 日志，网关照常运行。

响应体故意不含 projectId、仓库名、endpoint 与任何会话 / 用户标识——这是个无鉴权端口，那些信息属于日志。

## 本地启动

```bash
npm ci
# 必需 env（deploy 按项目写 RUNTIME_ARN_<项目> 到 .local/deploy-config，
# 项目名里的 - 换成 _，取你要调试的那个）：
export AWS_REGION=ap-northeast-1
export RUNTIME_ARN="$(grep '^RUNTIME_ARN_<项目>=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx          # 从 Secrets Manager/SSM 取出注入，勿写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
export LOG_HASH_SALT=some-salt        # 可选但建议（脱敏盐）
export HEALTH_PORT=18080              # 可选：健康端点端口，默认 bridge 端口 + 10000
# 本地调试启动（长驻；ts-node 直接运行 TS，无需预编译）：
node_modules/.bin/ts-node --transpile-only src/index.ts
```

> 线上不是这样起的：index 主机上由 systemd 跑 `run.sh`，它从 Secrets Manager 取飞书凭证注入进程
> 环境（不落盘），再 `exec node dist/index.js`（编译产物，非 ts-node）。详见 [`../docs/runbook_zh.md`](../docs/runbook_zh.md)。

成功日志：`sdk_wsclient_started` → `sdk_wsclient_connected`（健康端点起来时另有 `health_server_started`）。
完整的「连飞书 + 验证 + 排错」见 [`../docs/runbook_zh.md`](../docs/runbook_zh.md)。

> `package.json` 的 `build`/`lint`/`test` 是开发用脚本；启动用上面的 `ts-node` 命令运行入口。
> **同一个飞书应用只能运行一个网关实例**（长连接集群模式，事件只投给一个 client；多实例会争抢事件，导致行为异常）。
