# scripts

运维生命周期脚本（Bash）。

| 脚本 | 阶段 | 状态 | 职责 |
|------|------|------|------|
| `check-invariants.sh` | p0 | 已实现 | 快速无网络结构 lint：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录存在性。pre-commit 与 `test.sh --lint` 调用。 |
| `test.sh` | p1 | 已实现 | 分层测试的唯一入口：离线默认（lint + unit + typecheck）/ `--full`（加 e2e；smoke 仍占位）。详见下方「用法」。 |
| `e2e-probe.py` | p1 | 已实现 | `test.sh --full` 的 e2e 组件：对已部署 Runtime 跑真实问答（boto3 InvokeAgentRuntime + 流式），**发送与 gateway 完全一致的 payload** `{prompt, traceId, repos}`。校验只读边界（`permission_denials` 空）、无 `errors`、答案含 `文件:行号` 出处。ARN/region/repos 从 `.local/{deploy-config,projects.json}` 读（不写死）；缺依赖/未部署退出码 2（test.sh 视为 skip，不阻塞）。纯逻辑（region 优先级 / payload 形状）有单测 `tests/test_e2e_probe.sh`。 |
| `lib/common.sh` | p1 | 已实现 | 共享 shell：格式化输出（`say`）+ 依赖检查（`have_cmd` / `require_cmd`）。可被单测 source。 |
| `tests/test_*.sh` | p1 | 已实现 | 纯 bash 单元测试（无外部依赖）；`test.sh` 的 unit 层自动发现并运行。 |
| `check-versions.sh` | p1 | 已实现 | 无网络版本固定防漂移守卫：基础镜像 digest / requirements.txt 全 ==-pin / requirements.lock 一致 / Node 主版本 / claude-code npm pin（**例外：允许 `@latest`，仅 WARN 放行**，运维 2026-06-19 决定 CLI 跟随最新版本）。`test.sh --lint` 调用。 |
| `lib/env-utils.sh` | p1 | 已实现 | 读写 `.local/deploy-config` + region 解析（saved > env > aws > default）。有单测 `tests/test_env_utils.sh`。 |
| `deploy-all.sh` | p1 | 已实现 | **一键部署（权威入口）**：Phase 0 preflight → 1 artifacts→S3 → 1b IAM → 2 network → 3 index-service(EC2+bootstrap) → 4 镜像 build/push → 5 per-project deploy（activate + Runtime + gateway）→ 7 monitoring。幂等，`--dry-run` 无副作用，`--refresh-index` 会对 index 实例做蓝绿换机。`--local`：把整套部署放在当前这台 EC2 上跑、复用本机 VPC（单机模式，见 runbook「在单台 EC2 上就地部署」）。配套 `lib/provision_{iam,network,index_service,index_dns}.sh` + `lib/wait_index_health.sh` + `lib/deploy_runtime.py`（boto3 配置 Runtime）+ `lib/deploy_project.sh` + `lib/activate_gateway.sh`。会话 microVM 不挂任何文件系统，全部源码经 index-service HTTP 接口读取（`read_file`/`glob_files`/`search_files`/`read_table`/`codegraph_*`），仓库副本只在 index-service 本地磁盘。默认模型 `global.anthropic.claude-opus-4-8`（`--model` 可改）。**两个手动前置条件（脚本不自动创建）**：① 飞书 app secret（bot-gateway 需 `FEISHU_APP_ID/SECRET`）；② **Bedrock 访问**：部署身份需有 `bedrock:InvokeModel`；模型推理档由部署按 `--region` 自动解析（`bedrock list-inference-profiles`），解析不确定时 Phase 0 的 invoke 探针会 WARN（非阻断）。 |
| `launch-host.sh` | p1 | 已实现 | `--local`（单台 EC2）模式入口，在**运维本地**跑：选 profile → 建 IAM（`create-iam.sh`）→ 私有仓则把本机 gh token 存进 Secrets Manager → 自动建 source-truth 专用网络（VPC/公私子网/IGW/NAT，复用 `provision_network.sh`）+ host 安全组（只放行运维 IP 的 22）→ 在公有子网起一台 ARM64 EC2 挂好实例角色 → 问 SSH 私钥后 `scp prepare-local-host.sh` 上机并执行。已有 host 默认复用（`--new-host` 强制新建），`--dry-run` 只打印计划，选择记入 `.local/launch-host.<account>.env` 供重跑预填。 |
| `create-iam.sh` | p1 | 已实现 | 建/复用 `--local` 模式的实例角色 `source-truth-index-role` + instance profile，并补部署期权限（命令式 describe-or-create，幂等；角色已存在则只补策略不重建）。一般由 `launch-host.sh` 内部调用。 |
| `prepare-local-host.sh` | p1 | 已实现 | 在 `--local` 的全新 EC2 上跑（由 `launch-host.sh` scp 上来）：装 install.sh 所需依赖（`aws`/`docker`/`git`）→ 用 Secrets Manager 里的 token `gh auth login`（私有仓 clone/Release 下载/升级都靠它）→ 克隆仓库 → `sg docker -c ./scripts/install.sh` 进入交互安装。幂等；`REGION` 必填。 |
| `push-local-repo.sh` | p1 | 已实现 | **客户机侧** local 仓上传：`rsync` over SSH 把本地仓推到索引主机暂存目录 `/data/repo/<subdir>.incoming`，再经 `sudo bash reindex_local_repo.sh <subdir>` 在主机本地同步到正在用的代码目录 `/data/repo/<subdir>`——常规推送由 watcher 增量重建索引、按变更清单增量刷新术语表、不停 bridge（与 git pull 同路径）；首次推送停 bridge 全量建一次图，此时建图与术语表并行。重活交给后台 systemd 单元，推送命令随即返回 `REINDEX_LAUNCHED`（不阻塞、ssh 断开也不影响后台）。用于 `projects.json` 里 `source:"local"` 的仓（无 git remote），重跑即刷新。安全：subdir 正则校验、`--safe-links --no-links` 防软链逃逸、不支持自由 `--ssh-opts`（只认 `--identity`）。`--dry-run` 只打印命令。 |
| `deploy.sh` | p1 | 已废弃 | 已废弃兼容垫片：转发到 `deploy-all.sh`（旧的 index-service/bot-gateway 阶段曾是桩，会导致部署状态不完整）。新代码直接用 `deploy-all.sh`。 |
| `ops.sh` | p2 | 待实现 | 运维工具：status / logs / reindex。（destroy 已拆到 `teardown.sh`）|
| `teardown.sh` | p1 | 已实现 | **有序销毁**：按反依赖顺序删 deploy-all.sh 创建的资源（runtime → EC2 → NAT+EIP → DNS → 子网/路由/IGW/SG → VPC → ECR），资源从 `.local/deploy-config` 读；读不到则按 `source-truth-*` Name tag 发现（把中途失败遗留的资源也一并兜住）。`--dry-run` 只打印计划；默认交互确认，`--yes` 跳过；IAM 角色 + S3 桶（账号共享）默认保留，`--include-shared` 才删。破坏性操作，见 AGENTS.md「ask first」。 |

## 用法

```bash
./scripts/test.sh           # 离线默认：lint + unit(shell+python) + typecheck（安全、无网络/Docker/AWS）
./scripts/test.sh --lint    # 仅结构自检（= check-invariants.sh）
./scripts/test.sh --unit    # 仅单元测试（shell test_*.sh + 各组件 pytest）
./scripts/test.sh --list    # 列出发现的 shell unit 测试文件
./scripts/test.sh --list-py # 列出发现的 Python 测试目录（<component>/tests）
./scripts/test.sh --full    # 离线套件 + e2e（对已部署 Runtime 跑真实问答；缺部署则自动 skip）。smoke 仍占位
```

退出码 0 = 全部通过。unit 层运行两类测试：`scripts/tests/test_*.sh`（纯 bash）+ 各组件 `<component>/tests/test_*.py`
（pytest）。typecheck 层「缺工具/缺配置则 skip」——离线默认不强制安装 ruff/tsc/pytest。

## 写一个 unit 测试

- **Shell**：新建 `scripts/tests/test_<名>.sh`——纯 bash、可独立 `bash` 运行、退出码 0 = 全部通过；
  约定见 `tests/test_common.sh`（`source lib/common.sh` 后用内联断言）。
- **Python**：新建 `<component>/tests/test_*.py`（如 `agent-container/tests/`）——pytest 发现，
  纯函数优先、不触网/不启动容器/不 import 未装的 SDK。

## shellcheck 约定

对 `source` 了其他脚本的文件，用 `shellcheck -x`（跟随 source）以消除 SC1091 误报；脚本内已带
`# shellcheck source=...` 指令。
