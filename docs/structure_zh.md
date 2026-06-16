[中文](structure_zh.md) | [English](structure_en.md)

# 项目结构

> 权威顶层目录树。改动任何顶层目录，必须同步本文件与 `structure_en.md`（`scripts/check-invariants.sh` 校验）。

```
agent-container/        会话 microVM 内运行的 Claude Code Agent（Python）
  README.md             职责 + 对外契约（输入 goal/session、CodeGraph MCP 端点、EFS 挂载点）
  prompts/              系统 prompt + 高频问题清单 + 问答规范（代码为准 / 标差异 / 转研发）
  (p1) Dockerfile       ARM64 基础镜像 sha256 锁定；pin Claude Agent SDK + lark-cli
  (p1) agent.py         @app.entrypoint 异步流式 handler，启动 Agent 循环
bot-gateway/            飞书 Bot 长连接事件网关 + CardKit 流式渲染（TypeScript 长驻服务）
  README.md             长连接 / 事件去重 / 会话→runtimeSessionId 映射 / 卡片更新频控
  src/                  事件消费入口、SigV4 调 AgentCore、会话映射、CardKit、审计日志
index-service/          常驻 CodeGraph 索引服务 + MCP-over-HTTP 桥
  README.md             持 clone / git pull / inotify 增量 / CodeGraph / HTTP 桥 / 夜间全量兜底
  src/                  webhook 接收 + worktree 生命周期 + mcp-proxy 类桥
infra/                  基础设施即代码（MVP 先 agentcore toolkit / boto3，渐进 CDK 化）
  README.md             IaC 分工：CDK 管稳定层 / deploy.sh 用 boto3 配 AgentCore Runtime
  (p2) lib/             runtime / storage(EFS) / codegraph / gateway 各 stack
shared/                 跨包共享：结构化日志（hashUserId 脱敏）、MCP 工具 schema、卡片协议类型
config/                 配置驱动：i18n.json（卡片 / 告警 / 错误文案）、alarm-thresholds.json
scripts/                运维生命周期
  check-invariants.sh   快速结构 lint（AGENTS / CLAUDE / structure / 双语配对 / 顶层目录）
  (p1) lib/             common.sh（格式化 + 依赖检查）、config.sh（.local 配置 + region 解析）
  (p1) test.sh          单一分层测试入口（离线默认 / --full）
  (p1) check-versions.sh 版本钉死防漂移守卫
  (p1) deploy.sh        编排三组件部署（幂等 = 升级）
  (p2) ops.sh           运维工具（status / logs / reindex / destroy）
  (p2) teardown.sh      有序销毁 + 保留资源清单
docs/
  structure_zh.md       本文件（权威目录树，双语配对）
  structure_en.md       英文对照
  design/               设计真相源（中文）
    requirements_zh.md          需求与方案评审纪要（导入）
    architecture-overview_zh.md POC 架构方案（导入）
    agent-container_zh.md       agent-container 组件实现契约
  agent/                AI 面向文档
    architecture.md     心智模型：一次提问如何穿过系统
    invariants.md       （p1）源 → 生成物映射 + 改 X 必改 Y 的耦合
    playbooks.md        （p1）有序变更配方
.local/                 （已 gitignore）账号特定部署状态：deploy-config、deploy-output.md
```

标注 `(p1)` / `(p2)` 的条目为后续阶段产出，当前仅占位或尚未创建。
