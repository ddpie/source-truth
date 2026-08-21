# scripts

运维生命周期脚本（Bash）。

| 脚本 | 阶段 | 状态 | 职责 |
|------|------|------|------|
| `check-invariants.sh` | p0 | 已实现 | 快速无网络结构 lint，九项：AGENTS.md 存在 / `docs/agent/architecture.md` 存在且被 AGENTS.md 引用 / `docs/` 下 `_zh`·`_en` 双语配对 / 结构文档双语齐全 / 顶层目录 ↔ `structure_zh.md` 双向对齐 / `docs/design/` 四份权威依据存在 / 账号级全局 IAM 角色的策略 Resource 未钉死 `${REGION}`（多区部署互相覆盖的守卫）/ 脚本与 README 里的 GitHub slug 默认值均为 `aws-samples` / `docs/` 无真实人名与竞品名。由 `test.sh --lint` 与 CI 调用。 |
| `test.sh` | p1 | 已实现 | 分层测试的唯一入口：离线默认（lint + unit + typecheck）/ `--full`（加 e2e；smoke 仍占位）。详见下方「用法」。 |
| `e2e-probe.py` | p1 | 已实现 | `test.sh --full` 的 e2e 组件：对已部署 Runtime 跑真实问答（boto3 InvokeAgentRuntime + 流式），**发送与 gateway 完全一致的 payload** `{prompt, traceId, repos}`。校验只读边界（`permission_denials` 空）、无 `errors`、答案含 `文件:行号` 出处。ARN/region/repos 从 `.local/{deploy-config,projects.json}` 读（不写死）；缺依赖/未部署退出码 2（test.sh 视为 skip，不阻塞）。纯逻辑（region 优先级 / payload 形状）有单测 `tests/test_e2e_probe.sh`。 |
| `lib/common.sh` | p1 | 已实现 | 共享 shell：格式化输出（`say`）+ 依赖检查（`have_cmd` / `require_cmd`）。可被单测 source。 |
| `tests/test_*.sh` | p1 | 已实现 | 纯 bash 单元测试（无外部依赖）；`test.sh` 的 unit 层自动发现并运行。 |
| `check-versions.sh` | p1 | 已实现 | 无网络版本固定防漂移守卫：基础镜像 digest / requirements.txt 全 ==-pin / requirements.lock 一致 / Node 主版本 / claude-code npm pin（**例外：允许 `@latest`，仅 WARN 放行**，运维 2026-06-19 决定 CLI 跟随最新版本）。`test.sh --lint` 调用。 |
| `lib/env-utils.sh` | p1 | 已实现 | `.local/deploy-config` 等 env 文件的读写：`update_env`（单键 upsert）+ `safe_source_env`（容错加载，跳过坏行/CRLF）。有单测 `tests/test_env_utils.sh`。 |
| `install.sh` | p1 | 已实现 | **交互式安装（推荐入口）**：`deploy-all.sh` 的箭头菜单前端——初始化环境 / 添加项目 / 重新部署 / 删除项目。查依赖 + 校验 AWS 凭证后，交互填 projectId / 代码仓（git 或 local）/ 端口 / 模型 / 飞书凭证，把飞书 + git 凭证写进 Secrets Manager、清单写进 `.local/projects.json`，再调 deploy-all / deploy_project。`--yes` 无人值守（首次仍需已存在的飞书密钥），`--local` 单机模式（在索引主机上自动检测并进入）。 |
| `get.sh` | p1 | 已实现 | 一行引导脚本（`curl`/`gh` 取来跑）：把仓库 clone 到当前目录的 `./source-truth`，再交给 `install.sh`；已存在则 fetch + `merge --ff-only` 复用。私有仓自动走 `gh` 认证克隆。环境变量覆盖：`SOURCE_TRUTH_DIR`（克隆目录）、`SOURCE_TRUTH_SLUG`（`owner/repo`，`gh repo clone` 用）、`SOURCE_TRUTH_REPO`（完整 URL，plain `git clone` 用）、`SOURCE_TRUTH_REF`（分支/tag/sha）、`SOURCE_TRUTH_ALLOW_STALE=1`（刷新失败降级为告警）。**指向 fork 时优先设 `SOURCE_TRUTH_SLUG`**：两条克隆路径里 `gh` 已登录时走 `gh repo clone "$SLUG"`，`SOURCE_TRUTH_REPO` 只影响另一条，只设它会在 gh 已登录时仍然克隆上游。 |
| `deploy-all.sh` | p1 | 已实现 | **一键部署（权威入口）**：Phase 0 preflight → 1 artifacts→S3 → 1b IAM → 2 network → 3 index-service(EC2+bootstrap) → 4 镜像 build/push → 5 per-project deploy（activate + Runtime + gateway；`--skip projects` 可跳过）→ 7 monitoring（调 `apply-monitoring.sh`）。幂等，`--dry-run` 无副作用；索引主机始终**就地更新**（基础代码产物有变化时经 SSM 在原实例上重跑 bootstrap，不替换实例、不切 DNS）。`--local`：把整套部署放在当前这台 EC2 上跑、复用本机 VPC（单机模式，见 runbook「在单台 EC2 上就地部署」）。配套 `lib/provision_{iam,network,index_service,index_dns}.sh` + `lib/wait_base_host.sh` + `lib/deploy_runtime.py`（boto3 配置 Runtime）+ `lib/deploy_project.sh` + `lib/activate_gateway.sh`。会话 microVM 不挂任何文件系统，全部源码经 index-service HTTP 接口读取（`codegraph_read_file` / `codegraph_glob_files` / `codegraph_search_files` / `codegraph_read_table` / `codegraph_symbol_search` / `codegraph_get_callers` / `codegraph_analyze_impact`，工具名一律带 `codegraph_` 前缀，见 `docs/agent/invariants.md` §6），仓库副本只在 index-service 本地磁盘。默认模型 `global.anthropic.claude-opus-4-8`（`--model` 可改）。其余参数：`--max-files`（每仓建索引文件数上限，默认 10000）、`--glossary-max-files`（每仓术语表构建文件数上限，默认 0 = 不限；控成本的主要旋钮）、`--idle-timeout`（microVM 空闲回收秒数，默认 900）、`--max-lifetime`（microVM 硬上限秒数，默认 28800）、`--instance-type`（索引主机 EC2 机型，ARM，默认 `t4g.large`）、`--root-volume-gb`（索引主机根卷 GiB，默认 30；大仓需调大）、`--feishu-domain`（`feishu` 中国版 / `lark` 国际版，默认 `feishu`；同时决定事件长连接与 REST base URL）、`--locale`（卡片文案语言 `zh` / `en`，默认随 `--feishu-domain`：`lark` → `en`，否则 `zh`）、`--force`（跳过 Phase 0 硬阻断预检，如 vCPU 配额）。**两个手动前置条件（脚本不自动创建）**：① 飞书 app secret（bot-gateway 需 `FEISHU_APP_ID/SECRET`）；② **Bedrock 访问**：部署身份需有 `bedrock:InvokeModel`；模型推理档由部署按 `--region` 自动解析（`bedrock list-inference-profiles`），解析不确定时 Phase 0 的 invoke 探针会 WARN（非阻断）。 |
| `apply-monitoring.sh` | p1 | 已实现 | **监控栈唯一入口**（deploy-all Phase 7 调用；手动重跑也用它）：按序执行 dashboards → metric-filters（A 类 + by-project）→ alarms → DAU Lambda，各阶段幂等、失败只 WARN 不中断。`--only filters\|dashboards\|alarms\|dau`（可重复）选阶段；单阶段时其余参数（`--namespace`/`--prefix`/`--topic-name`/`--defs`/`--tz` 等）原样转发给该阶段脚本。`--dry-run` 无 AWS 调用。四个阶段实现在 `lib/apply-{metric-filters,dashboards,alarms,dau-lambda}.sh`。 |
| `launch-host.sh` | p1 | 已实现 | `--local`（单台 EC2）模式入口，在**运维本地**跑：选 profile → 建 IAM（`lib/create-iam.sh`）→ 私有仓则把本机 gh token 存进 Secrets Manager → 自动建 source-truth 专用网络（VPC/公私子网/IGW/NAT，复用 `provision_network.sh`）+ host 安全组（只放行运维 IP 的 22）→ 在公有子网起一台 ARM64 EC2 挂好实例角色 → 问 SSH 私钥后 `scp lib/prepare-local-host.sh` 上机并执行。已有 host 默认复用（`--new-host` 强制新建），`--dry-run` 只打印计划，选择记入 `.local/launch-host.<account>.env` 供重跑预填。 |
| `lib/create-iam.sh` | p1 | 已实现 | 建/复用 `--local` 模式的实例角色 `source-truth-index-role` + instance profile，并补部署期权限（命令式 describe-or-create，幂等；角色已存在则只补策略不重建）。由 `launch-host.sh` 内部调用（不作为顶层入口）。 |
| `lib/prepare-local-host.sh` | p1 | 已实现 | 在 `--local` 的全新 EC2 上跑（由 `launch-host.sh` scp 到 `/tmp` 后独立执行的单文件）：装 install.sh 所需依赖（`aws`/`docker`/`git`）→ 用 Secrets Manager 里的 token `gh auth login`（私有仓 clone/Release 下载/升级都靠它）→ 克隆仓库 → `sg docker -c ./scripts/install.sh` 进入交互安装。幂等；`REGION` 必填。 |
| `push-local-repo.sh` | p1 | 已实现 | **客户机侧** local 仓上传：`rsync` over SSH 把本地仓推到索引主机暂存目录 `/data/repo/<subdir>.incoming`，再经 `sudo bash reindex_local_repo.sh <subdir>` 在主机本地同步到正在用的代码目录 `/data/repo/<subdir>`——常规推送由 watcher 增量重建索引、按变更清单增量刷新术语表、不停 bridge（与 git pull 同路径）；首次推送停 bridge 全量建一次图，此时建图与术语表并行。重活交给后台 systemd 单元，推送命令随即返回 `REINDEX_LAUNCHED`（不阻塞、ssh 断开也不影响后台）。用于 `projects.json` 里 `source:"local"` 的仓（无 git remote），重跑即刷新。安全：subdir 正则校验、`--safe-links --no-links` 防软链逃逸、不支持自由 `--ssh-opts`（只认 `--identity`）。`--dry-run` 只打印命令。 |
| `trace.sh` | p1 | 已实现 | 按 traceId 合并查询网关 + agent microVM 两个 log group 的全链路时间线（`--since-hours` 扩窗、`--raw` 不合并、`--runtime <id>` 指定 AgentCore runtime id——默认从 `.local/deploy-config` 的 `RUNTIME_ARN_*` 推导，多项目时取第一条并提示）。排错用：定位一次问答卡在网关、invoke 还是 agent 侧。 |
| `ops.sh` | p2 | 待实现 | 运维工具：status / logs / reindex。（destroy 已拆到 `teardown.sh`）|
| `teardown.sh` | p1 | 已实现 | **有序销毁**：按反依赖顺序删 deploy-all.sh 创建的资源（runtime → EC2 → NAT+EIP → DNS → 子网/路由/IGW/SG → flow logs + 非默认 NACL → VPC → 监控（EventBridge/Lambda/看板/告警/SNS/metric filter）→ ECR），资源从 `.local/deploy-config` 读；读不到则按 `source-truth-*` Name tag 发现（把中途失败遗留的资源也一并兜住）。`--dry-run` 只打印计划；默认交互确认，`--yes` 跳过；IAM 角色 + S3 桶（账号共享）默认保留，`--include-shared` 才删。破坏性操作，见 AGENTS.md「ask first」。 |

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
