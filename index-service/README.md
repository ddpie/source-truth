# index-service

常驻 **CodeGraph 索引服务** + **MCP-over-HTTP 接口**。独立常驻服务（不在会话容器内），持有唯一一份代码本地副本，向会话容器提供只读的「定位 + 读文件」查询。

## 对外接口

CodeGraph 引擎原生仅 stdio MCP，本服务（`http_bridge.py`）把它转成 streamable HTTP 对外提供，供会话容器远程调用。工具分五类：

| 类别 | 工具 | 实现 |
|------|------|------|
| 代码定位 | `codegraph_symbol_search` / `codegraph_get_callers` / `codegraph_analyze_impact` 等 | `codegraph_session.py` |
| 文本检索 | `codegraph_search_files` | `file_search.py` |
| 读文件 | `codegraph_read_file` / `codegraph_glob_files` | `file_read.py` |
| 读数值表 | `codegraph_read_table`（Excel/CSV/TSV/SQLite → 文本） | `file_table.py` |
| 术语表 | `codegraph_glossary_index` / `codegraph_glossary_lookup` | `glossary_read.py` |

读文件 / 检索类替代了会话 agent 的内建 `Read` / `Glob`（agent 侧不挂文件系统，无从直接读）。

## 关键模块

包根布局（**不在 `src/`**）：

| 文件 | 职责 |
|------|------|
| `http_bridge.py` | FastMCP streamable-HTTP 接口（`mcp.server.fastmcp.FastMCP`），注册并对外提供上述工具 |
| `codegraph_session.py` | 常驻 codegraph-server 会话，独占写入 `graph.db`（worker 线程 + 私有事件循环 + 健康自愈 + liveness 容忍） |
| `repo_router.py` | 服务端多仓路由 + 范围强制（多仓隔离不变量 1：白名单默认拒绝，越界 `repo` 参数永不路由） |
| `repo_fanout.py` | 未指定 `repo` 时对每个仓的会话各查一遍再合并结果（纯合并核，无 I/O） |
| `file_read.py` / `file_search.py` / `file_table.py` | 读文件 / 文本检索 / 读数值表三个文件工具 |
| `text_decode.py` | 容错文本解码（仅标准库）：中文游戏仓常为 GBK/GB2312、配置表可能 UTF-16，按编码探测避免乱码 |
| `path_align.py` | 索引路径对齐为仓库相对路径（拒越界） |
| `glossary*.py` / `glossary_refresh.sh` | 术语表数据层 / 只读查询 / 构建期生成（详见 [`docs/agent/glossary.md`](../docs/agent/glossary.md)） |
| `perf.py` | 结构化耗时日志 |
| `bootstrap.sh` | EC2 user-data（base host，不挂项目）：装依赖 / codegraph 二进制 / systemd `index-build`→`index-bridge` 模板；仓库由 `activate_project.sh` 按项目挂载 |

依赖单一来源是 `requirements.txt`（`mcp` + `uvicorn` + `typing_extensions` + `openpyxl`，全部 `==` 固定；`bootstrap.sh` 用 `pip install -r` 安装，`scripts/check-versions.sh` 守卫不漂移）。

## 存储模型（唯一一份代码，本地副本）

仓库副本只在本服务的**本地磁盘** `/data/repo/<subdir>`；codegraph-server 索引它，文件工具也直接读它。会话 microVM **不挂任何文件系统**，全部源码经本服务的 HTTP 接口读取——没有共享挂载，也就没有副本同步问题。代码与索引是部署时快照，刷新靠定时 `git pull` + file-watcher 增量重建。

## 取得 codegraph-server / Obtaining codegraph-server（部署前置）

CodeGraph 引擎是独立的原生二进制 `codegraph-server`，**不在本仓、不由 pip 安装**，也**不由本仓分发**。
上游是公开的 Apache-2.0 Rust 项目 <https://github.com/codegraph-ai/CodeGraph>，本仓只指向它自己的
release 资产。

The engine is a standalone native binary. It is **not in this repository, not installed by pip, and
not redistributed by this sample** — upstream is the public Apache-2.0 Rust project
<https://github.com/codegraph-ai/CodeGraph> and we point at its own release assets.

**约束 / Constraints**

- **架构 / glibc**：会话与 index-service 主机均为 **ARM aarch64**，且需 **glibc ≥ 2.38**（故基础系统
  用 Ubuntu 24.04 / glibc 2.39；Amazon Linux 2023 的 2.34 实测会崩溃）。
  Both hosts are ARM aarch64 and need glibc >= 2.38. An x86_64 build will not run.
- **版本 / Version**：固定 **0.20.1**。`requirements.txt` 的 `mcp==1.23.3` 客户端按此版本验证过协议
  （MCP `2024-11-05`，`codegraph_symbol_search` / `codegraph_get_callers` / `codegraph_analyze_impact`
  三个工具名未变）。此前钉的 0.18.5 **上游没有对应 tag**，外部用户既下载不到也编译不出。
  0.20.1 is protocol-verified against the pinned client. The previously pinned 0.18.5 has no
  upstream tag, so no external user could obtain or build it.

**方式一：下载上游发布的构建 / Route 1 — download the published build**

```bash
gh release download v0.20.1 --repo codegraph-ai/CodeGraph \
  --pattern 'codegraph-server-linux-arm64' --pattern 'codegraph-server-linux-arm64.sha256'
sha256sum -c codegraph-server-linux-arm64.sha256      # 必做 / do not skip
chmod +x codegraph-server-linux-arm64
export CODEGRAPH_SERVER_BIN="$PWD/codegraph-server-linux-arm64"
```

`deploy-all.sh` 在本地和 S3 都找不到时会自动走这条路，并**校验上游随资产发布的 `.sha256`**——校验不过
就中止，不会把来历不明的字节暂存到 S3。该二进制会在索引主机上以 root 运行，所以这一步不可省。
`deploy-all.sh` does this automatically when the binary is neither local nor already staged, and
verifies the published checksum; a mismatch aborts. The binary runs as root on the index host.

**方式二：自己编译 / Route 2 — build from source**

需要 Rust stable。想审计代码、换架构、或钉自己的构建时走这条。
Requires Rust stable. Take this route to audit the code, target a different architecture, or pin a
build of your own.

```bash
git clone https://github.com/codegraph-ai/CodeGraph
cd CodeGraph
cargo build --release -p codegraph-server
export CODEGRAPH_SERVER_BIN="$PWD/target/release/codegraph-server"
# 可选：把自己构建的摘要钉给部署脚本 / optionally pin your own build's digest
export CODEGRAPH_SERVER_SHA256="$(sha256sum "$CODEGRAPH_SERVER_BIN" | awk '{print $1}')"
```

必须在 **ARM aarch64** 上编译（或交叉编译到该目标）——索引主机跑不了 x86_64 产物。上游是个大型
workspace（含约 65 MB C 代码），首次 `--release` 构建耗时可观，请预留时间和磁盘。
Build on ARM aarch64 or cross-compile to it. Upstream is a large workspace (~65 MB of C alongside
the Rust); the first release build takes a while and a fair amount of disk.

**覆盖点 / Override knobs**：`CODEGRAPH_SERVER_BIN`（直接给路径）、`CODEGRAPH_SERVER_REPO` /
`CODEGRAPH_SERVER_TAG` / `CODEGRAPH_SERVER_ASSET`（换来源）、`CODEGRAPH_SERVER_URL`（任意 URL）、
`CODEGRAPH_SERVER_SHA256`（钉摘要）。取得后由部署侧暂存到 `s3://<bucket>/bin/codegraph-server`，
再由 `bootstrap.sh` 拉到 EC2。

**运行时注意 / Runtime notes**：引擎会往自己的 stderr 打 `TEL: {...}` 行；二进制里没有遥测外发端点。
它在首次使用时会拉取 embedding 模型，因此索引主机需要出网（私有子网经 NAT 已具备）。
The engine logs `TEL: {...}` to its own stderr; no outbound telemetry endpoint exists in the binary.
It fetches an embedding model on first use, so the index host needs egress (it has it via NAT).

### 0.18.5 → 0.20.1 契约复验记录 / What was re-verified for the version bump

源码里多处注释写着「verified live against codegraph-server 0.18.5」。那些注释对 0.18.5 是准确的，
换版本时**不应该只把数字改掉**——那等于声称一份没做过的验证。以下是针对 0.20.1 实际跑过的：

Several source comments say "verified live against codegraph-server 0.18.5". Those remain accurate
for 0.18.5; bumping the pin must not simply relabel them, which would assert verification that was
never performed. What was actually exercised against 0.20.1:

| 契约点 / Contract point | 结果 / Result |
| --- | --- |
| MCP 协议版本 / protocol version | `2024-11-05`，与 `mcp==1.23.3` 客户端握手成功 |
| 工具名 / tool names (`EXPOSED_TOOLS`) | `codegraph_symbol_search` / `codegraph_get_callers` / `codegraph_analyze_impact` 三者均在，共 42 个工具 |
| `symbol_search` 信封 / envelope (`repo_fanout.py`) | 顶层含 `results`，与 `_LIST_KEYS` 期望一致 |
| 路径形态 / path form (`path_align.py`) | workspace 传绝对路径时 `location.file` 返回 workspace 绝对路径——即生产形态（`activate_project.sh` 传 `/data/repo/<subdir>`） |
| 架构 / glibc | aarch64 + glibc 2.39 上运行通过；上游 `.sha256` 校验通过 |

**尚未复验 / NOT re-verified against 0.20.1**：`codegraph_session.py` 的 warmup 行为、
`agent_lib.py` 记录的空信封语义、`get_callers` / `analyze_impact` 的返回细节，以及
`path_align.py` 里 workspace 为 `.` 时的 `./`-前缀形态（生产不走这条）。这些仍只对 0.18.5 有实测依据；
升级前若要动这些代码路径，请先自己跑一遍。
These remain empirically grounded only against 0.18.5. Verify them yourself before relying on them.

## 测试

单测见 `index-service/tests/`，经 `./scripts/test.sh`（离线套件）运行。

代码如何进入与索引如何刷新，见 [`docs/agent/architecture.md`](../docs/agent/architecture.md)。
