# scripts

运维生命周期脚本（Bash）。

| 脚本 | 阶段 | 状态 | 职责 |
|------|------|------|------|
| `check-invariants.sh` | p0 | ✅ | 快速无网络结构 lint：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录存在性。pre-commit 与 `test.sh --lint` 调用。 |
| `test.sh` | p1 | ✅ | 单一分层测试入口：离线默认（lint + unit + typecheck）/ `--full`（加 smoke / e2e）。详见下方「用法」。 |
| `lib/common.sh` | p1 | ✅ | 共享 shell：格式化输出（`say`）+ 依赖检查（`have_cmd` / `require_cmd`）。可被单测 source。 |
| `tests/test_*.sh` | p1 | ✅ | 纯 bash 单元测试（无外部依赖）；`test.sh` 的 unit 层自动发现并运行。 |
| `check-versions.sh` | p1 | ⏳ | 版本钉死防漂移守卫（Claude Agent SDK / lark-cli / 基础镜像）。 |
| `lib/config.sh` | p1 | ⏳ | 读写 `.local/deploy-config` + region 解析（saved > env > aws > default）。 |
| `deploy.sh` | p1 | ⏳ | 编排三组件部署：index-service → AgentCore Runtime(boto3) → bot-gateway（幂等 = 升级）。 |
| `ops.sh` | p2 | ⏳ | 运维工具：status / logs / reindex / destroy。 |
| `teardown.sh` | p2 | ⏳ | 有序销毁 + 保留资源清单。 |

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

状态：p0/p1 部分已落地（见上表 ✅），其余随阶段补全。
