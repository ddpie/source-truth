# 部署与运维手册（runbook）

从零把 source-truth 跑起来、连上飞书、日常运维的一条龙指引。工作原理见
[`agent/architecture.md`](agent/architecture.md)；这里只讲**怎么做**。

整套系统有两半：

- **后端**：S3 产物 → IAM → 网络 → index-service(EC2) → 镜像(ECR) → AgentCore Runtime。
- **bot-gateway**：飞书长连接网关，把群里的 @ 消息路由到后端，再把答案流式回填成卡片。**网关与索引服务同主机**
  （index-service 那台 EC2 上的第二个 systemd 服务），由部署脚本一并拉起。

> **两种部署方式**：
> - **推荐（客户环境）**：`./scripts/install.sh` —— 交互式，问几个问题（区域 / 代码仓 / 飞书凭证），
>   把凭证写进 Secrets Manager，然后端到端拉起后端 **+ 网关**。见第二节。
> - **手动 / 进阶**：`./scripts/deploy-all.sh` 直接传参（CI、可复现、可单跳某阶段）。见 [附录 A](#附录-a手动-deploy-allsh)。
>
> 两者都**幂等**：失败重跑会续上未完成的部分。`install.sh` 重跑会预填上次的答案。

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
2. **问配置**（带默认值，回车即接受；重跑预填上次答案）：区域、**代码仓来源**（本地 / git / s3）、模型、索引机型；
3. **收飞书凭证**：`App Secret` 输入不回显；把 `{app_id, app_secret, bot_open_id}` 写进 **Secrets Manager**
   （密钥名默认 `source-truth/feishu-app`，凭证不落盘、不进仓库）；
4. **确认**清单后，调用 `deploy-all.sh` 端到端拉起后端 **+ 网关**。

成功的样子：

- 后端各阶段过完，最后 **Phase 6** 打印 `bot-gateway is active`，整体 `deploy-all complete`；
- 状态写进 `.local/deploy-config`（含 `AGENT_RUNTIME_ARN`、`INDEX_SERVICE_IP`、`FEISHU_SECRET_ID` 等）；
- 直接进第五节验证即可（网关已在 index 主机上以 `bot-gateway.service` 长驻）。

> 无人值守 / CI：`./scripts/install.sh --yes` 接受所有预填值（首次仍需已存在的飞书密钥）。

---

## 三、连飞书（connect 清单）

在[飞书开放平台](https://open.feishu.cn)创建并配置应用：

1. **创建企业自建应用**，记下 `App ID`（`cli_...`）和 `App Secret`。
2. **权限（scope）**：开通发消息 / 读消息相关权限（`im:message`、`im:message:send_as_bot`），以及卡片相关权限。
3. **事件订阅**：启用**长连接**模式（不是 webhook）。订阅这两个事件：
   - `im.message.receive_v1`（收到群消息）
   - `card.action.trigger`（卡片按钮点击：停止 / 追问 / 澄清）
4. **机器人**：启用机器人能力；把它的 `open_id`（`ou_...`）记为 `FEISHU_BOT_OPEN_ID`（群里 @ 谁就靠它判断）。
5. **存密钥**：`App Secret` 属敏感信息，**绝不提交进仓库**。`install.sh` 会替你把 `App ID` / `App Secret` /
   机器人 `open_id` 写进 **Secrets Manager**（密钥名 `source-truth/feishu-app`）——你只需在它提示时粘贴即可，
   无需手动建密钥。网关运行时由 `run.sh` 从 Secrets Manager 取出注入进程环境（不落盘）。

   > 若手动管理（不走 install.sh）：自行建一个 Secrets Manager 密钥，内容为 JSON
   > `{"app_id":"...","app_secret":"...","bot_open_id":"..."}`，密钥名以 `source-truth/` 开头（IAM 已按此前缀授权），
   > 然后部署时设 `FEISHU_SECRET_ID=<密钥名>` 让 gateway 阶段激活。

6. 把机器人**拉进目标群**，记下群 `chat_id`（`oc_...`）。

---

## 四、网关在哪跑

走 `install.sh`（或 `deploy-all.sh` 的 gateway 阶段）后，网关已作为 **`bot-gateway.service`** 在
index-service 那台 EC2 上长驻运行——无需你单独起进程。常用运维：

```bash
# 看网关状态 / 日志（经 SSM 进实例）：
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
#   sudo systemctl status bot-gateway
#   sudo journalctl -u bot-gateway -f     # 期望日志：sdk_wsclient_started → sdk_wsclient_connected
```

> **只能有一个网关实例连同一个飞书应用**：飞书长连接是集群模式，每个事件只投给一个 client，
> 同 app 跑两个网关（如又在本地起了一个）会互相争抢事件、表现异常。本地调试时先停掉实例上的服务。

本地起网关（开发调试用）见 [附录 A](#附录-a本地手动起网关开发调试)。

---

## 五、验证（端到端冒烟）

1. **后端健康**（在 index-service 实例内，经 SSM）：

   ```bash
   aws ssm send-command --region <r> --instance-ids <INDEX_SERVICE_INSTANCE> \
     --document-name AWS-RunShellScript \
     --parameters 'commands=["curl -fs -w %{http_code} http://127.0.0.1:8080/health"]'
   # 期望 200 + healthy:true
   ```

2. **群里 @ 机器人**问一句业务问题（如「装备耐久怎么算？」）。预期：
   - 几秒内出现一张卡片，标题带实时计时（思考→分析→完成）；
   - 结论先行、用业务语言表述，底部「供研发复核」折叠区列 `文件:行号` 出处；
   - 可点「继续追问」或直接回复卡片，带着上文接着问。
   - 首次冷启（新 microVM）会慢一些（含 MCP 注册），属正常。

---

## 六、日常运维（day-2）

> 运维聚合命令 `ops.sh status` 尚未实现（规划中，p2）；当前用下面的手动命令。

**代码更新了，刷新索引**（蓝绿替换 index-service 实例，不动网关/runtime）：

```bash
./scripts/deploy-all.sh --region <r> --repo /path/to/repo --refresh-index
```

**只重部 runtime**（改了 agent 镜像 / system prompt 后）：重跑 `deploy-all.sh`（镜像与 runtime 阶段幂等）。
注意热 microVM 会持旧镜像约 15 分钟才被回收。

**看网关日志**（网关是 index 主机上的 `bot-gateway.service`，结构化 JSON 日志进 journald）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：sudo journalctl -u bot-gateway -f
```

关键事件：`card_closed`（一次问答收尾）、`reply_context_replayed`（追问带上了上文）、
`card_write_dropped` / `finalize_error`（卡片写失败）、`invoke_http_error`（后端非 200）。

**看 index-service 日志**（同一台实例）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：journalctl -u index-bridge -f   （建图日志：index-build 单元）
```

**重启网关**（实例内）：`sudo systemctl restart bot-gateway`。改了飞书凭证后，重跑
`install.sh`（或 deploy 的 gateway 阶段）会重写 `/etc/bot-gateway.env` 并重启服务。

**拆除整套（停止计费）**：试用完、或某次部署中途失败留下计费资源（NAT ~$32/月、EIP、EC2）时，一条命令按反依赖顺序清干净：

```bash
./scripts/teardown.sh --region <r> --dry-run     # 先看要删什么，不动资源
./scripts/teardown.sh --region <r>               # 交互确认后删除（输入 yes）
./scripts/teardown.sh --region <r> --include-shared   # 连 IAM 角色 + S3 桶（账号共享）一起删
```

资源从 `.local/deploy-config` 读、读不到则按 `source-truth-*` tag 发现（所以中途崩溃的残留也能清）。
删完会提示一条核对命令确认没有遗留的计费 NAT。破坏性、不可逆。

---

## 七、排错（症状 → 原因 → 处置）

| 症状 | 可能原因 | 处置 |
|------|----------|------|
| 卡片一直「正在分析…」不收尾 | 后端流被中断 / finalize 异常 | 看网关日志 `finalize_error` / `card_closed failed:true`；偶发则重问；持续则查 runtime/index 健康 |
| 答案里出现原始 `<invoke>` XML 等标记 | 冷 microVM 首次 invoke 时 MCP 工具未注册（冷启动竞速） | 网关会自动重试一次；暖机后消失。看日志 `num_turns`/`cache_read` 确认是冷启动 |
| 机器人在群里**完全不回** | 网关没起 / 没 @ 到机器人 / 同 app 跑了两个网关争抢事件 | 进实例 `systemctl status bot-gateway` 确认 active + 日志 `sdk_wsclient_connected`；确认 @ 的是 `FEISHU_BOT_OPEN_ID`；杀掉多余网关只留一个 |
| 网关 `condition failed` 未启动 | `/etc/bot-gateway.env` 还没写（runtime 未就绪 / gateway 阶段被跳过） | 重跑 `install.sh` 或 `deploy-all.sh`（不跳 gateway）；确认 `FEISHU_SECRET_ID` 已配 |
| 卡片回「查询失败」/ 日志 `AccessDenied` | Bedrock 模型未在该区域开通 | 去 Bedrock 控制台开通模型访问；跨区域改用区域级推理档（见前置条件 2） |
| 部署在 index-service 阶段超时 | 全新账号 NAT 路由未收敛 / 实例还在冷建索引 | 多等一轮（bootstrap 对网络操作有重试）；看 `/var/log/` 与 `journalctl -u index-build` |
| `/health` 长期非 200 | 索引建坏 / graph.db 空 / worker 反复重启 | 进实例看 index-bridge 日志；必要时 `--refresh-index` 重建（蓝绿，不破坏在跑实例） |
| 重新部署后行为仍是旧的 | 热 microVM 仍持旧镜像（约 15 分钟）/ 网关没重启 | 等热 VM 老化回收；重启网关确保跑新代码 |

> 独占写入约束：index-service 的 graph.db 同一时刻只能有一个进程写入，并发写会导致 0 节点损坏。
> 服务层已用 flock + 进程内锁 + orphan reaper 守护；**不要**在实例上手动再跑一个 codegraph-server 写同一份图。

---

## 八、边界与安全（务必知道）

- **只读**：MVP 全程不写代码 / 不提交 / 不跑引擎；答案只基于最新主分支真实代码 + CodeGraph 取证。
- **密钥**：飞书 `App Secret`、`App ID` 等绝不入仓库（gitleaks pre-commit 守）；走环境变量 / Secrets Manager / SSM。
- **越界能力后置**：多分支、设计文档读取、写回、第二引擎等均为 post-MVP，详见
  [`../README.md`](../README.md) 的「MVP 边界」与设计权威依据 [`design/`](design/)。

---

## 附录 A：手动 deploy-all.sh

`install.sh` 是 `deploy-all.sh` 的交互式前端。要在 CI / 脚本里跑、或想精确控制参数，可直接调：

```bash
# 全新账号 / 新区域可跑、幂等、可重复。失败重跑会续上未完成的部分。
./scripts/deploy-all.sh --region ap-northeast-1 --repo <本地路径 | git URL | s3://...> \
  [--repo-ref <分支/标签/提交>] [--model <id>] [--instance-type t4g.large]

# 只打印计划、不动资源：
./scripts/deploy-all.sh --region <r> --repo <src> --dry-run

# 单跳某阶段（可重复）：artifacts|iam|network|index-svc|image|runtime|gateway
./scripts/deploy-all.sh --region <r> --repo <src> --skip gateway
```

gateway 阶段要激活网关，需要 `FEISHU_SECRET_ID`（指向一个 Secrets Manager 密钥，内容为
`{"app_id","app_secret","bot_open_id"}` 的 JSON，密钥名以 `source-truth/` 开头）。`install.sh` 会创建它并持久化到
`.local/deploy-config`；手动跑则自己 `export FEISHU_SECRET_ID=...`，否则 gateway 阶段会跳过（只部署后端）。

## 附录 B：本地手动起网关（开发调试）

正常部署里网关跑在 index 主机上（见第四节）。本地调试时可直接跑 TS：

```bash
cd bot-gateway
npm install
export AWS_REGION=ap-northeast-1
export RUNTIME_ARN="$(grep '^AGENT_RUNTIME_ARN=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx            # 勿写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
# 可选：LOG_HASH_SALT、MAX_CONCURRENT_INVOKES（默认 8）、LOCALE（默认 zh）
node_modules/.bin/ts-node --transpile-only src/index.ts
```

> ⚠️ 同一飞书 app 只能有一个网关连接。本地起之前，先停掉 index 主机上的服务
> （`sudo systemctl stop bot-gateway`），否则两个网关会争抢同一批事件。
