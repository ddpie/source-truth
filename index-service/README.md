# index-service

常驻 **CodeGraph 索引服务** + **MCP-over-HTTP 桥**。

## 职责

独立常驻服务（非会话容器内）：

1. **持 clone + 同步**：内网 GitLab 反向拉取 / 打包至 AWS；`git push` → webhook → `git pull`（~1s）写
   EFS worktree（MVP 仅 main 分支）。
2. **增量索引**：`inotify` 监听 EFS worktree 变更 → CodeGraph（Tree-sitter）增量重建调用关系图（~3s）；
   夜间 CI 全量重建兜底。
3. **MCP-over-HTTP 桥**：CodeGraph 原生仅 stdio MCP，用 mcp-proxy 类组件把它暴露为 streamable HTTP，
   供会话容器远程查询（`codegraph_search` / `codegraph_callers` / `codegraph_impact` 等）。

## 存储模型（单一份代码，无副本）

EFS 卷被本服务**可写**挂载（建索引），被每个会话 microVM **只读**挂载 `/mnt/repo`（读最新代码）。
AI 通过索引定位文件后读的是代码最新版本，不是索引快照。

## 待 POC 验证（影响架构定型）

- CodeGraph 对 Unity 风格 C# / Node.js / Lua 动态模式的召回率；
- push→索引端到端时延 + 首次全量索引耗时（社区 13 万文件约 1 小时量级）；
- stdio→HTTP 桥的稳定性、并发、路径对齐（工具返回路径 vs 容器挂载路径）；
- EFS 同卷并发挂载 + NFS 上 inotify 可靠性；
- EFS 读性能（点读 vs 全仓兜底）。

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
事件循环 + 健康自愈）、`path_align.py`（索引路径 → `/mnt/repo` 对齐）、`perf.py`（结构化耗时日志）、
`bootstrap.sh`（EC2 user-data：装依赖 / 挂 EFS / systemd `index-build`→`index-bridge`）。
依赖单一来源是 `requirements.txt`（`mcp` + `uvicorn` + `typing_extensions`，全部 `==` 钉死；
`bootstrap.sh` 用 `pip install -r` 安装；`scripts/check-versions.sh` 守卫不漂移）。

> 注：上文「持 clone / inotify 增量 / mcp-proxy / src/」描述的是早期规划形态；当前 MVP 实为
> EFS 只读挂载 + 常驻单写者会话直连 `codegraph-server --mcp`，索引随主机 file-watcher 增量。
