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

**目录**

1. [前置条件（一次性）](#一前置条件一次性)
2. [一键安装（交互式，推荐）](#二一键安装交互式推荐)
3. [接入飞书（connect 清单）](#三接入飞书connect-清单)
4. [网关运行位置](#四网关运行位置)
5. [验证（端到端冒烟）](#五验证端到端冒烟)
6. [日常运维（day-2）](#六日常运维day-2)
7. [多项目（一台机器多个机器人）](#七多项目一台机器多个机器人)
8. [排错（症状 → 原因 → 处置）](#八排错症状--原因--处置)
9. [边界与安全（务必知道）](#九边界与安全务必知道)
- [附录 A：手动 deploy-all.sh](#附录-a手动-deploy-allsh)
- [附录 B：本地手动启动网关（开发调试）](#附录-b本地手动启动网关开发调试)

---

## 一、前置条件（一次性）

1. **AWS 账号 + 目标区域**：区域须支持 AgentCore（如 `ap-northeast-1` 东京）。本机配好可部署的 AWS 凭证。
2. **部署机（Linux 或 macOS）**：装好 `aws` CLI v2、`python3`、`git`，以及 **Docker 且守护进程在运行**
   （Phase 4 要构建 ARM64 镜像；只装不启动会在依赖检查就被拦下，提示 `docker info` 验证）。私有仓部署还需
   `gh` 并已 `gh auth login`（用于克隆仓库 + 拉取 `codegraph-server`）。`codegraph-server` 二进制无需手动准备——
   本地与 S3 都没有时，部署会从本仓 Release 自动下载（私有仓经 `gh`，公开仓经直链）。
3. **Bedrock 模型访问**：确保部署身份有 `bedrock:InvokeModel`（AWS 已不再需要逐模型在控制台「Model access」开通）。
   模型推理档由部署按 `--region` 自动解析，无需手填——部署调 `bedrock list-inference-profiles` 查该区域实际提供的档、
   自动挑最优（地域档 `us.`/`eu.`/`jp.`/`au.` 优先，没有就用 `global.`；如默认模型在东京解析为 `jp.…`、在新加坡保留 `global.…`）。
   仅当查不到匹配档时 preflight 会 WARN 并列出该区域可用的档。
4. **目标代码仓**：要被问答的游戏代码仓，**只支持 git 地址**（index-service clone 到本地、定时 `git pull` 保持新鲜）：
   `https://github.com/org/repo.git`、`https://gitlab.com/org/repo.git`、`git@host:org/repo.git`，可选指定分支 / 标签 / 提交。私有仓需要本机有 `git` 与一份只读访问凭证。
5. **飞书应用**（见第三节，可与部署并行准备）。

---

## 二、一键安装（交互式，推荐）

先准备好飞书应用（第三节），拿到 `App ID` / `App Secret` / 机器人 `open_id`。

**一行命令拉起**（克隆仓库后进入交互式安装）：

```bash
# 仓库公开时
bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)

# 仓库私有时（先 gh auth login 一次，再用 gh 取脚本，带认证）
bash <(gh api repos/ddpie/source-truth/contents/scripts/get.sh --jq '.content' | base64 -d)
```

已克隆仓库则直接：

```bash
./scripts/install.sh
```

它是一个交互菜单（键盘上下键选择、回车确认），四个流程见 [第七节 多项目](#七多项目一台机器多个机器人)。
首次部署的典型顺序：

1. **查依赖**：`aws` / `python3` / `docker`（含守护进程在运行）/ `git`，可选 `gh`（私有仓部署需要），并校验 AWS 凭证可用；
2. **选「添加项目」**（底座不存在会自动先建）：填 projectId → 逐个加仓库（**git 地址** + 子目录 + 分支）→
   索引服务端口（即该项目的 `index-bridge-<项目>` 进程监听端口，脚本自动建议）→ 飞书 App 凭证（自动写入
   `source-truth/feishu-<项目>`）→ 首次再给一个只读 git
   凭证（写入全局 `source-truth/git-credentials`，后续项目复用）；
3. 写入 `.local/projects.json` 并部署该项目（底座 + 该项目的 bridge + runtime + gateway）。

> 想先把 AWS 环境拉起来、之后再配 git？选「**初始化环境（不挂项目）**」：只起共享底座，机型/磁盘见下表。

索引主机是整套系统唯一一台 EC2（同机跑 codegraph 索引 + 各项目 bridge + 各项目 bot-gateway，全 ARM）。
codegraph 索引吃内存、随仓库增大而增长，按仓库规模选机型；磁盘存放各仓 git 副本与 `graph.db`，按总体积选容量：

| 机型 | vCPU / 内存 | 适用 |
|---|---|---|
| `t4g.large`（默认） | 2C / 8G | 小中仓，突发型省钱 |
| `t4g.xlarge` | 4C / 16G | 中大仓 |
| `m7g.large` | 2C / 8G | 内存型，持续负载更稳 |
| `m7g.xlarge` | 4C / 16G | 大仓·稳定 |
| `m7g.2xlarge` | 8C / 32G | 超大仓 / 多仓 |

磁盘默认 30 GiB，可选 50 / 100 / 200 GiB 或自定义容量。

**术语表构建上限**（初始化环境时会问一次「术语表构建文件上限」）：术语表把中文业务词对应到代码里
真实出现的英文符号，让策划用中文也能命中英文代码——它在 index 主机后台离线构建（首启会自动装一个
本地 `claude` CLI 作为构建引擎），不在问答路径上。这个上限控制每次构建扫多少文件：

| 选项 | 适用 | 成本量级（一次性） |
|---|---|---|
| `400`（默认） | 日常够用，覆盖高频概念 | 约 $10 量级 |
| `1000` / `4000` | 想要更广 / 大仓深覆盖 | 随文件数线性增长 |
| `0`（不限） | 全量、最高覆盖 | 大仓可达数百美元 |

成本随文件数线性增长（首次全量是一次性，之后只扫代码变更的增量、花费很小）。**纯英文 / 无中文项目
保持默认即可**——术语表会自动为空、零开销、不影响问答。改这个上限需重新初始化主机才生效（见第六节
「改术语表构建上限」），日常无需调整。

> 术语表是**后台异步**构建：部署完成后问答立即可用；大仓首次全量可能要几十分钟，**这段时间问答正常**，
> 只是中文冷僻词可能还没对应上。构建进度/结果在主机日志里（`journalctl` 找 `glossary_gen_done` /
> `glossary_gen_cc_failed`）。构建失败（如 cc 没装上）只让术语表暂时为空，**不影响问答**。

成功后应看到：

- 底座各阶段完成，每个项目打印 `index-bridge-<项目>` 健康 + `bot-gateway@<项目> is active`，整体 `deploy-all complete`；
- 状态写进 `.local/deploy-config`（含每项目 `RUNTIME_ARN_<项目>`、`INDEX_SERVICE_IP` 等）；
- 直接按第五节验证即可（各项目网关已在 index 主机上以 `bot-gateway@<项目>.service` 长驻）。

> 无人值守 / CI：`./scripts/install.sh --yes` 接受所有预填值（首次仍需已存在的飞书密钥）。

---

## 三、接入飞书（connect 清单）

在[飞书开放平台](https://open.feishu.cn)按顺序配置应用（后面的步骤依赖前面的：先有机器人才能开
发消息权限，权限/事件/机器人都配好后才发布生效）：

1. **创建企业自建应用**：「开发者后台」→「创建应用」→「企业自建应用」。建好后在「凭证与基础信息」页
   记下 `App ID`（`cli_...`）和 `App Secret`。
2. **启用机器人**：在「机器人」页打开机器人能力，记下它的 `open_id`（`ou_...`）——即 `FEISHU_BOT_OPEN_ID`
   （用于判断群里 @ 的是不是它）。**先有机器人，下一步的发消息权限才有意义。**
3. **权限（scope）**：在「权限管理」开通以下（少一个，对应功能就静默失效）：
   - `im:message`、`im:message.group_at_msg`：读群里 @ 机器人的消息；
   - `im:message:send_as_bot`：以机器人身份发消息 / 回复 / 加「处理中」表情（调 `im/v1/messages` 及其
     `reactions` 子接口——表情回应由消息收发权限覆盖，无需单独的资源 scope）；
   - **CardKit 卡片**：在「权限管理」搜「卡片」，按 `cardkit/v1/cards` 接口的依赖项勾选；缺它卡片建不出来。
4. **事件订阅**：选**长连接**模式（不是 webhook——本系统是长驻订阅，不暴露公网回调），订阅两个事件：
   - `im.message.receive_v1`：收到群消息；
   - `card.action.trigger`：卡片按钮点击（停止 / 追问 / 澄清）。
5. **创建版本并发布**：第 2–4 步的改动都要发布后才对线上生效（企业内部可走自助审批）。只存草稿不发布，
   机器人不响应。

发布之后，还有两件事（与飞书后台无关，顺序不限）：

- **把机器人拉进目标群**，记下群 `chat_id`（`oc_...`）。
- **凭证交给安装器**：`App Secret` 是敏感信息，**绝不入库**。第二节的 `install.sh`「添加项目」会问
  `App ID` / `App Secret` / 机器人 `open_id`，替你写进 **Secrets Manager**（密钥名按项目区分
  `source-truth/feishu-<projectId>`）；网关启动时由 `run.sh` 取出注入进程环境，不落盘。按提示粘贴即可，无需手建密钥。

  > 手动管理（不走 install.sh）：自建一个 Secrets Manager 密钥，内容为 JSON
  > `{"app_id":"...","app_secret":"...","bot_open_id":"..."}`，名字以 `source-truth/` 开头（IAM 已按此前缀授权），
  > 再填进 `.local/projects.json` 对应项目的 `feishuSecretId`（或部署时设 `FEISHU_SECRET_ID=<密钥名>`）。

---

## 四、网关运行位置

走 `install.sh`（或 `deploy-all.sh` 的 gateway 阶段）后，每个项目的网关都作为 **`bot-gateway@<项目>.service`**
（systemd 模板单元，如 `bot-gateway@mangos.service`）在 index-service 那台 EC2 上长驻运行——无需单独启动进程。
常用运维（把 `<项目>` 换成实际 projectId）：

```bash
# 查看网关状态 / 日志（经 SSM 进实例）：
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
#   sudo systemctl status 'bot-gateway@*'              # 所有项目网关
#   sudo journalctl -u bot-gateway@<项目> -f           # 期望日志：sdk_wsclient_started → sdk_wsclient_connected
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

**代码更新了，刷新索引**：**无需手动操作**。每个仓库按 `refreshIntervalSec`（默认 300 秒）由 systemd timer
定时 `git pull`，常驻 codegraph 的 file-watcher 在几秒内增量重建该仓的内存图——不重启、无中断。改频率就改
`.local/projects.json` 里该仓/该项目的 `refreshIntervalSec`，再「重新部署该项目」。`--refresh-index` 现在只
用于**换索引服务自身的代码/机型**（蓝绿换整机），不再用于刷新业务代码。多项目部署见第七节。

**改术语表构建上限（`GLOSSARY_MAX_FILES`）**：该值在主机首次启动时写入 `/etc/index-service.env`，**对已在
运行的主机改了重跑不会生效**（复用实例不重写该文件）。要让新上限生效，用 `--refresh-index` 蓝绿换整机；或
临时进实例手改 `/etc/index-service.env` 的 `GLOSSARY_MAX_FILES`，等下一轮刷新构建按新值跑。日常无需调整。

**只重部署 runtime**（改了 agent 镜像 / system prompt 后）：重跑 `deploy-all.sh`（镜像与 runtime 阶段幂等）。
注意仍存活的 microVM 会使用旧镜像约 15 分钟，直到被回收。

**调整 microVM 存活时长（追问命中率 vs 成本）**：`deploy-all.sh --idle-timeout <秒>`（默认 900，即 15 分钟，
范围 60–28800）。该参数同时设置 AgentCore 的 `idleRuntimeSessionTimeout` 与网关的 session 复用 TTL，二者自动对齐。
AgentCore 空闲时 CPU 免费、内存照常计费。调大延长 microVM 存活、提高追问命中存活实例的概率，代价是多付这段空闲期的内存。
多数会话一次问答就结束，所以默认 15 分钟；追问密集（如客服式高频问答）可调大，要省钱则调小。
详见 [`agent/architecture.md`](agent/architecture.md)「Runtime 调参与成本权衡」。

**查看网关日志**（每项目一个 `bot-gateway@<项目>.service`，结构化 JSON 日志进 journald）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：sudo journalctl -u bot-gateway@<项目> -f
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
# 实例内：journalctl -u index-bridge-<项目> -f   （建图日志：index-build@<仓> 单元）
```

**重启网关**（实例内）：`sudo systemctl restart bot-gateway@<项目>`。改了飞书凭证后，重跑
`install.sh`（或 deploy 的 gateway 阶段）会重写 `/etc/bot-gateway-<项目>.env` 并重启服务。

**监控：指标 / 看板 / 告警**（CloudWatch 侧，部署期身份需 `logs:PutMetricFilter` /
`cloudwatch:PutDashboard,PutMetricAlarm` / `sns:CreateTopic`；不是运行时角色）。

> **`deploy-all.sh` 的 Phase 7（monitoring）已自动执行这四步**（best-effort：网关日志组尚未创建时只告警，
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
`AnswerFailedBurst`（回答失败率激增）、`LogPipelineStalled`（网关每 60 秒发一次 `gateway_heartbeat` 心跳日志，
心跳断了才告警——日志管道中断或网关异常；空闲夜里仍有心跳，不会误报）。

**拆除整套资源（停止计费）**：试用完、或某次部署中途失败留下计费资源（NAT ~$32/月、EIP、EC2）时，一条命令按反依赖顺序清理：

```bash
./scripts/teardown.sh --region <r> --dry-run     # 先看将删除哪些资源，不动资源
./scripts/teardown.sh --region <r>               # 交互确认后删除（输入 yes）
./scripts/teardown.sh --region <r> --include-shared   # 连同 IAM 角色 + S3 桶（账号共享）一起删
```

资源从 `.local/deploy-config` 读、读不到则按 `source-truth-*` tag 发现（所以中途失败的残留也能清理）。
删完会提示一条核对命令确认没有遗留的计费 NAT。破坏性、不可逆。

---

## 七、多项目（一台机器多个机器人）

一台索引主机可承载多个互相隔离的项目：机器人（独立飞书 App）⟷ 项目 一一对应，项目 ⟷ 仓库 一对多。
项目间逻辑隔离（各自进程 + 端口 + 服务端 scope，A 档），同团队互信项目共机即可；互不信任的项目仍应分机器。

**唯一声明处**是 `.local/projects.json`（不入库）。每个项目一条：`port`（该项目 bridge 端口，全机唯一）、
`feishuSecretId`（由「添加项目」自动生成，**勿手填**）、`repos`（每个仓 `{subdir, git, ref?,
refreshIntervalSec?}`，**git-only**）。顶层 `refreshIntervalSec` 是全局默认刷新间隔。

全部操作走 `./scripts/install.sh` 的箭头菜单：

- **初始化环境（不挂项目）**：只起共享底座（VPC/NAT/EC2/镜像），不挂任何项目。适合先把 AWS 环境拉起来、
  之后再凭 git 地址与凭证挂项目（即「先部署环境、后配置 git」）。
- **添加项目**：交互填 projectId → 逐个加仓库（git 地址 + 子目录 + 分支）→ 索引服务端口（自动建议下一个未用值）
  → 飞书 App 凭证（自动写入 `source-truth/feishu-<项目>`）→ 首次还会收一个**只读 git 凭证**写入全局
  `source-truth/git-credentials`（后续项目复用）。随后写入清单并部署该项目（其余项目不受影响）。
- **重新部署现有项目**：改了某项目的仓库集合 / 端口 / 刷新间隔后，选它重跑（幂等）。
- **删除项目**（破坏性，需打项目名二次确认）：停并删除该项目的 bridge/gateway/runtime 与代码副本、从清单移除；
  飞书密钥默认保留（会单独问是否删），**全局 git 凭证绝不删**；其余项目不受影响。

**代码来源只支持 git（R1）**：本地目录 / S3 不再支持（它们没有可定时 pull 的上游）。私有仓需要那一份只读
凭证（GitHub/GitLab PAT 或 deploy key，所有仓共用一份）。索引主机在私有子网经 NAT 出网 clone/pull。

排查某项目：主机上单元名都带项目/仓库标识——`index-bridge-<项目>.service`、`bot-gateway@<项目>.service`、
`index-refresh-<仓库>.timer`、`index-build@<仓库>.service`；日志 `journalctl -u <单元>`。各项目 bridge 在
各自端口（`curl 127.0.0.1:<port>/health`）。

> 直接用 `deploy-all.sh`（不走 install.sh）：它会起底座 + 遍历 `.local/projects.json` 部署每个项目；
> `--skip-projects` 只起底座。但**飞书 / git 凭证仍需先存在于 Secrets Manager**——这些只有 install.sh 的
> 「添加项目」会交互创建，所以新项目首次务必走 install.sh。

---

## 八、排错（症状 → 原因 → 处置）

| 症状 | 可能原因 | 处置 |
|------|----------|------|
| 卡片一直「正在分析…」不结束 | 后端流被中断 / finalize 异常 | 查看网关日志 `finalize_error` / `card_closed failed:true`；偶发则重问；持续则查 runtime/index 健康 |
| 卡片里冒出奇怪的 `<invoke>` 代码标记 | 冷启动那次问答，底层取证工具还没就绪 agent 就提前回了 | 网关会自动重试一次，暖机后消失。查日志 `num_turns`/`cache_read` 确认是否冷启动 |
| 机器人在群里**完全无响应** | 网关未启动 / 未 @ 到机器人 / 同一 app 运行了两个网关争抢事件 | 进实例 `systemctl status 'bot-gateway@*'` 确认 active + 日志 `sdk_wsclient_connected`；确认 @ 的是 `FEISHU_BOT_OPEN_ID`；停止多余网关，只保留一个 |
| 网关 `condition failed` 未启动 | `/etc/bot-gateway-<项目>.env` 尚未写入（runtime 未就绪 / gateway 阶段被跳过） | 重跑 `install.sh` 或 `deploy-all.sh`（不跳 gateway）；确认 `FEISHU_SECRET_ID` 已配 |
| 卡片回「查询失败」/ 日志 `AccessDenied` | 部署身份缺 `bedrock:InvokeModel`，或该模型在此区域无可用推理档 | 给部署身份补 `bedrock:InvokeModel`；模型档由部署按区域自动解析，查不到时 preflight 会列出该区域可用的档（见前置条件 3） |
| 部署在 index-service 阶段超时 | 全新账号 NAT 路由未收敛 / 实例仍在冷启动建索引 | 多等一轮（bootstrap 对网络操作有重试）；查看 `/var/log/` 与 `journalctl -u 'index-build@*'` |
| `/health` 长期非 200 | 索引损坏 / graph.db 空 / worker 反复重启 | 进实例查看 index-bridge-<项目> 日志；必要时 `--refresh-index` 重建（蓝绿，不破坏运行中实例） |
| 重新部署后行为仍是旧版本 | 仍存活的 microVM 持旧镜像（约 15 分钟）/ 网关未重启 | 等待该 microVM 回收；重启网关确保运行新代码 |
| 中文问答没用上项目专属命名 / 术语表像是空的 | 术语表后台构建未完成或失败（cc 没装上 / Bedrock 调不通或无权限） | 进实例看 `journalctl` 与 `/var/log/glossary-build-*`，找 `glossary_gen_done`（成功）/ `glossary_gen_cc_failed`（构建失败）；不影响问答，问答会自动退回常规检索 |

> 独占写入约束：index-service 的 graph.db 同一时刻只能有一个进程写入，并发写会导致 0 节点损坏。
> 服务层已用 flock + 进程内锁 + orphan reaper 守护；**不要**在实例上手动再跑一个 codegraph-server 写同一份图。

---

## 九、边界与安全（务必知道）

- **只读**：MVP 全程不写代码 / 不提交 / 不运行引擎；答案只基于最新主分支真实代码 + CodeGraph 取证。
- **密钥**：飞书 `App Secret`、`App ID` 等绝不入仓库（gitleaks pre-commit 守）；走环境变量 / Secrets Manager / SSM。
- **越界能力后置**：多分支、设计文档读取、写回、第二引擎等均为 post-MVP，详见
  [`../README.md`](../README.md) 的「MVP 边界」与设计权威依据 [`design/`](design/)。

---

## 附录 A：手动 deploy-all.sh

`install.sh` 是 `deploy-all.sh` 的交互式前端。代码仓库**不再走命令行**——它们在 `.local/projects.json` 里声明
（git-only），由 deploy-all 起底座后遍历部署。直接调用：

```bash
# 起底座 + 部署 .local/projects.json 里的每个项目。幂等、可重复、新账号可跑。
./scripts/deploy-all.sh --region ap-northeast-1 [--instance-type t4g.large] [--root-volume-gb 30] [--model <默认id>]

# 只起共享底座、不挂项目（init-env）：
./scripts/deploy-all.sh --region <r> --skip-projects

# 只打印计划、不动资源：
./scripts/deploy-all.sh --region <r> --dry-run

# 跳过某阶段（可重复）：artifacts|iam|network|index-svc|image|runtime|gateway|monitoring
# 注意 runtime 与 gateway 同属「按项目部署」一个阶段，只有两个都跳才会跳过它（单跳其一无效）。
./scripts/deploy-all.sh --region <r> --skip monitoring

# 部署/重部署单个项目（底座须已就绪）：
./scripts/deploy_project.sh <r> <projectId>   # 即 scripts/lib/deploy_project.sh
```

**前提**：`.local/projects.json` 里每个项目的 `feishuSecretId` 指向的飞书密钥、以及全局
`source-truth/git-credentials`（私有仓只读凭证）**必须已存在于 Secrets Manager**。这些只有
`install.sh` 的「添加项目」会交互创建，所以**新项目首次务必走 install.sh**；deploy-all 只消费它们。

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

> 注意：同一飞书 app 只能有一个网关连接。本地启动前，先停掉 index 主机上对应项目的服务
> （`sudo systemctl stop bot-gateway@<项目>`），否则两个网关会争抢同一批事件。
