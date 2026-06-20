# scripts

运维生命周期脚本（Bash）。

| 脚本 | 阶段 | 状态 | 职责 |
|------|------|------|------|
| `check-invariants.sh` | p0 | ✅ | 快速无网络结构 lint：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录存在性。pre-commit 与 `test.sh --lint` 调用。 |
| `test.sh` | p1 | ✅ | 单一分层测试入口：离线默认（lint + unit + typecheck）/ `--full`（加 smoke / e2e）。详见下方「用法」。 |
| `lib/common.sh` | p1 | ✅ | 共享 shell：格式化输出（`say`）+ 依赖检查（`have_cmd` / `require_cmd`）。可被单测 source。 |
| `tests/test_*.sh` | p1 | ✅ | 纯 bash 单元测试（无外部依赖）；`test.sh` 的 unit 层自动发现并运行。 |
| `check-versions.sh` | p1 | ✅ | 无网络版本钉死防漂移守卫：基础镜像 digest / requirements.txt 全 ==-pin / requirements.lock 一致 / Node 主版本 / claude-code npm pin（**例外：允许 `@latest`，仅 WARN 放行**——运维 2026-06-19 决定 CLI 跟最新）。`test.sh --lint` 调用。 |
| `lib/env-utils.sh` | p1 | ✅ | 读写 `.local/deploy-config` + region 解析（saved > env > aws > default）。有单测 `tests/test_env_utils.sh`。 |
| `deploy-all.sh` | p1 | ✅ | **一键部署（canonical）**：Phase 0 preflight → 1 artifacts→S3 → 1b IAM → 2 network → 3 index-service(EC2+bootstrap) → 4 镜像 build/push → 5 AgentCore Runtime。幂等、`--dry-run` 零副作用、`--refresh-index` 做 index 实例 blue-green。配套 `lib/provision_{iam,network,index_service,index_dns}.sh` + `lib/wait_index_health.sh` + `lib/deploy_runtime.py`（boto3 配 Runtime）。会话 microVM 不挂任何文件系统，全部源码经 index-service HTTP 接口读取（`read_file`/`glob_files`/`search_files`/`read_table`/`codegraph_*`），仓库副本只在 index-service 本地磁盘。默认模型 `global.anthropic.claude-opus-4-8`（`--model` 可改）。**两个手工前置（脚本不自动建）**：① 飞书 app secret（bot-gateway 需 `FEISHU_APP_ID/SECRET`）；② **Bedrock 模型访问**——全新账号须在 Bedrock 控制台为目标模型开通 Model access（`global.*` 跨区域推理需在相关区域分别开通），否则部署照样 READY 但提问会 AccessDenied。Phase 0 已加 model-access 预检，未开通会**显式 WARN + 可操作提示**（非阻断）。 |
| `deploy.sh` | p1 | ⚠️ | 已废弃兼容垫片：转发到 `deploy-all.sh`（旧的 index-service/bot-gateway 阶段曾是桩，会半残部署）。新代码直接用 `deploy-all.sh`。 |
| `ops.sh` | p2 | ⏳ | 运维工具：status / logs / reindex。（destroy 已拆到 `teardown.sh`）|
| `teardown.sh` | p1 | ✅ | **有序销毁**：按反依赖顺序删 deploy-all.sh 建的一切（runtime → EC2 → NAT+EIP → DNS → 子网/路由/IGW/SG → VPC → ECR），资源从 `.local/deploy-config` 读、读不到则按 `source-truth-*` Name tag 发现（覆盖中途崩溃的残留）。`--dry-run` 只打印计划；默认交互确认、`--yes` 跳过；IAM 角色 + S3 桶（账号共享）默认保留，`--include-shared` 才删。破坏性、AGENTS.md「ask first」。 |

## 用法

```bash
./scripts/test.sh           # 离线默认：lint + unit(shell+python) + typecheck（安全、无网络/Docker/AWS）
./scripts/test.sh --lint    # 仅结构自检（= check-invariants.sh）
./scripts/test.sh --unit    # 仅单元测试（shell test_*.sh + 各组件 pytest）
./scripts/test.sh --list    # 列出发现的 shell unit 测试文件
./scripts/test.sh --list-py # 列出发现的 Python 测试目录（<component>/tests）
./scripts/test.sh --full    # 离线套件 + smoke/e2e（占位，待组件落地）
```

退出码 0 = 全绿。unit 层跑两类：`scripts/tests/test_*.sh`（纯 bash）+ 各组件 `<component>/tests/test_*.py`
（pytest）。typecheck 层「缺工具/缺配置则 skip」——离线默认不强制安装 ruff/tsc/pytest。

## 写一个 unit 测试

- **Shell**：新建 `scripts/tests/test_<名>.sh`——纯 bash、可独立 `bash` 运行、退出码 0 = 全绿；
  约定见 `tests/test_common.sh`（`source lib/common.sh` 后用内联断言）。
- **Python**：新建 `<component>/tests/test_*.py`（如 `agent-container/tests/`）——pytest 发现，
  纯函数优先、不触网/不起容器/不 import 未装的 SDK。

## shellcheck 约定

对 `source` 了其他脚本的文件，用 `shellcheck -x`（跟随 source）以消除 SC1091 误报；脚本内已带
`# shellcheck source=...` 指令。
