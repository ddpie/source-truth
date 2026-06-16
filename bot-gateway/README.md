# bot-gateway

飞书 Bot 长连接事件网关 + CardKit 流式渲染（**TypeScript / Node 20 长驻服务**）。

## 职责

每个游戏项目一个机器人。网关通过**长连接事件订阅**消费飞书 IM 事件（@助手提问、卡片回调），按会话
路由到 AgentCore Runtime 的对应 session，并把 Agent 的流式输出实时渲染 / 更新到 CardKit 卡片。

## 子模块（p1）

| 文件 | 职责 |
|------|------|
| `src/index.ts` | 事件消费入口（长连接订阅，类比 `lark-cli event consume`）；事件去重、@提及解析 |
| `src/session-map.ts` | 会话 (chat_id / thread_id) → runtimeSessionId 映射（DDB + TTL，复用 warm 容器） |
| `src/sigv4.ts` | SigV4 签名调 AgentCore `/runtimes/<arn>/invocations`（按会话注入 runtimeSessionId） |
| `src/cardkit.ts` | CardKit 卡片构建 + 流式 create/update 循环；完成后动态追加按钮 / 图表 / 转研发组件 |
| `src/audit.ts` | prompt/response 审计日志（hashUserId 脱敏，MVP 仅防滥用） |

## 关键约束

- **长驻在线**：长连接需常在线，不能空闲缩零（建议 ECS Fargate / 常驻容器承载）。
- **会话隔离**：不同用户 / 会话绝不共用 runtimeSessionId，否则上下文串扰。
- **卡片频控**：飞书卡片 update 有频率限制与 10 分钟更新窗口，流式更新需做节流。
- **事件幂等**：飞书事件会重投，按 event_id 去重。

## 运行载体

长驻服务（ECS Fargate / 常驻容器）。语言选 TypeScript：飞书官方 SDK 与 CardKit 流式卡片在 TS 生态最成熟。

## 状态

p0：占位。p1 落地上述 `src/*` 与 `package.json` / ESLint 配置。
