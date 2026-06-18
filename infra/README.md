# infra

基础设施即代码（IaC）。

## IaC 分工

采用 CDK / boto3 混合分工：

- **CDK 管稳定层**（post-MVP，p2）：会话容器镜像（DockerImageAsset，`Platform.LINUX_ARM64`）、AgentCore
  执行 IAM 角色、EFS（FileSystem + AccessPoint + VPC + mount targets）、index-service 常驻计算、网关基础设施。
- **`scripts/deploy-all.sh`（+ `lib/deploy_runtime.py`，boto3）配 AgentCore Runtime 本身**：其 env、
  idle timeout、网络模式、请求头 allowlist——因为 Runtime 是快速演进的服务，CloudFormation 支持未稳定。
  CDK 输出（ImageUri / RoleArn / 端点）是 CDK 层与脚本层之间的契约。（`deploy.sh` 为已废弃转发垫片。）
- **密钥不归 CDK**：飞书 app secret、bot token 走 Secrets Manager / SSM，**当前需手工在 CDK 外创建**
  （编排脚本尚未自动建密钥），重部署不覆盖真实凭证。

## MVP 阶段：先不 CDK 化

MVP 用 `agentcore` starter toolkit / boto3 直接起 Runtime + 手工建 EFS / index-service，先跑通主流程与
POC 性能基准。CodeGraph 召回率、EFS 读性能与同卷并发挂载、NFS 上 inotify 可靠性是三大待验证点——验证
前不固化 IaC，避免返工。架构定型后再渐进 CDK 化。

## 状态

p0：占位。p2 落地 `bin/app.ts` + `lib/`（runtime-stack / storage(EFS)-stack / codegraph-stack /
gateway-stack）+ 快照测试 + cdk-nag 合规门禁。
