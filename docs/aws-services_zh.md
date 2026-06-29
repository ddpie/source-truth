# AWS 服务清单

系统部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。本文列出全部用到的 AWS 服务及其规格 / 数量 / 用途。

规格均为默认值，部署时可调（见 `scripts/install.sh` 与 `scripts/deploy-all.sh`）。**数量**一栏里
**N = 项目数**（每个游戏项目一个机器人，按项目独立的资源会随项目数增长），其余为全局共享。

## 1. 计算与 AI（跑 Agent、出答案）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **EC2**（index-service 主机） | ARM Graviton `t4g.large`（2 vCPU / 8 GiB）默认；可选到 `m7g.2xlarge`（8 vCPU / 32 GiB） | 1（所有项目共用一台） | 常驻 CodeGraph 索引 + MCP-over-HTTP 接口、各项目 bot-gateway 进程；持有唯一一份代码本地副本；并跑构建期术语表引擎（本地 `claude` CLI 离线扫码生成术语表，见 `docs/agent/glossary.md`） |
| **Bedrock AgentCore Runtime** | Firecracker microVM；VPC 模式；空闲回收 900s、硬上限 8h（均可调 60–28800s） | **N**（`source_truth_agent_<projectId>`，每项目一套） | 会话隔离的 Agent 执行环境，按会话独立 microVM |
| **Bedrock**（模型推理） | 默认 `global.anthropic.claude-opus-4-8`（可按项目覆盖） | 共享 | ① 会话 microVM 内 Agent 的 LLM 推理；② index 主机构建期术语表引擎的 `InvokeModel`（index 实例角色带受限 `bedrock-invoke` 策略）。均 `CLAUDE_CODE_USE_BEDROCK=1` 计费 |

## 2. 存储与镜像（放代码、产物、镜像）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **EBS**（根卷） | gp3，30 GiB 默认；可选 50 / 100 / 200 GiB 或手动输入 | 1 | 存代码副本、`graph.db`、构建产物 |
| **S3** | artifact bucket `source-truth-repo-<account>-<region>` | 1 | 部署产物：codegraph 二进制、index/gateway tarball、bootstrap 脚本 |
| **ECR** | 私有仓库 `source-truth/agent`，ARM64 镜像 | 1 | 存放会话容器镜像，供 AgentCore 拉取 |

## 3. 网络（隔离与连通）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **VPC** | CIDR `10.1.0.0/16`；公有子网 `10.1.0.0/24` + 私有子网 `10.1.1.0/24` | 1 | 网络隔离；index 主机置于私有子网 |
| **NAT Gateway**（+ 弹性 IP） | 置于公有子网 | 1 | 私有子网出站（拉取 S3 产物、调用 Bedrock） |
| **Internet Gateway** | — | 1 | 公有子网入口 |
| **Security Group** | 入站仅 `8080-8099`、限同 SG 成员 | 1（AgentCore Runtime 的 ENI 也加入此 SG） | 限制各项目 bridge 端口仅本 VPC 内可达 |
| **Route 53**（私有托管区） | 私有域 `source-truth.internal`，A 记录 TTL 30s | 1 | 给 index 主机稳定 DNS 名（蓝绿换实例时存活中的 microVM 缓存仍有效） |

## 4. 安全与运维（凭证、权限、远程管理）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **Secrets Manager** | 飞书凭证（每项目）+ git 只读令牌 + 日志脱敏盐 | **N + 2**（`feishu-<projectId>` ×N、`git-credentials`、`log-hash-salt`） | 飞书 App 凭证、私有仓只读拉取令牌、`hashUserId` 脱敏盐；运行时取出不落盘 |
| **IAM** | 2 角色 + 1 实例配置 + 1 服务关联角色 | 固定 | EC2 执行角色、AgentCore Runtime 角色、实例配置、AgentCore 的 VPC ENI 托管角色 |
| **Systems Manager（SSM）** | Session Manager（无 SSH） | — | 管理私有子网 EC2：上线项目、刷新网关、清理单元 |

## 5. 监控与告警（看健康、出指标）

| 服务 | 规格 | 数量 | 用途 |
|------|------|------|------|
| **CloudWatch Logs** | 日志组 `/source-truth/bot-gateway` | 1（各项目网关汇入，按 `projectId` 维度区分） | 网关结构化日志，指标的数据源 |
| **CloudWatch Metric Filters** | KPI 17 项 + 告警 4 项 + 按项目维度伴生指标 | 20+ | 从日志提取用量 / 延迟 / 健康 / 失败率等指标 |
| **CloudWatch Dashboards** | 产品用量 / SRE 健康 / 分项目 | 3 | 看板可视化 |
| **CloudWatch Alarms** | ToolcallLeakDetected / FinalizeFailed / AnswerFailedBurst / LogPipelineStalled | 4 | 关键健康事件告警，经 SNS 通知 |
| **SNS** | 主题 `source-truth-alarms` | 1 | 告警分发（手动订阅邮件 / webhook） |
| **Lambda** | `python3.12`，128 MB，超时 180s | 1 | 日活（DAU）预聚合：每日跑一次 Logs Insights 写回指标 |
| **EventBridge** | 规则 `source-truth-dau-daily`，每日 cron | 1 | 触发 DAU 预聚合 Lambda |

## 未使用的服务（避免误解）

会话映射与事件去重为网关**进程内内存**实现（MVP），未使用 DynamoDB / Redis；会话容器**不挂任何文件系统**
（无 EFS），源码全经 index-service 的 HTTP 接口读取，没有共享挂载、没有副本同步问题。
