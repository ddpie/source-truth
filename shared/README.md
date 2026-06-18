# shared

跨包共享代码与契约。

- 结构化 JSON 日志助手（单行 `JSON.stringify({...})` + `hashUserId` sha256 脱敏）。
  **`hashUserId` 已落地**于 `bot-gateway/src/log.ts`：bot-gateway 日志对 chatId / messageId
  脱敏、不再记原始问题文本（仅记长度）。后续可上提为真正的跨包 `shared/`。
- MCP 工具 schema、CardKit 卡片协议类型——agent-container 与 bot-gateway 共享的契约。

状态：p0 占位（`hashUserId` 已在 bot-gateway 内实现；其余契约 p1 落地）。
