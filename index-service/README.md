# index-service

常驻 **CodeGraph 索引服务** + **MCP-over-HTTP 接口**。

## 职责

独立常驻服务（非会话容器内）。一句话管线：deploy 时打包仓库 tar.gz→S3 → `bootstrap.sh` 首次解包到
**本服务本地磁盘** `/data/repo/<subdir>` → `index-build` 一次性建图 → `codegraph-server --mcp` 常驻只读。
对会话容器只暴露一件事——

**MCP-over-HTTP 接口**（`http_bridge.py`）：CodeGraph 原生仅 stdio MCP，本服务把它暴露为 streamable HTTP，
供会话容器远程**定位 + 读文件**——定位类 `codegraph_symbol_search` / `codegraph_get_callers` /
`codegraph_analyze_impact`，文本检索 `codegraph_search_files`，读文件 `codegraph_read_file` /
`codegraph_glob_files`，以及读数值表 `codegraph_read_table`（Excel/CSV/TSV/SQLite，对应 `file_table.py`）
（替代会话 agent 的内建 `Read`/`Glob`）。

## 存储模型（唯一一份代码，本地副本）

仓库副本只在本服务的**本地磁盘** `/data/repo/<subdir>`；codegraph-server 索引该本地副本，文件读取工具
也直接读它。会话 microVM **不挂任何文件系统**，全部源码经本服务的 HTTP 接口读取，没有共享挂载，因此不存在副本同步问题。代码与索引是**部署时快照**，刷新靠重部署。

## codegraph-server 二进制来源（部署前置）

CodeGraph 引擎是一个独立的原生二进制 `codegraph-server`，**不在本仓、不由 pip 安装**，
由部署侧暂存到 S3、再由 `bootstrap.sh` 拉到 index-service EC2。约束：

- **架构 / glibc**：会话与 index-service 主机是 **ARM aarch64**，且 `codegraph-server` 需
  **glibc ≥ 2.38**（故基础系统用 Ubuntu 24.04 / glibc 2.39，Amazon Linux 2023 的 2.34 实测崩）。
- **版本**：当前钉 **0.18.5**（`requirements.txt` 的 `mcp==1.23.3` 客户端按此版本验证过协议）。
- **取得方式**：从 CodeGraph 官方发布渠道下载对应版本的 aarch64 二进制，放到部署机 `PATH`
  或 `~/.local/bin/codegraph-server`，或用环境变量 `CODEGRAPH_SERVER_BIN=/path/to/codegraph-server`
  指定。`deploy-all.sh` Phase 1 会优先用本地二进制暂存到 `s3://<bucket>/bin/codegraph-server`；
  若本地与 S3 都没有则**在 Phase 1 直接报错并给出可操作提示**。

## 模块构成

资源化于包根（**不在 `src/`**）：`http_bridge.py`（FastMCP streamable-HTTP 接口，用 `mcp`
内置的 `mcp.server.fastmcp.FastMCP`）、`codegraph_session.py`（常驻会话，独占写入 graph.db：worker 线程 + 私有
事件循环 + 健康自愈 + liveness 连续失败容忍）、`codegraph_client.py`（定位类工具的 stdio 调用封装）、
`file_read.py` / `file_search.py` / `file_table.py`（三个文件工具：读文件 / 文本检索 / 读数值表）、
`path_align.py`（索引路径对齐为仓库相对路径，`mount_root` 默认 `""`）、`perf.py`（结构化耗时日志）、
`bootstrap.sh`（EC2 user-data：装依赖 / 本地解包仓库到 `/data/repo` / systemd `index-build`→`index-bridge`）。
依赖单一来源是 `requirements.txt`（`mcp` + `uvicorn` + `typing_extensions`，全部 `==` 钉死；
`bootstrap.sh` 用 `pip install -r` 安装；`scripts/check-versions.sh` 守卫不漂移）。数据面见
`docs/agent/architecture.md`。
