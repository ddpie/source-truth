# infra

基础设施即代码（IaC）。

## IaC 分工

采用 CDK / boto3 混合分工：

- **CDK 管稳定层**（post-MVP，p2）：会话容器镜像（DockerImageAsset，`Platform.LINUX_ARM64`）、AgentCore
  执行 IAM 角色、VPC / 网络、index-service 常驻计算（含其本地代码副本）、网关基础设施。会话
  microVM 不挂任何文件系统，全部源码经 index-service HTTP 接口读取（仓库副本只在 index-service 本地磁盘）。
- **`scripts/deploy-all.sh`（+ `lib/deploy_runtime.py`，boto3）配 AgentCore Runtime 本身**：其 env、
  idle timeout、网络模式、请求头 allowlist——因为 Runtime 是快速演进的服务，CloudFormation 支持未稳定。
  CDK 输出（ImageUri / RoleArn / 端点）是 CDK 层与脚本层之间的契约。（`deploy.sh` 为已废弃转发垫片。）
- **密钥不归 CDK**：飞书 app secret、bot token 走 Secrets Manager / SSM，**当前需手工在 CDK 外创建**
  （编排脚本尚未自动建密钥），重部署不覆盖真实凭证。

## MVP 阶段：先不 CDK 化

MVP 用 `agentcore` starter toolkit / boto3 直接起 Runtime + index-service（ARM EC2，本地代码副本 +
CodeGraph + HTTP 文件工具），先跑通主流程与 POC 性能基准。CodeGraph 召回率、本地检索/读文件
延迟、常驻索引可靠性是待验证点——验证前不固化 IaC，避免返工。架构定型后再渐进 CDK 化。

## CDK 化目标（p2，未实现）

目录当前为占位。CDK 化后落地 `bin/app.ts` + `lib/`（runtime-stack / network-stack /
codegraph(index-service)-stack / gateway-stack）+ 快照测试 + cdk-nag 合规门禁。
无独立存储 stack——索引服务用本地磁盘副本。
