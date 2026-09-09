# infra

基础设施即代码（IaC）。

## 当前活跃：`monitoring/`

`infra/monitoring/` 已在用，是监控栈的权威源（非占位）：`dashboard.{product,sre,by-project}.json`
看板模板、`lambda/dau_preaggregate.py`、`queries/metric-filters/*.json` 指标定义、
`queries/insights/*.logsinsights` 查询。由 `scripts/apply-monitoring.sh`（内部 `lib/apply-*.sh`
+ `lib/render_*.py`）渲染后应用到 CloudWatch。下面的 CDK 分工是 post-MVP 规划。

## 当前部署方式

[`scripts/install.sh`](../scripts/install.sh) 提供交互入口，
[`scripts/deploy-all.sh`](../scripts/deploy-all.sh) 编排 AWS CLI / boto3 脚本，创建和更新 IAM、网络、
EC2、镜像及 AgentCore Runtime。Runtime 的实现入口是
[`scripts/lib/deploy_runtime.py`](../scripts/lib/deploy_runtime.py)。当前部署不依赖 CDK。

网关和索引服务共用一台 EC2；每个项目有独立的服务进程与 Runtime 配置。
会话 microVM 通过 HTTP 读取仓库，不挂载仓库文件系统；隔离的临时 Session Storage 挂载于
`/mnt/workspace`。

`install.sh` 根据交互输入创建或更新飞书 Secrets Manager 条目，网关启动时读取并注入进程环境。
密钥值不写入仓库或部署配置文件。具体流程见
[`部署手册`](../docs/runbook_zh.md)。

## CDK 化目标（p2，未实现）

CDK 部分尚未实现。规划落地 `bin/app.ts` + `lib/`（runtime-stack / network-stack /
codegraph(index-service)-stack / gateway-stack）+ 快照测试 + cdk-nag 合规门禁。
无独立存储 stack——索引服务用本地磁盘副本。
