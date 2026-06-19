# index-service

常驻 **CodeGraph 索引服务** + **MCP-over-HTTP 桥**。

## 职责

> ⚠️ **本节（下列 1/2 项）是目标形态，当前 MVP 未实现**：当前没有 git clone / webhook / git pull /
> inotify 增量 / 夜间 CI。**MVP 实况**＝ deploy 时打包仓库 tar.gz→S3 → bootstrap 首次解包到**本服务本地磁盘**
> `/data/repo/<subdir>` → index-build 一次性建图 → `codegraph-server --mcp` 常驻只读，**刷新靠重部署**。只有
> 第 3 项（MCP-over-HTTP 桥，含定位 + 文件读取工具）已落地（即 `http_bridge.py`）。详见文末「实现现状」与
> `docs/agent/architecture.md` 数据面。

独立常驻服务（非会话容器内），**目标形态**：

1. **持 clone + 同步**（目标，未实现）：内网 GitLab 反向拉取 / 打包至 AWS；`git push` → webhook →
   `git pull`（~1s）写本地仓库副本（MVP 仅 main 分支）。
2. **增量索引**（目标，未实现）：`inotify` 监听本地仓库副本变更 → CodeGraph（Tree-sitter）增量重建
   调用关系图（~3s）；夜间 CI 全量重建兜底。
3. **MCP-over-HTTP 桥**（已落地）：CodeGraph 原生仅 stdio MCP，把它暴露为 streamable HTTP，
   供会话容器远程**定位 + 读文件**——定位类 `codegraph_symbol_search` / `codegraph_get_callers` /
   `codegraph_analyze_impact`，文本检索 `codegraph_search_files`，以及读文件 `codegraph_read_file` /
   `codegraph_glob_files`（替代会话 agent 原本的内建 `Read`/`Glob`）。

## 存储模型（唯一一份代码，本地副本）

仓库副本只在本服务的**本地磁盘** `/data/repo/<subdir>`；codegraph-server 索引该本地副本，文件读取工具
也直接读它。会话 microVM **不挂任何文件系统**，全部源码经本服务的 HTTP 桥读取——既无 EFS、也无 `/mnt/repo`
共享挂载，因此不存在副本同步问题。代码与索引是**部署时快照**，刷新靠重部署（非随 push 更新）。

## 待 POC 验证（影响架构定型）

- CodeGraph 对 Unity 风格 C# / Node.js / Lua 动态模式的召回率；
- push→索引端到端时延 + 首次全量索引耗时（社区 13 万文件约 1 小时量级）；
- stdio→HTTP 桥的稳定性、并发、路径对齐（工具返回路径为仓库相对，如 `Assets/Scripts/Foo.cs`）；
- 本地仓库副本上 inotify 增量索引的可靠性（post-MVP）；
- 经 HTTP 桥读文件的延迟（点读 vs 全仓文本检索兜底）。

## codegraph-server 二进制来源（部署前置）

CodeGraph 引擎是一个独立的原生二进制 `codegraph-server`，**不在本仓、不由 pip 安装**，
由部署侧暂存到 S3、再由 `bootstrap.sh` 拉到 index-service EC2。约束：

- **架构 / glibc**：会话与 index-service 主机是 **ARM aarch64**，且 `codegraph-server` 需
  **glibc ≥ 2.38**（故基础系统用 Ubuntu 24.04 / glibc 2.39，Amazon Linux 2023 的 2.34 实测崩）。
- **版本**：当前钉 **0.18.5**（`requirements.txt` 的 `mcp==1.23.3` 客户端按此版本验证过协议）。
- **取得方式**：从 CodeGraph 官方发布渠道下载对应版本的 aarch64 二进制，放到部署机 `PATH`
  或 `~/.local/bin/codegraph-server`，或用环境变量 `CODEGRAPH_SERVER_BIN=/path/to/codegraph-server`
  指定。`deploy-all.sh` Phase 1 会优先用本地二进制暂存到 `s3://<bucket>/bin/codegraph-server`；
  若本地与 S3 都没有则**在 Phase 1 直接报错并给出可操作提示**（不再拖到 Phase 4 健康超时才暴露）。

## 实现现状

已实现（资源化于包根，**不在 `src/`**）：`http_bridge.py`（FastMCP streamable-HTTP 桥，用 `mcp`
内置的 `mcp.server.fastmcp.FastMCP`）、`codegraph_session.py`（常驻单写者会话：worker 线程 + 私有
事件循环 + 健康自愈）、`path_align.py`（索引路径对齐为仓库相对路径；`mount_root` 默认 `""`，遗留
`/mnt/repo` 值仍兼容但生产不用）、`perf.py`（结构化耗时日志）、`bootstrap.sh`（EC2 user-data：装依赖 /
本地解包仓库到 `/data/repo` / systemd `index-build`→`index-bridge`）。
依赖单一来源是 `requirements.txt`（`mcp` + `uvicorn` + `typing_extensions`，全部 `==` 钉死；
`bootstrap.sh` 用 `pip install -r` 安装；`scripts/check-versions.sh` 守卫不漂移）。

> 注：上文「持 clone / inotify 增量 / mcp-proxy / src/」描述的是早期规划形态；当前 MVP 实为
> 本地仓库副本 + 常驻单写者会话直连 `codegraph-server --mcp` + 经 HTTP 桥的文件读取工具；索引是
> **部署时一次性快照、刷新靠重部署**（无 webhook / git pull / file-watcher 增量，留作 post-MVP）。
> 与 `docs/agent/architecture.md` 数据面一致。
