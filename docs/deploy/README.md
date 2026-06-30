# docs/deploy

`--local`（单台 EC2）部署的引导脚本与 IAM 模板。**默认（双机）部署用不到这里**——那条路由
`scripts/install.sh` / `scripts/deploy-all.sh` 直接走，IAM 由 `scripts/lib/provision_iam.sh` 自动建。

只有走 `--local`（在一台长期保留的 EC2 上既部署又常驻）时才用本目录。完整步骤见
[`../runbook.md`](../runbook.md) 的「在单台 EC2 上就地部署（`--local`）」一节；这里只是文件索引：

| 文件 | 何时用 | 说明 |
|------|--------|------|
| `launch-host.sh` | **入口**，在运维自己机器上跑 | 一条龙：选 AWS profile → 建 IAM → 选 VPC/子网/密钥/机型 → 启动 ARM64 EC2 并挂好实例角色 → 打印后续 SSH + 部署命令 |
| `create-iam.sh` | 一般不单独跑（`launch-host.sh` 内部调用） | 选 profile + region，用下面的模板建好实例角色 + instance profile。单独跑用于重建 IAM。 |
| `source-truth-iam.yaml` | CloudFormation 模板，由上面两个脚本调用 | 建一个 EC2 实例角色（部署期 + 运行期权限合一）+ instance profile。`--local` 部署在 EC2 上跑、用这台机器的实例角色，故该角色权限较大——**这台机器应专机专用**。 |

要点：IAM 由 CloudFormation 管理（无状态、可重建）；**EC2 独立长存、不进任何栈**——它的 `.local/`
存部署状态，升级时 SSH 回这台机器重跑即可，删栈不应波及它。
