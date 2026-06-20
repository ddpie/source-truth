# bot-gateway

飞书 Bot 长连接事件网关 + CardKit 流式渲染（**TypeScript / Node 20 长驻服务**）。

## 职责

每个游戏项目一个机器人。网关通过**长连接事件订阅**消费飞书 IM 事件（@助手提问、卡片回调），按会话
路由到 AgentCore Runtime 的对应 session，并把 Agent 的流式输出实时渲染 / 更新到 CardKit 卡片。

## 子模块

| 文件 | 职责 |
|------|------|
| `src/index.ts` | 事件消费入口（长连接订阅，类比 `lark-cli event consume`）；事件去重、@提及解析 |
| `src/session-map.ts` | 会话 (chat_id / thread_id) → runtimeSessionId 映射（DDB + TTL，复用热容器） |
| `src/sigv4.ts` | SigV4 签名调 AgentCore `/runtimes/<arn>/invocations`（按会话注入 runtimeSessionId） |
| `src/cardkit-client.ts` | CardKit 卡片构建 + 流式 create/update 循环；动态追加停止按钮 / 图表 / 追问按钮 / 「供研发复核」出处面板 |
| `src/log.ts` | 结构化日志 + `hashUserId` 脱敏（用户/会话/消息标识不落明文） |
| `src/handle-event.ts` · `src/sdk-event.ts` | IM 事件核心：去重、@提及解析 / 群里 @ 门控、会话路由 |
| `src/parse-stream.ts` · `src/redact.ts` · `src/extract-charts.ts` · `src/extract-followups.ts` | SSE 解析（含错误传播）/ 敏感信息脱敏 / 图表块抽取 / 追问抽取 |

## 关键约束

- **长驻在线**：长连接需常在线，不能空闲缩零（建议 ECS Fargate / 常驻容器承载）。
- **会话隔离**：不同用户 / 会话绝不共用 runtimeSessionId，否则上下文串扰。
- **卡片频控**：飞书卡片 update 有频率限制与 10 分钟更新窗口，流式更新需做节流。
- **事件幂等**：飞书事件会重投，按 event_id 去重。

## 本地启动

```bash
npm install
# 必需 env（RUNTIME_ARN 来自后端部署写入的 .local/deploy-config）：
export AWS_REGION=ap-northeast-1
export RUNTIME_ARN="$(grep '^AGENT_RUNTIME_ARN=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx          # 从 Secrets Manager/SSM 取出注入，勿写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
export LOG_HASH_SALT=some-salt        # 可选但建议（脱敏盐）
# 启动（长驻；ts-node 直接跑 TS，无需预编译）：
node_modules/.bin/ts-node --transpile-only src/index.ts
```

成功日志：`sdk_wsclient_started` → `sdk_wsclient_connected`。完整的「连飞书 + 验证 + 排错」见
[`../docs/runbook.md`](../docs/runbook.md)。

> `package.json` 的 `build`/`lint`/`test` 是开发用脚本；启动用上面的 `ts-node` 命令直接跑入口。
> **同一个飞书应用只能跑一个网关实例**（长连接集群模式，事件只投给一个 client；多实例会争抢事件、表现出旧行为）。

## 运行载体

长驻服务（ECS Fargate / 常驻容器）。语言选 TypeScript：飞书官方 SDK 与 CardKit 流式卡片在 TS 生态最成熟。

## 运行形态

本地 `ts-node` 跑，飞书长连接单消费者。运行所需 env：`RUNTIME_ARN` / `AWS_REGION` / `FEISHU_APP_ID` /
`FEISHU_APP_SECRET` / `FEISHU_BOT_OPEN_ID`（群里精确判定被 @）/ `LOG_HASH_SALT`。
ECS 常驻托管为 post-MVP。
