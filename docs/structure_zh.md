[中文](structure_zh.md) | [English](structure_en.md)

# 项目结构

> 权威顶层目录树。改动任何顶层目录，必须同步本文件与 `structure_en.md`（`scripts/check-invariants.sh` 校验）。

```
agent-container/        会话 microVM 内运行的 Claude Code Agent（Python）
  README.md             职责 + 对外契约（输入 goal/session、CodeGraph MCP 端点、EFS 挂载点）
  prompts/              系统 prompt + 高频问题清单 + 问答规范（代码为准 / 标差异 / 转研发）
  Dockerfile            ARM64 基础镜像 sha256 锁定；pin Claude Agent SDK + @anthropic-ai/claude-code
  agent.py              @app.entrypoint 异步流式 handler，启动 Agent 循环
  agent_lib.py          SDK-free 只读问答 Agent 主逻辑（agent.py 的可测试内核：选项构建 / 取证循环）
  requirements.txt + requirements.lock  钉死的 Python 依赖（lock = pip freeze 全传递）
  tests/                pytest（由 scripts/test.sh 调用）
bot-gateway/            飞书 Bot 长连接事件网关 + CardKit 流式渲染（TypeScript 长驻服务）
  README.md             长连接 / 事件去重 / 会话→runtimeSessionId 映射 / 卡片更新频控
  src/                  事件消费入口、SigV4 调 AgentCore、会话映射、CardKit 渲染、SSE 解析、脱敏日志
index-service/          常驻 CodeGraph 索引服务 + MCP-over-HTTP 桥
  README.md             常驻单写者会话 / CodeGraph / HTTP 桥 / EFS 挂载 / bootstrap
  http_bridge.py        FastMCP HTTP 桥（包根，非 src/）：暴露 codegraph 工具，路径对齐到 /mnt/repo
  codegraph_session.py  常驻 codegraph-server 单写者会话（worker 线程 + 私有 loop，健康自愈，带超时）
  file_search.py        本地副本 ripgrep/grep 检索工具（替代 EFS grep 慢 ~225x；命中按内容去重；MCP 暴露）
  path_align.py         索引路径 ↔ /mnt/repo 词法对齐（拒越界）
  codegraph_client.py   codegraph-server 客户端封装
  perf.py               结构化耗时日志
  bootstrap.sh          EC2 user-data：装依赖 / 挂 EFS / 快照 stamp 重解压 / systemd build→bridge
  tests/                pytest（由 scripts/test.sh 调用）
infra/                  基础设施即代码（MVP 先 agentcore toolkit / boto3，渐进 CDK 化）
  README.md             IaC 分工：CDK 管稳定层 / deploy-all.sh 用 boto3 配 AgentCore Runtime
  (p2) lib/             runtime / storage(EFS) / codegraph / gateway 各 stack
shared/                 跨包共享：结构化日志（hashUserId 脱敏）、MCP 工具 schema、卡片协议类型
config/                 配置驱动：i18n.json（卡片 / 告警 / 错误文案）、alarm-thresholds.json
scripts/                运维生命周期
  check-invariants.sh   快速结构 lint（AGENTS / CLAUDE / structure / 双语配对 / 顶层目录存在性）
  lib/                  common.sh（格式化 + 依赖检查）、env-utils.sh（.env / deploy-config 共享 helper）
  test.sh               单一分层测试入口（离线默认 / --full）
  check-versions.sh     版本钉死防漂移守卫（base digest / requirements pin / Node / claude-code npm）
  deploy-all.sh         一键部署 canonical（artifacts→IAM→network→EFS→index-service→镜像→Runtime；幂等）
  lib/provision_*.sh + deploy_runtime.py + wait_index_health.sh  deploy-all.sh 的各阶段实现
  ⚠️ deploy.sh          已废弃兼容垫片（转发到 deploy-all.sh）
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
