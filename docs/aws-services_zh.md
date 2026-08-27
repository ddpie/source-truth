[中文](aws-services_zh.md) | [English](aws-services_en.md)

# AWS 服务清单

系统部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。本文列出全部用到的 AWS 服务及其规格 / 数量 / 用途。

规格均为默认值，部署时可调（见 `scripts/install.sh` 与 `scripts/deploy-all.sh`）。**数量**一栏里
**N = 项目数**（每个游戏项目一个机器人，按项目独立的资源会随项目数增长），其余为全局共享。

## 1. 计算与 AI（跑 Agent、出答案）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **EC2**（index-service 主机） | ARM Graviton `t4g.large`（2 vCPU / 8 GiB）默认；可选到 `m7g.2xlarge`（8 vCPU / 32 GiB）；开启终止保护与 IMDSv2 强制（`HttpTokens=required`，每轮部署都重新校准） | 1（所有项目共用一台） | 常驻 CodeGraph 索引 + MCP-over-HTTP 接口、各项目 bot-gateway 进程；持有唯一一份代码本地副本；并跑构建期术语表引擎（本地 `claude` CLI 离线扫码生成术语表，见 `docs/agent/glossary.md`） |
| **Bedrock AgentCore Runtime** | Firecracker microVM；VPC 模式；空闲回收 900s、硬上限 8h（均可调 60–28800s） | **N**（`source_truth_agent_<projectId>`，每项目一套） | 会话隔离的 Agent 执行环境，按会话独立 microVM |
| **Bedrock**（模型推理） | 默认 `global.anthropic.claude-opus-4-8`（可按项目覆盖） | 共享 | ① 会话 microVM 内 Agent 的 LLM 推理；② index 主机构建期术语表引擎的 `InvokeModel`（index 实例角色带受限 `bedrock-invoke` 策略）。均 `CLAUDE_CODE_USE_BEDROCK=1` 计费 |

## 2. 存储与镜像（放代码、产物、镜像）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **EBS**（根卷） | gp3，30 GiB 默认；可选 50 / 100 / 200 GiB 或手动输入；`Encrypted: true`（静态加密，AWS 托管密钥） | 1 | 存代码副本、`graph.db`、构建产物 |
| **S3** | artifact bucket `source-truth-repo-<account>-<region>` | 1 | 部署产物：codegraph 二进制、index/gateway tarball、bootstrap 脚本 |
| **ECR** | 私有仓库 `source-truth/agent`，ARM64 镜像 | 1 | 存放会话容器镜像，供 AgentCore 拉取 |

## 3. 网络（隔离与连通）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **VPC** | CIDR `10.1.0.0/16`；公有子网 `10.1.0.0/24` + 私有子网 `10.1.1.0/24` | 1 | 网络隔离；默认两台拓扑下 index 主机在私有子网，`--local`（单台 EC2）下 index 主机在公有子网、带公网 IP，安全组只放行运维出口 IP 的 22 |
| **NAT Gateway**（+ 弹性 IP） | 置于公有子网 | 1 | 私有子网出站。有了下面的 VPC 端点后，它已不在拉镜像和 S3 的路径上，但调用 Bedrock 仍必须经它（Bedrock 在此没有端点） |
| **VPC 端点** | `ecr.api` + `ecr.dkr`（Interface 型，置于私有子网，开启 private DNS，独立安全组只放行 VPC CIDR 的 443）与 `s3`（Gateway 型，挂在私有路由表上） | 3 | 让拉取容器镜像不出 VPC。经 NAT 走公网拉镜像会间歇失败，而且**唯一**的表现是 `HTTP 424 Runtime health check failed`——容器根本没起来，里面任何东西都报不出原因。一次 ECR 拉取需要三个端点齐备：`ecr.api` 负责认证与 manifest，`ecr.dkr` 负责 registry 协议，`s3` 是因为镜像层本身就是 S3 对象（缺了它，每次拉取的绝大部分字节仍然出 VPC）。两个 Interface 端点按小时按可用区计费；设 `DEPLOY_VPC_ENDPOINTS=false` 可跳过，代价是退回 NAT 路径 |
| **Internet Gateway** | — | 1 | 公有子网入口 |
| **Security Group** | 入站仅 `8080-8099`、限同 SG 成员 | 1（AgentCore Runtime 的 ENI 也加入此 SG） | 限制各项目 bridge 端口仅本 VPC 内可达 |
| **Network ACL** | `source-truth-private-nacl`，关联私有子网（替换默认 NACL）。入站白名单：`100` TCP 8080-8099（限 VPC CIDR）、`110` TCP 443（限 VPC CIDR）、`115` TCP 1024-65535（限 VPC CIDR，下面 VPC 端点的回程流量）、`120/130` TCP/UDP 32768-65535（经 NAT 发起连接的回程流量；上界必须到 65535，因为 AgentCore Runtime 的 ENI 是 AWS 托管 microVM，源端口高于 Linux 默认的 60999）、`140` ICMP type 3 code 4（Path MTU 发现）；出站全放通（NAT 出站需要）；其余走 32767 隐式拒绝 | 1 | 子网级第二道网络管控，收敛为增量式（先补齐目标规则、再清理多余规则，任何时刻都不会经过 deny-all 状态） |
| **VPC Flow Logs** | 全流量（`ALL`），聚合间隔 600s，投递到 S3 `s3://<artifact-bucket>/vpc-flow-logs/` | 1 | 网络审计留痕；建不出来只 WARN 不阻断部署（审计辅助，非服务依赖） |
| **Route 53**（私有托管区） | 私有域 `source-truth.internal`，A 记录 TTL 30s | 1 | 给 index 主机稳定 DNS 名（agent 侧不写死私有 IP；索引主机就地更新、不换实例，这个名字始终指向同一台在跑的主机） |

## 4. 安全与运维（凭证、权限、远程管理）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **Secrets Manager** | 飞书凭证（每项目）+ git 只读令牌 + 日志脱敏盐；`--local` 另加一条部署用 GitHub 令牌 | **N + 2**（`feishu-<projectId>` ×N、`git-credentials`、`log-hash-salt`）；`--local` 为 **N + 3**（另加 `deploy-github-token`） | 飞书 App 凭证、私有仓只读拉取令牌、`hashUserId` 脱敏盐；`--local` 的 `deploy-github-token` 供新机 `gh auth login`（克隆私有仓、下载 Release、后续升级）。运行时取出不落盘 |
| **IAM** | 3 角色 + 1 实例配置 + 1 服务关联角色 | 固定 | EC2 执行角色 `source-truth-index-role`、AgentCore Runtime 角色 `SourceTruthAgentRuntimeRole`、DAU 预聚合 Lambda 角色 `source-truth-dau-lambda-role`、实例配置、AgentCore 的 VPC ENI 托管角色。前三个角色都是账号级全局角色（多区域共用），其策略里资源型 ARN 的 region 段必须用 `*`，否则第二个区域部署会覆盖写、静默撤销第一个区域的权限。`check-invariants.sh` 的守卫是**部分覆盖**：只 grep `scripts/lib/provision_iam.sh` 与 `scripts/lib/apply-dau-lambda.sh`，且只查 `logs` / `bedrock` / `bedrock-agentcore` / `secretsmanager` / `s3` 这几个服务面的 ARN。`scripts/lib/create-iam.sh`——`--local` 路径上往同一个账号级 `source-truth-index-role` 写内联策略的脚本——**不在扫描范围内**，在那里新写一个钉死 region 的 ARN 能通过 CI |
| **Systems Manager（SSM）** | Session Manager（无 SSH） | — | 管理私有子网 EC2：上线项目、刷新网关、清理单元 |

## 5. 监控与告警（看健康、出指标）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **CloudWatch Logs** | 日志组 `/source-truth/bot-gateway`（网关日志文件）+ `/source-truth/index-bridge`（bridge 的 journald 单元），保留期均 90 天 | 2（网关组各项目汇入，按 `projectId` 维度区分） | 网关结构化日志（指标的数据源）+ 索引 bridge 日志；由主机上的 CloudWatch agent 投递 |
| **CloudWatch Metric Filters** | KPI 17 项 + 告警 4 项 + 按项目维度 8 项 | 29 | 从日志提取用量 / 延迟 / 健康 / 失败率等指标 |
| **CloudWatch Dashboards** | 产品用量 / SRE 健康 / 分项目 | 3 | 看板可视化 |
| **CloudWatch Alarms** | ToolcallLeakDetected / FinalizeFailed / AnswerFailedBurst / LogPipelineStalled（阈值在 `config/alarm-thresholds.json`，经 SNS 通知）+ `source-truth-index-auto-recover-<region>`（`StatusCheckFailed_System`，动作是 `arn:aws:automate:<region>:ec2:recover`，不经 SNS） | 5 | 前 4 条是关键健康事件告警；第 5 条触发 EC2 自动恢复：系统状态检查连续 2 个周期失败（底层硬件 / hypervisor 故障）时把实例迁到健康硬件上恢复运行，实例 ID、私有 IP 与 EBS 卷都保留 |
| **SNS** | 主题 `source-truth-alarms` | 1 | 告警分发（手动订阅邮件 / webhook） |
| **Lambda** | `python3.12`，128 MB，超时 180s | 1 | 日活（DAU）预聚合：每日跑一次 Logs Insights 写回指标 |
| **EventBridge** | 规则 `source-truth-dau-daily`，每日 cron | 1 | 触发 DAU 预聚合 Lambda |

## 未使用的服务（避免误解）

会话映射与事件去重为网关**进程内内存**实现（MVP），未使用 DynamoDB / Redis；会话容器**不挂任何文件系统**
（无 EFS），源码全经 index-service 的 HTTP 接口读取，没有共享挂载、没有副本同步问题。
