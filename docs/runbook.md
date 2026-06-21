# 部署与运维手册（runbook）

从零部署 source-truth、接入飞书并完成日常运维的指引。工作原理见
[`agent/architecture.md`](agent/architecture.md)；本文只讲**怎么做**。

整套系统分为两部分：

- **后端**：S3 产物 → IAM → 网络 → index-service(EC2) → 镜像(ECR) → AgentCore Runtime。
- **bot-gateway**：飞书长连接网关，把群里的 @ 消息路由到后端，再把答案流式回填成卡片。**网关与索引服务同主机**
  （index-service 那台 EC2 上的第二个 systemd 服务），由部署脚本一并拉起。

> **两种部署方式**：
> - **推荐（客户环境）**：`./scripts/install.sh` —— 交互式，询问区域 / 代码仓 / 飞书凭证，
>   把凭证写进 Secrets Manager，然后端到端启动后端 **+ 网关**。见第二节。
> - **手动 / 进阶**：`./scripts/deploy-all.sh` 直接传参（CI、可复现、可跳过某阶段）。见 [附录 A](#附录-a手动-deploy-allsh)。
>
> 两者都**幂等**：失败后重跑会继续未完成部分。`install.sh` 重跑会预填上次的答案。

---

## 一、前置条件（一次性）

1. **AWS 账号 + 目标区域**：区域须支持 AgentCore（如 `ap-northeast-1` 东京）。本机配好可部署的 AWS 凭证。
2. **Bedrock 模型访问**：在 Bedrock 控制台 → Model access 开通目标模型（默认 `global.anthropic.claude-opus-4-8`）。
   跨区域注意：`global.*` 推理档只在部分区域承载，不支持的区域改用区域级档（`apac.*` / `us.*` / `eu.*`）；
   `deploy-all.sh` 的 preflight 会就此 WARN 并给出可操作提示。
3. **目标代码仓**：要被问答的游戏代码仓，可以是以下任一来源（index-service 会快照、建索引）：
   - 本地路径：`/path/to/your-game-repo`
   - git 地址：`https://github.com/org/repo.git`、`https://gitlab.com/org/repo.git`、`git@host:org/repo.git`
     （可选 `--repo-ref <分支/标签/提交>`；git 源需本机有 `git` 与对私有仓的访问凭证）
   - S3：`s3://bucket/code.tar.gz`（tarball）或 `s3://bucket/prefix/`（前缀同步）
4. **飞书应用**（见第三节，可与部署并行准备）。

---

## 二、一键安装（交互式，推荐）

先准备好飞书应用（第三节），拿到 `App ID` / `App Secret` / 机器人 `open_id`，然后：

```bash
./scripts/install.sh
```

它会：

1. **查依赖**：`aws` / `python3` / `docker` / `git`，并校验 AWS 凭证可用；
2. **问配置**：区域、模型、**索引主机机型与磁盘**（见下表）、代码仓来源（本地 / git / s3）。重跑沿用上次答案；
3. **收飞书凭证**：`App Secret` 输入不回显；把 `{app_id, app_secret, bot_open_id}` 写进 **Secrets Manager**
   （密钥名默认 `source-truth/feishu-app`，凭证不落盘、不进仓库）；
4. **确认**清单后，调用 `deploy-all.sh` 端到端启动后端 **+ 网关**。

索引主机是整套系统唯一一台 EC2（同机跑 codegraph 索引 + bridge + bot-gateway，全 ARM）。codegraph 索引
吃内存、随仓库增大而增长，按仓库规模选机型；磁盘存放仓库副本、`graph.db` 与 tarball，按仓库体积选容量：

| 机型 | vCPU / 内存 | 适用 |
|---|---|---|
| `t4g.large`（默认） | 2C / 8G | 小中仓，突发型省钱 |
| `t4g.xlarge` | 4C / 16G | 中大仓 |
| `m7g.large` | 2C / 8G | 内存型，持续负载更稳 |
| `m7g.xlarge` | 4C / 16G | 大仓·稳定 |
| `m7g.2xlarge` | 8C / 32G | 超大仓 / 多仓 |

磁盘默认 30 GiB，可选 50 / 100 / 200 GiB 或自定义容量。对应 `deploy-all.sh` 的
`--instance-type` / `--root-volume-gb`。

成功后应看到：

- 后端各阶段完成，最后 **Phase 6** 打印 `bot-gateway is active`，整体 `deploy-all complete`；
- 状态写进 `.local/deploy-config`（含 `AGENT_RUNTIME_ARN`、`INDEX_SERVICE_IP`、`FEISHU_SECRET_ID` 等）；
- 直接按第五节验证即可（网关已在 index 主机上以 `bot-gateway.service` 长驻）。

> 无人值守 / CI：`./scripts/install.sh --yes` 接受所有预填值（首次仍需已存在的飞书密钥）。

---

## 三、接入飞书（connect 清单）

在[飞书开放平台](https://open.feishu.cn)创建并配置应用：

1. **创建企业自建应用**，记下 `App ID`（`cli_...`）和 `App Secret`。
2. **权限（scope）**：开通发消息 / 读消息相关权限（`im:message`、`im:message:send_as_bot`），以及卡片相关权限。
3. **事件订阅**：启用**长连接**模式（不是 webhook）。订阅这两个事件：
   - `im.message.receive_v1`（收到群消息）
   - `card.action.trigger`（卡片按钮点击：停止 / 追问 / 澄清）
4. **机器人**：启用机器人能力；把它的 `open_id`（`ou_...`）记为 `FEISHU_BOT_OPEN_ID`（用于判断群里 @ 的对象）。
5. **存密钥**：`App Secret` 属敏感信息，**绝不提交进仓库**。`install.sh` 会替你把 `App ID` / `App Secret` /
   机器人 `open_id` 写进 **Secrets Manager**（密钥名 `source-truth/feishu-app`）——按提示粘贴即可，
   无需手动建密钥。网关运行时由 `run.sh` 从 Secrets Manager 取出注入进程环境（不落盘）。

   > 若手动管理（不走 install.sh）：自行建一个 Secrets Manager 密钥，内容为 JSON
   > `{"app_id":"...","app_secret":"...","bot_open_id":"..."}`，密钥名以 `source-truth/` 开头（IAM 已按此前缀授权），
   > 然后部署时设 `FEISHU_SECRET_ID=<密钥名>` 让 gateway 阶段激活。

6. 把机器人**拉进目标群**，记下群 `chat_id`（`oc_...`）。

---

## 四、网关运行位置

走 `install.sh`（或 `deploy-all.sh` 的 gateway 阶段）后，网关已作为 **`bot-gateway.service`** 在
index-service 那台 EC2 上长驻运行——无需单独启动进程。常用运维：

```bash
# 查看网关状态 / 日志（经 SSM 进实例）：
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
#   sudo systemctl status bot-gateway
#   sudo journalctl -u bot-gateway -f     # 期望日志：sdk_wsclient_started → sdk_wsclient_connected
```

> **只能有一个网关实例连接同一个飞书应用**：飞书长连接是集群模式，每个事件只投给一个 client，
> 同一 app 运行两个网关（例如本地又启动一个）会互相争抢事件、表现异常。本地调试时先停掉实例上的服务。

本地启动网关（开发调试用）见 [附录 B](#附录-b本地手动启动网关开发调试)。

---

## 五、验证（端到端冒烟）

1. **后端健康**（在 index-service 实例内，经 SSM）：

   ```bash
   aws ssm send-command --region <r> --instance-ids <INDEX_SERVICE_INSTANCE> \
     --document-name AWS-RunShellScript \
     --parameters 'commands=["curl -fs -w %{http_code} http://127.0.0.1:8080/health"]'
   # 期望 200 + healthy:true
   ```

2. **在群里 @ 机器人**并提问（如「装备耐久怎么算？」）。预期：
   - 几秒内出现一张卡片，标题带实时计时（思考→分析→完成）；
   - 结论先行、用业务语言表述，底部「供研发复核」折叠区列 `文件:行号` 出处；
   - 可点「继续追问」或直接回复卡片，延续上文继续提问。
   - 首次冷启动（新 microVM）会慢一些（含 MCP 注册），属正常。

---

## 六、日常运维（day-2）

> 运维聚合命令 `ops.sh status` 尚未实现（规划中，p2）；当前用下面的手动命令。

**代码更新了，刷新索引**（蓝绿替换 index-service 实例，不动网关/runtime）：

```bash
./scripts/deploy-all.sh --region <r> --repo /path/to/repo --refresh-index
```

**只重部署 runtime**（改了 agent 镜像 / system prompt 后）：重跑 `deploy-all.sh`（镜像与 runtime 阶段幂等）。
注意热 microVM 会使用旧镜像约 15 分钟，直到被回收。

**调整暖 VM 存活时长（追问命中率 vs 成本）**：`deploy-all.sh --idle-timeout <秒>`（默认 900，即 15 分钟，
范围 60–28800）。该参数同时设置 AgentCore 的 `idleRuntimeSessionTimeout` 与网关的 session 复用 TTL，二者自动对齐。
成本权衡：AgentCore 空闲时 CPU 免费、内存照常计费，因此调大会延长暖 VM 存活、提高追问命中暖机的概率，
但需承担这段空闲期的内存开销；多数会话在一次问答后即结束，故默认 15 分钟。追问密集的场景可调大，需要压缩成本则调小。
详见 [`agent/architecture.md`](agent/architecture.md)「Runtime 调参与成本权衡」。

**查看网关日志**（网关是 index 主机上的 `bot-gateway.service`，结构化 JSON 日志进 journald）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：sudo journalctl -u bot-gateway -f
```

关键事件（网关侧）：`invoke_start`（开始调用 runtime）、`card_sent`（卡片已发出）、
`card_closed`（一次问答结束）、`reply_context_replayed`（追问带上上文）、
`card_write_dropped` / `finalize_error`（卡片写失败）、`invoke_http_error`（后端非 200）。
关键事件（agent microVM 侧，同 traceId）：`agent_run_start`（开跑，记 promptChars / repos / model）、
`tool_call`（工具调用开始）、`tool_latency`（每次工具调用耗时）。

**按 traceId 查全链路（网关 + agent microVM 合并时间线）**：一次问答横跨两个 log group
（网关 `/source-truth/bot-gateway` + agent 的 `/aws/bedrock-agentcore/runtimes/<runtime>-DEFAULT`），
二者用同一 `traceId` 串联。一条命令把两侧查询 + 合并都包好——只需输入 traceId（区域、两个 log group、
时间窗、查询、排序全自动）：

```bash
./scripts/trace.sh st-731080073903468d83a0fbe1249b5dc3   # traceId 取自卡片底部或 answer_* 日志行
#   --since-hours N（默认 6）扩大回溯窗；--raw 不合并、两侧原样输出
```

输出按时间合并、标 `GW`/`AGT` 来源，并自动抽取关键字段（status / detail / error / reason / tool /
latencyMs / ttfbMs / numToolCalls / toolErrors / turnCount / evidenceCitationCount / num_turns /
cache_read）。后端 403/超时这类「卡片失败但不知卡在哪一段」的问题，可定位是网关、invoke、还是 agent 侧。

**查看 index-service 日志**（同一台实例）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：journalctl -u index-bridge -f   （建图日志：index-build 单元）
```

**重启网关**（实例内）：`sudo systemctl restart bot-gateway`。改了飞书凭证后，重跑
`install.sh`（或 deploy 的 gateway 阶段）会重写 `/etc/bot-gateway.env` 并重启服务。

**监控：指标 / 看板 / 告警**（CloudWatch 侧，部署期身份需 `logs:PutMetricFilter` /
`cloudwatch:PutDashboard,PutMetricAlarm` / `sns:CreateTopic`；不是运行时角色）。

> **`deploy-all.sh` 的 Phase 8（monitoring）已自动执行这四步**（best-effort：网关日志组尚未创建时只告警，
> 不中断部署；重跑 deploy 即可补齐）。**正常一键部署无需手动执行**；下面的手动命令用于：单独刷新看板/阈值、
> deploy 时 monitoring 被 `--skip monitoring`、或首次部署网关刚启动且尚未写入第一行日志（log group 未生成）后的补跑。

幂等、可重跑、换区域只改 `--region`。**顺序固定：先指标 filter，再看板/告警**（告警引用 metric，metric 由 filter 产出）：

```bash
# 1. A 类指标 filter（看板读的计数/分位/分布）
./scripts/apply-metric-filters.sh --region <r>            # --dry-run 先看计划
# 2. 看板（三页：产品用量 + SRE 健康（顶部告警）+ 分项目拆分）
./scripts/apply-dashboards.sh --region <r>
# 3. 告警 + SNS（apply-alarms 会先自动应用告警专用 dense filter，再建 alarm——顺序内建，避免引用空指标）
./scripts/apply-alarms.sh --region <r>
#    告警阈值在 config/alarm-thresholds.json（运维可调，改完重跑本步即可）。
#    订阅是手动一步（邮件需点确认链接）：
#    aws sns subscribe --region <r> --topic-arn <脚本打印的 ARN> --protocol email --notification-endpoint you@example.com
# 4. DAU 预聚合 Lambda + 每日调度（产品看板的「日活」widget 读它产出的 SourceTruth/Gateway DAU 指标）
./scripts/apply-dau-lambda.sh --region <r>
#    每日运行一次，查询前一天的去重活跃用户数。不运行这步则看板 DAU widget 持续为空（其余 widget 不受影响）。
```

关键告警：`ToolcallLeakDetected`（工具调用指令文本漏进卡片）、`FinalizeFailed`（卡片未正常结束、停在「分析中」）、
`AnswerFailedBurst`（回答失败率激增）、`LogPipelineStalled`（日志管道存活兜底——监控网关每 60s 的
`gateway_heartbeat` 心跳；只有心跳停止，即管道中断或网关异常时才告警，空闲夜晚仍发送心跳，不误报）。

**拆除整套资源（停止计费）**：试用完、或某次部署中途失败留下计费资源（NAT ~$32/月、EIP、EC2）时，一条命令按反依赖顺序清理：

```bash
./scripts/teardown.sh --region <r> --dry-run     # 先看将删除哪些资源，不动资源
./scripts/teardown.sh --region <r>               # 交互确认后删除（输入 yes）
./scripts/teardown.sh --region <r> --include-shared   # 连同 IAM 角色 + S3 桶（账号共享）一起删
```

资源从 `.local/deploy-config` 读、读不到则按 `source-truth-*` tag 发现（所以中途失败的残留也能清理）。
删完会提示一条核对命令确认没有遗留的计费 NAT。破坏性、不可逆。

---

## 七、排错（症状 → 原因 → 处置）

| 症状 | 可能原因 | 处置 |
|------|----------|------|
| 卡片一直「正在分析…」不结束 | 后端流被中断 / finalize 异常 | 查看网关日志 `finalize_error` / `card_closed failed:true`；偶发则重问；持续则查 runtime/index 健康 |
| 答案里出现原始 `<invoke>` XML 等标记 | 冷 microVM 首次 invoke 时 MCP 工具未注册（冷启动竞速） | 网关会自动重试一次；暖机后消失。查看日志 `num_turns`/`cache_read` 确认是否冷启动 |
| 机器人在群里**完全无响应** | 网关未启动 / 未 @ 到机器人 / 同一 app 运行了两个网关争抢事件 | 进实例 `systemctl status bot-gateway` 确认 active + 日志 `sdk_wsclient_connected`；确认 @ 的是 `FEISHU_BOT_OPEN_ID`；停止多余网关，只保留一个 |
| 网关 `condition failed` 未启动 | `/etc/bot-gateway.env` 尚未写入（runtime 未就绪 / gateway 阶段被跳过） | 重跑 `install.sh` 或 `deploy-all.sh`（不跳 gateway）；确认 `FEISHU_SECRET_ID` 已配 |
| 卡片回「查询失败」/ 日志 `AccessDenied` | Bedrock 模型未在该区域开通 | 到 Bedrock 控制台开通模型访问；跨区域改用区域级推理档（见前置条件 2） |
| 部署在 index-service 阶段超时 | 全新账号 NAT 路由未收敛 / 实例仍在冷启动建索引 | 多等一轮（bootstrap 对网络操作有重试）；查看 `/var/log/` 与 `journalctl -u index-build` |
| `/health` 长期非 200 | 索引损坏 / graph.db 空 / worker 反复重启 | 进实例查看 index-bridge 日志；必要时 `--refresh-index` 重建（蓝绿，不破坏运行中实例） |
| 重新部署后行为仍是旧版本 | 热 microVM 仍持旧镜像（约 15 分钟）/ 网关未重启 | 等待热 VM 回收；重启网关确保运行新代码 |

> 独占写入约束：index-service 的 graph.db 同一时刻只能有一个进程写入，并发写会导致 0 节点损坏。
> 服务层已用 flock + 进程内锁 + orphan reaper 守护；**不要**在实例上手动再跑一个 codegraph-server 写同一份图。

---

## 八、边界与安全（务必知道）

- **只读**：MVP 全程不写代码 / 不提交 / 不运行引擎；答案只基于最新主分支真实代码 + CodeGraph 取证。
- **密钥**：飞书 `App Secret`、`App ID` 等绝不入仓库（gitleaks pre-commit 守）；走环境变量 / Secrets Manager / SSM。
- **越界能力后置**：多分支、设计文档读取、写回、第二引擎等均为 post-MVP，详见
  [`../README.md`](../README.md) 的「MVP 边界」与设计权威依据 [`design/`](design/)。

---

## 附录 A：手动 deploy-all.sh

`install.sh` 是 `deploy-all.sh` 的交互式前端。如需在 CI / 脚本中运行，或精确控制参数，可直接调用：

```bash
# 全新账号 / 新区域可执行、幂等、可重复。失败重跑会继续未完成部分。
./scripts/deploy-all.sh --region ap-northeast-1 --repo <本地路径 | git URL | s3://...> \
  [--repo-ref <分支/标签/提交>] [--model <id>] [--instance-type t4g.large] [--root-volume-gb 30]

# 只打印计划、不动资源：
./scripts/deploy-all.sh --region <r> --repo <src> --dry-run

# 跳过某阶段（可重复）：artifacts|iam|network|index-svc|image|runtime|gateway
./scripts/deploy-all.sh --region <r> --repo <src> --skip gateway
```

gateway 阶段要激活网关，需要 `FEISHU_SECRET_ID`（指向一个 Secrets Manager 密钥，内容为
`{"app_id","app_secret","bot_open_id"}` 的 JSON，密钥名以 `source-truth/` 开头）。`install.sh` 会创建它并持久化到
`.local/deploy-config`；手动运行则自行 `export FEISHU_SECRET_ID=...`，否则 gateway 阶段会跳过（只部署后端）。

## 附录 B：本地手动启动网关（开发调试）

正常部署中，网关运行在 index 主机上（见第四节）。本地调试时可直接运行 TS：

```bash
cd bot-gateway
npm install
export AWS_REGION=ap-northeast-1
export RUNTIME_ARN="$(grep '^AGENT_RUNTIME_ARN=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx            # 不要写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
# 可选：LOG_HASH_SALT、MAX_CONCURRENT_INVOKES（默认 8）、LOCALE（默认 zh）
node_modules/.bin/ts-node --transpile-only src/index.ts
```

> 注意：同一飞书 app 只能有一个网关连接。本地启动前，先停掉 index 主机上的服务
> （`sudo systemctl stop bot-gateway`），否则两个网关会争抢同一批事件。
