# 部署与运维手册（runbook）

从零把 source-truth 跑起来、连上飞书、日常运维的一条龙指引。心智模型见
[`agent/architecture.md`](agent/architecture.md)；这里只讲**怎么做**。

整套系统有两半：

- **后端**（`deploy-all.sh` 一键起）：S3 产物 → IAM → 网络 → index-service(EC2) → 镜像(ECR) → AgentCore Runtime。
- **bot-gateway**（你单独长驻跑）：飞书长连接网关，把群里的 @ 消息路由到后端，再把答案流式回填成卡片。

> 一句话：`deploy-all.sh` 把**后端**拉起来；网关要你自己跑（带上飞书凭证 + 后端的 `RUNTIME_ARN`）。
> 后端 READY ≠ 机器人能回话——还差「连飞书 + 起网关」这最后一公里，本文补齐。

---

## 一、前置条件（一次性）

1. **AWS 账号 + 目标区域**：区域须支持 AgentCore（如 `ap-northeast-1` 东京）。本机配好可部署的 AWS 凭证。
2. **Bedrock 模型访问**：在 Bedrock 控制台 → Model access 开通目标模型（默认 `global.anthropic.claude-opus-4-8`）。
   跨区域注意：`global.*` 推理档只在部分区域承载，不支持的区域改用区域级档（`apac.*` / `us.*` / `eu.*`）；
   `deploy-all.sh` 的 preflight 会就此 WARN 并给出可操作提示。
3. **目标代码仓**：本机有一份要被问答的游戏代码仓（index-service 会把它打包快照、建索引）。
4. **飞书应用**（见第三节，可与部署并行准备）。

---

## 二、部署后端（一条命令）

```bash
# 全新账号 / 新区域可跑、幂等、可重复。失败重跑会续上未完成的部分。
./scripts/deploy-all.sh --region ap-northeast-1 --repo /path/to/your-game-repo

# 先看计划不动资源：
./scripts/deploy-all.sh --region ap-northeast-1 --repo /path/to/repo --dry-run
```

成功的样子：

- 脚本结尾打印 `deploy-all complete`，并把状态写进 `.local/deploy-config`（含 `AGENT_RUNTIME_ARN`、
  `INDEX_SERVICE_IP`、`ECR_IMAGE` 等）。
- index-service 的 `/health` 在部署中被网关探到 `200`（脚本经 SSM 在实例内 `curl 127.0.0.1:8080/health` 探活）。
- 结尾的 **NEXT STEPS** 提醒你后端已好、网关还没起——接着走第三、四节。

---

## 三、连飞书（connect 清单）

在[飞书开放平台](https://open.feishu.cn)创建并配置应用：

1. **创建企业自建应用**，记下 `App ID`（`cli_...`）和 `App Secret`。
2. **权限（scope）**：开通发消息 / 读消息相关权限（`im:message`、`im:message:send_as_bot`），以及卡片相关权限。
3. **事件订阅**：启用**长连接**模式（不是 webhook）。订阅这两个事件：
   - `im.message.receive_v1`（收到群消息）
   - `card.action.trigger`（卡片按钮点击：停止 / 追问 / 澄清）
4. **机器人**：启用机器人能力；把它的 `open_id`（`ou_...`）记为 `FEISHU_BOT_OPEN_ID`（群里 @ 谁就靠它判断）。
5. **存密钥**：`App Secret` 属敏感信息，**绝不提交进仓库**。放进 Secrets Manager / SSM，或仅作为网关进程的环境变量注入：

   ```bash
   # 示例（择一）：
   aws secretsmanager create-secret --name source-truth/feishu-app-secret --secret-string '<APP_SECRET>'
   # 或
   aws ssm put-parameter --name /source-truth/feishu-app-secret --type SecureString --value '<APP_SECRET>'
   ```

   > 当前 MVP：网关直接从**环境变量** `FEISHU_APP_SECRET` 读取明文；上面的 Secrets Manager/SSM 是推荐的存放处，
   > 由你的启动脚本在起网关前取出注入环境变量（编排脚本不自动建密钥）。

6. 把机器人**拉进目标群**，记下群 `chat_id`（`oc_...`）。

---

## 四、起网关（最后一公里）

网关是一个长驻 Node 进程，入口 `bot-gateway/src/index.ts`。

```bash
cd bot-gateway
npm install

# 必需环境变量：
export AWS_REGION=ap-northeast-1
export RUNTIME_ARN="$(grep '^AGENT_RUNTIME_ARN=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx            # 从 Secrets Manager/SSM 取出注入，勿写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
# 可选：LOG_HASH_SALT（脱敏用户 id 的盐，建议设）、MAX_CONCURRENT_INVOKES（默认 8）、LOCALE（默认 zh）

# 启动（长驻；用 ts-node 直接跑 TS，无需预编译）：
node_modules/.bin/ts-node --transpile-only src/index.ts
```

启动成功的日志：`sdk_wsclient_started` → `sdk_wsclient_connected`。

> **只能有一个网关实例连同一个飞书应用**：飞书长连接是集群模式，每个事件只投给一个 client，
> 同 app 跑两个网关会互相抢事件、表现出旧行为。重启前先杀掉旧进程。

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
   - 结论先行、用大白话，底部「供研发复核」折叠区列 `文件:行号` 出处；
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
注意暖 microVM 会持旧镜像约 15 分钟才被回收。

**看网关日志**：网关把结构化 JSON 日志打到 stdout（本地跑时重定向到文件，如 `/tmp/bot-gateway.log`）。
关键事件：`card_closed`（一次问答收尾）、`reply_context_replayed`（追问带上了上文）、
`card_write_dropped` / `finalize_error`（卡片写失败）、`invoke_http_error`（后端非 200）。

**看 index-service 日志**（经 SSM 进实例）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：journalctl -u index-bridge -f   （建图日志：index-build 单元）
```

**重启网关**：先杀旧进程（同 app 只能一个），再按第四节重新起。

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
| 机器人在群里**完全不回** | 网关没起 / 没 @ 到机器人 / 同 app 跑了两个网关抢事件 | 确认网关 `sdk_wsclient_connected`；确认 @ 的是 `FEISHU_BOT_OPEN_ID`；杀掉多余网关只留一个 |
| 卡片回「查询失败」/ 日志 `AccessDenied` | Bedrock 模型未在该区域开通 | 去 Bedrock 控制台开通模型访问；跨区域改用区域级推理档（见前置条件 2） |
| 部署在 index-service 阶段超时 | 全新账号 NAT 路由未收敛 / 实例还在冷建索引 | 多等一轮（bootstrap 对网络操作有重试）；看 `/var/log/` 与 `journalctl -u index-build` |
| `/health` 长期非 200 | 索引建坏 / graph.db 空 / worker 反复重启 | 进实例看 index-bridge 日志；必要时 `--refresh-index` 重建（蓝绿，不破坏在跑实例） |
| 重新部署后行为仍是旧的 | 暖 microVM 仍持旧镜像（约 15 分钟）/ 网关没重启 | 等暖 VM 老化回收；重启网关确保跑新代码 |

> 单写者铁律：index-service 的 graph.db 同一时刻只能有一个写者，并发写会导致 0 节点损坏。
> 服务层已用 flock + 进程内锁 + orphan reaper 守护；**不要**在实例上手动再跑一个 codegraph-server 写同一份图。

---

## 八、边界与安全（务必知道）

- **只读**：MVP 全程不写代码 / 不提交 / 不跑引擎；答案只基于最新主分支真实代码 + CodeGraph 取证。
- **密钥**：飞书 `App Secret`、`App ID` 等绝不入仓库（gitleaks pre-commit 守）；走环境变量 / Secrets Manager / SSM。
- **越界能力后置**：多分支、设计文档读取、写回、第二引擎等均为 post-MVP，详见
  [`../README.md`](../README.md) 的「MVP 边界」与设计真相源 [`design/`](design/)。
