# 变更手册（playbooks）

常见改动「如何做、改哪里、如何验证、如何上线」的操作手册。每个场景都遵守
[`invariants.md`](invariants.md) 的不变量。生效方式分三类，先区分：

- **gateway 改动** → 重新部署该项目网关单元 `bot-gateway@<projectId>.service`（经 `deploy-all.sh` 的 gateway 阶段，每项目一个进程、各连自己的飞书 App）。
- **agent 改动（含 system.md / 工具 / 镜像）** → 重建镜像 + 更新 runtime；**仍存活的 microVM 还会跑旧镜像，约 15 分钟后才被回收换上新镜像**。
- **index-service 代码改动** → 重新部署 index-service（bootstrap + 重启 bridge）；**代码索引刷新无需部署**——定时 `git pull` + watcher 增量重建，分钟级内即跟上最新代码（见场景 4）。

每次改完都运行 `./scripts/test.sh`（离线套件，pre-push 必过）。

---

## 场景 1：改答案行为 / 输出规范（system prompt）

- **修改位置**：`agent-container/prompts/system.md`。
- **注意**：marker 词（`供研发复核` / `你可能还想问` / `需要你确认`）是 gateway 解析器的**中文锚点**，
  prompt 必须要求它们**恒中文、不随回答语言翻译**；依据区必须是**最后一块内容**（gateway 贪婪折叠它之后的一切）。
- **验证**：运行 agent-container 单测；改完**必须重部署镜像**才生效（见下），然后 E2E 读取卡片确认。
- **上线**：

  ```bash
  ./scripts/deploy-all.sh --region ap-northeast-1 --repo <repo> \
    --skip artifacts --skip iam --skip network --skip index-svc
  # 只重建 image + 更新 runtime
  ```

  等旧 microVM 老化（~15min）后再复测，否则读取到的可能仍是旧 prompt 的输出。
- **注意**：preamble/marker 类「读取卡片发现没生效」，多半是因为旧 microVM 还在用旧 prompt——先看 deploy 时间，别急着改 gateway 正则兜底。

## 场景 2：新增 / 修改一个 MCP 工具（index-service 提供给 agent）

- **修改位置**：`index-service/http_bridge.py`（注册 + 处理器，闭合白名单）+ 工具实现（`file_read.py` /
  `file_search.py` / `file_table.py` / `codegraph_session.py`）；**同步** `agent-container/agent_lib.py`
  的 `CODEGRAPH_TOOLS` 允许清单（两端工具名必须一致，否则 agent 无法调用或 server 不注册该工具）。
- **只读约束**：新工具必须只读（`readOnlyHint=True`）；不得增加写/exec 能力（MVP 边界）。
- **路径安全**：任何接受 agent 路径的工具必须经 `path_align.to_local_path`（词法 + realpath 双层 confine）。
- **验证**：`cd index-service && python -m pytest -q`；增加路径逃逸/注入用例。
- **上线**：重新部署 index-service（重启各项目 bridge）+ 重建镜像（agent 侧允许清单已变更）。

## 场景 3：切换模型

- **修改位置**：`scripts/deploy-all.sh` 的 `DEFAULT_MODEL`，或部署时传 `--model <id>`。
- **注意**：`global.*` 推理档只在部分区域承载；跨区域用区域级档（`apac.*`/`us.*`/`eu.*`）。
  目标区域 Bedrock 控制台需先开通该模型访问。
- **验证**：deploy 的 `preflight_model_access` 会检查可用性，并对 AccessDenied/不可用给出可处置的 WARN 提示。
- **上线**：重新运行 deploy 的 runtime 阶段（写入 runtime env `ANTHROPIC_MODEL`）。

## 场景 4：刷新代码索引（目标仓库更新了）

- **机制**：自动。每个仓库一个 systemd timer `index-refresh-<subdir>.timer`（默认 300s，`projects.json`
  的 `refreshIntervalSec` 可配）周期性 `git pull`；常驻 codegraph（`--mcp --graph-only`）进程的
  file-watcher 在数秒内增量重建内存图——无重启、不会有两个进程同时写同一张图、无服务抖动。主分支改动分钟级内反映到问答，**无需重新部署**。
- **改刷新频率 / 加减仓库**：改 `.local/projects.json`，重跑该项目的部署
  （`./scripts/deploy-all.sh ... --skip-base` 或 `install.sh` 的 redeploy 流程），脚本按清单重建 timer / bridge。
- **验证**：`git pull` 失败会打 `GIT_FETCH_FAILED: <subdir>` 标记（可接监控）；端到端可问一个只有新提交才有的问题，确认改动已反映。

## 场景 5：改卡片渲染 / 流式 / 脱敏（gateway）

- **修改位置**：`bot-gateway/src/` —— 卡片构建 `cardkit-client.ts`、写入队列 `card-writer.ts`、
  抽取器 `extract-*.ts`、规范化 `normalize-blocks.ts`、脱敏 `redact.ts` / `strip-*.ts`、SSE 解析
  `parse-stream.ts`、会话路由 `session-map.ts` / `card-registry.ts`。
- **关键规则**：
  - 正则**行首/行尾的无界量词**（`X*` / `[\s\S]*?`）必须检查 ReDoS，用有界 `{0,N}`；修改后运行超长输入探针。
  - `strip` / `normalize` 与 `redact` 同处一条 pipeline 时，**redact 必须在最后**（strip 可能把被切断的 secret 重新拼回完整，故脱敏要收尾）。
  - 卡片正文/证据进 finalize PUT 前要 **clamp 长度**（超 Feishu 卡片体积上限会 400 → CardWriter 丢弃 → 卡片无法完成）。
  - 所有进群可见卡片的 agent/仓库派生文本都要过 `redactSensitive`；图表 spec 用 `redactDeep`（只清理 value，不修改 key）。
- **验证**：`cd bot-gateway && npx jest`（含 ReDoS / 脱敏 / 抽取回归）。
- **上线**：重新部署该项目网关单元 `bot-gateway@<projectId>.service`（deploy-all 的 gateway 阶段）。

## 场景 6：全新账号 / 新区域一键部署

- 见 [`../runbook.md`](../runbook.md)（前置 → 一条命令 → 连飞书 → 起网关 → 验证 → 运维 → 排错）。
- 幂等：每个资源 describe-or-create，按 tag 复用；中途失败后重新运行会继续未完成步骤。
- 飞书密钥由 `install.sh` 交互式创建（Secrets Manager：`source-truth/feishu-<projectId>` + 全局 `source-truth/git-credentials`）；纯 `deploy-all.sh`（CI）要求密钥已存在。

## 场景 7：改顶层目录 / 加文档

- 改顶层目录 ⇒ 同步 `docs/structure_zh.md` 和 `_en.md`。
- 新增 `docs/*_zh.md` ⇒ 补充 `_en.md`（反之亦然）；非双语的运维文档用中性名（如 `runbook.md`）避开配对校验。
- 运行 `./scripts/check-invariants.sh`，确认结构/双语/权威依据校验通过。

---

相关：不变量映射见 [`invariants.md`](invariants.md)；架构见 [`architecture.md`](architecture.md)；
部署/运维/排错见 [`../runbook.md`](../runbook.md)。
