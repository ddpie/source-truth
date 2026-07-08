# infra

基础设施即代码（IaC）。

## 当前活跃：`monitoring/`

`infra/monitoring/` 已在用，是监控栈的权威源（非占位）：`dashboard.{product,sre,by-project}.json`
看板模板、`lambda/dau_preaggregate.py`、`queries/metric-filters/*.json` 指标定义、
`queries/insights/*.logsinsights` 查询。由 `scripts/apply-monitoring.sh`（内部 `lib/apply-*.sh`
+ `lib/render_*.py`）渲染后应用到 CloudWatch。下面的 CDK 分工是 post-MVP 规划。

## IaC 分工

CDK 与 boto3 分两层管 IaC：

- **CDK 管理稳定层**（post-MVP，p2）：会话容器镜像（DockerImageAsset，`Platform.LINUX_ARM64`）、AgentCore
  执行 IAM 角色、VPC / 网络、index-service 常驻计算（含其本地代码副本）、网关基础设施。会话
  microVM 不挂任何文件系统，全部源码经 index-service HTTP 接口读取（仓库副本只在 index-service 本地磁盘）。
- **`scripts/deploy-all.sh`（+ `lib/deploy_runtime.py`，boto3）配置 AgentCore Runtime 本身**：其 env、
  idle timeout、网络模式、请求头 allowlist 都由脚本设定——之所以不交给 CDK，是因为 Runtime 还在快速演进，CloudFormation 对它的支持尚未稳定。
  CDK 输出（ImageUri / RoleArn / 端点）是 CDK 层与脚本层之间的契约。
- **密钥不归 CDK**：飞书 app secret、bot token 走 Secrets Manager / SSM，**当前需手动在 CDK 外创建**
  （编排脚本尚未自动建密钥），重部署不覆盖真实凭证。

## MVP 阶段：先不 CDK 化

MVP 用 `agentcore` starter toolkit / boto3 直接创建 Runtime + index-service（ARM EC2，本地代码副本 +
CodeGraph + HTTP 文件工具），先跑通主流程、建立 POC 性能基准。CodeGraph 召回率、本地检索/读文件
延迟、常驻索引可靠性这几项还需验证——验证前不固化 IaC，避免返工。架构定型后再渐进 CDK 化。

## CDK 化目标（p2，未实现）

CDK 部分（`bin/` / `lib/`）当前为占位。CDK 化后落地 `bin/app.ts` + `lib/`（runtime-stack / network-stack /
codegraph(index-service)-stack / gateway-stack）+ 快照测试 + cdk-nag 合规门禁。
无独立存储 stack——索引服务用本地磁盘副本。
