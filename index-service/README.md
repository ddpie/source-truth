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

## 实现路线（MVP）

先用 mcp-proxy 类现成桥做 POC 验证，自研只补 git pull / inotify / worktree 生命周期编排，降低风险。
语言与 agent-container / bot-gateway 对齐再定（Python 或 TypeScript）。

## 状态

p0：占位。p1 落地 `src/`（webhook 接收 + worktree 生命周期 + mcp-proxy 类桥封装）。
