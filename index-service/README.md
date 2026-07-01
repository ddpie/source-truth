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
| `codegraph_client.py` | 定位类工具的 stdio 调用封装 |
| `file_read.py` / `file_search.py` / `file_table.py` | 读文件 / 文本检索 / 读数值表三个文件工具 |
| `text_decode.py` | 容错文本解码（仅标准库）：中文游戏仓常为 GBK/GB2312、配置表可能 UTF-16，按编码探测避免乱码 |
| `path_align.py` | 索引路径对齐为仓库相对路径（`mount_root` 默认 `""`，拒越界） |
| `glossary*.py` / `glossary_refresh.sh` | 术语表数据层 / 只读查询 / 构建期生成（详见 [`docs/agent/glossary.md`](../docs/agent/glossary.md)） |
| `perf.py` | 结构化耗时日志 |
| `bootstrap.sh` | EC2 user-data（base host，不挂项目）：装依赖 / codegraph 二进制 / systemd `index-build`→`index-bridge` 模板；仓库由 `activate_project.sh` 按项目挂载 |

依赖单一来源是 `requirements.txt`（`mcp` + `uvicorn` + `typing_extensions`，全部 `==` 固定；`bootstrap.sh` 用 `pip install -r` 安装，`scripts/check-versions.sh` 守卫不漂移）。

## 存储模型（唯一一份代码，本地副本）

仓库副本只在本服务的**本地磁盘** `/data/repo/<subdir>`；codegraph-server 索引它，文件工具也直接读它。会话 microVM **不挂任何文件系统**，全部源码经本服务的 HTTP 接口读取——没有共享挂载，也就没有副本同步问题。代码与索引是部署时快照，刷新靠定时 `git pull` + file-watcher 增量重建。

## codegraph-server 二进制来源（部署前置）

CodeGraph 引擎是独立的原生二进制 `codegraph-server`，**不在本仓、不由 pip 安装**，由部署侧暂存到 S3、再由 `bootstrap.sh` 拉到 EC2。约束：

- **架构 / glibc**：会话与 index-service 主机均为 **ARM aarch64**，且 `codegraph-server` 需 **glibc ≥ 2.38**（故基础系统用 Ubuntu 24.04 / glibc 2.39；Amazon Linux 2023 的 2.34 实测会崩溃）。
- **版本**：当前固定 **0.18.5**（`requirements.txt` 的 `mcp==1.23.3` 客户端按此版本验证过协议）。
- **取得方式**：放到部署机 `PATH` 或 `~/.local/bin/codegraph-server`，或用 `CODEGRAPH_SERVER_BIN` 指定。`deploy-all.sh` Phase 1 的获取顺序为本地二进制 → S3 已有 → 从 `CODEGRAPH_SERVER_URL` 下载（默认本仓 Release 资产；私有仓经 `gh release download` 带认证），暂存到 `s3://<bucket>/bin/codegraph-server`；全都拿不到才在 Phase 1 报错并给出可操作提示。

## 测试

单测见 `index-service/tests/`，经 `./scripts/test.sh`（离线套件）运行。

代码如何进入与索引如何刷新，见 [`docs/agent/architecture.md`](../docs/agent/architecture.md)。
