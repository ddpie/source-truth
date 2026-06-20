[中文](structure_zh.md) | [English](structure_en.md)

# 项目结构

> 权威顶层目录树。改动任何顶层目录，必须同步本文件与 `structure_en.md`（`scripts/check-invariants.sh` 校验）。

```
agent-container/        会话 microVM 内运行的 Claude Code Agent（Python）
  README.md             职责 + 对外契约（输入 goal/session、index-service MCP 端点：定位 + 读文件）
  prompts/              系统 prompt + 高频问题清单 + 问答规范（代码为准 / 标差异 / 转研发）
  Dockerfile            ARM64 基础镜像 sha256 锁定；pin Claude Agent SDK（claude-agent-sdk）；@anthropic-ai/claude-code 按运维决定跟 @latest（不 pin）
  agent.py              @app.entrypoint 异步流式 handler，启动 Agent 循环
  agent_lib.py          SDK-free 只读问答 Agent 主逻辑（agent.py 的可测试内核：选项构建 / 取证循环）
  requirements.txt + requirements.lock  钉死的 Python 依赖（lock = pip freeze 全传递）
  tests/                pytest（由 scripts/test.sh 调用）
bot-gateway/            飞书 Bot 长连接事件网关 + CardKit 流式渲染（TypeScript 长驻服务）
  README.md             长连接 / 事件去重 / 会话→runtimeSessionId 映射 / 卡片更新频控
  src/                  事件消费入口、SigV4 调 AgentCore、会话映射、CardKit 渲染、SSE 解析、脱敏日志
  run.sh                服务启动器：source /etc/bot-gateway.env + 从 Secrets Manager 取飞书凭证（不落盘）→ node dist
index-service/          常驻 CodeGraph 索引服务 + MCP-over-HTTP 接口
  README.md             常驻会话（独占写入 graph.db） / CodeGraph / HTTP 接口（定位 + 读文件） / 本地仓库副本 / bootstrap
  http_bridge.py        FastMCP HTTP 接口（包根，非 src/）：暴露 codegraph 定位 + 读文件工具，路径对齐为仓库相对
  codegraph_session.py  常驻 codegraph-server 会话，独占写入 graph.db（worker 线程 + 私有 loop，健康自愈，带超时）
  file_search.py        本地副本 ripgrep/grep 检索工具（在本地副本上检索，内置 Grep 禁用、改走本地副本；命中按内容去重；MCP 暴露）
  file_read.py          本地副本按行 / 按位置读取文件的工具（read_file，路径对齐为仓库相对；MCP 暴露）
  file_table.py         结构化配置表读取（Excel/CSV/TSV/SQLite → 文本，read_table；只读、带 DoS 上限；MCP 暴露）
  path_align.py         索引路径 ↔ 仓库相对路径词法对齐（拒越界；mount_root 默认空）
  codegraph_client.py   codegraph-server 客户端封装（休眠：仅测试用，独占写入 tripwire 守护，绝不进常驻服务路径）
  perf.py               结构化耗时日志
  bootstrap.sh          EC2 user-data：装依赖 / 解包仓库到本地 /data/repo / 快照 stamp 重解压 / systemd build→bridge
  tests/                pytest（由 scripts/test.sh 调用）
infra/                  基础设施即代码（MVP 先 agentcore toolkit / boto3，渐进 CDK 化）
  README.md             IaC 分工：CDK 管稳定层 / deploy-all.sh 用 boto3 配 AgentCore Runtime
  monitoring/           监控（CloudWatch 侧；scripts/boto3，非 CDK stack）
    queries/metric-filters/a-class-metrics.json  A 类指标口径单一事实源（计数/分位/分布 → metric-filter）
    queries/metric-filters/alarm-metrics.json    告警专用稠密 filter（每 card_health kind 一条，defaultValue:0）
    queries/insights/*.logsinsights              B 类去重/留存的 Insights 查询（DAU 等，配定时预聚合 Lambda）
    lambda/dau_preaggregate.py                   B 类 DAU 预聚合 Lambda（每日 StartQuery→PutMetricData，纯 stdlib+boto3）
    dashboard.product.json / dashboard.sre.json  看板模板（${REGION}/${NAMESPACE} 占位；产品用量 / SRE 健康两页）
  (p2) lib/             runtime / codegraph(index-service) / gateway 各 stack
config/                 配置驱动：i18n.json（卡片 / 告警 / 错误文案）、alarm-thresholds.json（告警阈值，运维可调）、projects.example.json（项目路由 schema 模板；真实配置在 .local/projects.json，部署相关、gitignore）
scripts/                运维生命周期
  check-invariants.sh   快速结构 lint（AGENTS / CLAUDE / structure / 双语配对 / 顶层目录存在性）
  lib/                  common.sh（格式化 + 依赖检查）、env-utils.sh（.env / deploy-config 共享 helper）、render_metric_filters.py（指标定义→put-metric-filter 计划）、render_dashboard.py（看板模板渲染 + 禁 type:log 校验）、render_alarms.py（阈值→put-metric-alarm 计划）
  apply-metric-filters.sh  把 infra/monitoring 的指标定义应用到 CloudWatch（幂等 upsert；--defs 切 A 类/告警；--dry-run）
  apply-dashboards.sh   渲染看板模板并 put-dashboard（幂等；--dry-run；读 metric-filters 同源 namespace）
  apply-alarms.sh       建 SNS topic + 从 config/alarm-thresholds.json 建 CloudWatch 告警（幂等；订阅需手动确认）
  apply-dau-lambda.sh   部署 B 类 DAU 预聚合 Lambda + 每日 EventBridge 调度（角色/打包/触发，幂等；--dry-run）
  test.sh               单一分层测试入口（离线默认 / --full）
  check-versions.sh     版本钉死防漂移守卫（base digest / requirements pin / Node / claude-code npm）
  install.sh            交互式一键安装（查依赖→飞书凭证→配置→确认→调 deploy-all；重跑预填）
  deploy-all.sh         一键部署 canonical（artifacts→IAM→network→index-service→镜像→Runtime→gateway；幂等）
  lib/provision_*.sh + deploy_runtime.py + wait_index_health.sh  deploy-all.sh 的各阶段实现
  lib/resolve_repo.sh   --repo 多来源解析（本地 / git URL / s3://）→ 统一为本地目录
  lib/activate_gateway.sh  经 SSM 写 /etc/bot-gateway.env + 启动 bot-gateway.service（gateway 与索引同主机）
  lib/stop_gateway.sh   经 SSM 停旧实例 gateway（蓝绿换实例 break-before-make，防双网关抢飞书长连接）
  ⚠️ deploy.sh          已废弃兼容垫片（转发到 deploy-all.sh）
  (p2) ops.sh           运维工具（status / logs / reindex）
  teardown.sh           有序销毁 + 保留资源清单
docs/
  README.md             文档总索引（按受众分类的入口地图）
  structure_zh.md       本文件（权威目录树，双语配对）
  structure_en.md       英文对照
  runbook.md            部署 / 连飞书 / 运维 / 排错（中性名，不参与双语配对）
  design/               设计权威依据（仅中文，暂不翻译）
    README.md                   目录说明 + 与架构 / 不变量文档的关系
    requirements_zh.md          需求与方案评审纪要（导入）
    architecture-overview_zh.md POC 架构方案（导入）
    agent-container_zh.md       agent-container 组件实现契约
  agent/                AI 面向文档
    architecture.md     工作原理：一次提问如何在系统里流转
    invariants.md       源 → 生成物映射 + 改 X 必改 Y 的耦合（7 条不变量）
    playbooks.md        有序变更配方（7 个配方）
    *-spike.md          调研记录（cardkit 流式 / 索引性能 / 存储选型 / 性能对比 / 模板）
.local/                 （已 gitignore）账号特定部署状态：deploy-config、projects.json（项目路由）、deploy-output.md
```

标注 `(p1)` / `(p2)` 的条目为后续阶段产出，当前仅占位或尚未创建；未标注者均已落地。
