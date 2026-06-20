# 变更配方（playbooks）

常见改动「怎么做、改哪、怎么验、怎么上线」的操作手册。每个配方都遵守
[`invariants.md`](invariants.md) 的不变量。生效方式分三类，先记住：

- **gateway 改动** → 重启网关即时生效（`bash .local/run-gateway.sh`，单实例）。
- **agent 改动（含 system.md / 工具 / 镜像）** → 重建镜像 + 更新 runtime；**热 microVM 仍跑旧镜像约 15 分钟**才老化。
- **index-service 改动 / 刷新代码索引** → 蓝绿替换 index 实例（`--refresh-index`）。

每次改完都跑 `./scripts/test.sh`（离线套件，pre-push 必过）。

---

## 配方 1：改答案行为 / 输出规范（system prompt）

- **改哪**：`agent-container/prompts/system.md`。
- **注意**：marker 词（`供研发复核` / `你可能还想问` / `需要你确认`）是 gateway 解析器的**中文锚点**，
  prompt 必须要求它们**恒中文、不随回答语言翻译**；依据区必须是**最后一块内容**（gateway 贪婪折叠它之后的一切）。
- **验**：跑 agent-container 单测；改完**必须重部署镜像**才生效（见下），然后 E2E 读卡确认。
- **上线**：

  ```bash
  ./scripts/deploy-all.sh --region ap-northeast-1 --repo <repo> \
    --skip artifacts --skip iam --skip network --skip index-svc
  # 只重建 image + 更新 runtime
  ```

  等热 VM 老化（~15min）后再复测，否则读到的可能仍是旧 prompt 的输出。
- **坑**：preamble/marker 类「读卡发现没生效」八成是热 VM 旧 prompt——先看 deploy 时间，别急着改 gateway 正则兜底。

## 配方 2：加 / 改一个 MCP 工具（index-service 暴露给 agent）

- **改哪**：`index-service/http_bridge.py`（注册 + 处理器，闭合白名单）+ 工具实现（`file_read.py` /
  `file_search.py` / `file_table.py` / `codegraph_session.py`）；**同步** `agent-container/agent_lib.py`
  的 `CODEGRAPH_TOOLS` 允许清单（两端工具名必须一致，否则 agent 调不到或 server 不暴露）。
- **只读约束**：新工具必须只读（`readOnlyHint=True`）；绝不加写/exec 能力（MVP 边界）。
- **路径安全**：任何接受 agent 路径的工具必须经 `path_align.to_local_path`（词法 + realpath 双层 confine）。
- **验**：`cd index-service && python -m pytest -q`；加路径逃逸/注入用例。
- **上线**：蓝绿刷 index（`--refresh-index`）+ 重建镜像（agent 侧允许清单变了）。

## 配方 3：换模型

- **改哪**：`scripts/deploy-all.sh` 的 `DEFAULT_MODEL`，或部署时传 `--model <id>`。
- **注意**：`global.*` 推理档只在部分区域承载；跨区域用区域级档（`apac.*`/`us.*`/`eu.*`）。
  目标区域 Bedrock 控制台需先开通该模型访问。
- **验**：deploy 的 `preflight_model_access` 会探活并对 AccessDenied/不可用给可操作 WARN。
- **上线**：重跑 deploy 的 runtime 阶段（写入 runtime env `ANTHROPIC_MODEL`）。

## 配方 4：刷新代码索引（目标仓库更新了）

- **机制**：索引是部署时快照，靠重新部署 index-service 刷新（无 webhook / 无增量，post-MVP）。
- **做**：

  ```bash
  ./scripts/deploy-all.sh --region ap-northeast-1 --repo /path/to/repo --refresh-index
  ```

  蓝绿替换：新实例建好图、`/health` 通过后，再终止旧实例（不破坏在跑实例）。
- **验**：deploy 内置 SSM `/health` 探活；之后 E2E 问一个只有新代码才有的点。

## 配方 5：改卡片渲染 / 流式 / 脱敏（gateway）

- **改哪**：`bot-gateway/src/` —— 卡片构建 `cardkit-client.ts`、写入队列 `card-writer.ts`、
  抽取器 `extract-*.ts`、规范化 `normalize-blocks.ts`、脱敏 `redact.ts` / `strip-*.ts`、SSE 解析
  `parse-stream.ts`、会话路由 `session-map.ts` / `card-registry.ts`。
- **几条硬规矩**：
  - 正则**行首/行尾的无界量词**（`X*` / `[\s\S]*?`）必查 ReDoS，用有界 `{0,N}`；改完跑超长输入探针。
  - `strip` / `normalize` 与 `redact` 同处一条 pipeline 时，**redact 必须在最后**（strip 重接被切断的 secret）。
  - 卡片正文/证据进 finalize PUT 前要 **clamp 长度**（超 Feishu 卡片体积上限会 400 → CardWriter 吞掉 → 卡死）。
  - 所有进群可见卡片的 agent/仓库派生文本都要过 `redactSensitive`；图表 spec 用 `redactDeep`（只洗 value 不碰 key）。
- **验**：`cd bot-gateway && npx jest`（含 ReDoS / 脱敏 / 抽取回归）。
- **上线**：`bash .local/run-gateway.sh`（杀旧进程、单实例起新的）。

## 配方 6：全新账号 / 新区域一键部署

- 见 [`../runbook.md`](../runbook.md)（前置 → 一条命令 → 连飞书 → 起网关 → 验证 → 运维 → 排错）。
- 幂等：每个资源 describe-or-create，按 tag 复用；中途失败重跑会续上。
- 飞书密钥手工建（Secrets Manager/SSM），编排脚本不自动建。

## 配方 7：改顶层目录 / 加文档

- 改顶层目录 ⇒ 同步 `docs/structure_zh.md` 和 `_en.md`。
- 新增 `docs/*_zh.md` ⇒ 补 `_en.md`（反之亦然）；非双语的运维文档用中性名（如 `runbook.md`）避开配对校验。
- 跑 `./scripts/check-invariants.sh` 确认结构/双语/权威依据校验过。

---

相关：不变量映射见 [`invariants.md`](invariants.md)；架构见 [`architecture.md`](architecture.md)；
部署/运维/排错见 [`../runbook.md`](../runbook.md)。
