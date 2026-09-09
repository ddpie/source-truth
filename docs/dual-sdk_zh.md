# 部署时选择 Agent SDK

每个项目选择 **OpenAI Agents SDK** 或 **Claude Agent SDK**。新项目默认 OpenAI，
问答和离线术语表共用 `agent.sdk`；两者可以选择不同模型。当前两条路径均使用
Amazon Bedrock Runtime 和 AWS 角色凭证，不需要 OpenAI API key。

OpenAI Agents SDK 是应用内的工具编排循环，并非 Codex SDK。拓扑保持为
飞书 → AgentCore microVM → index-service HTTP MCP；源码副本仅在 index 主机。

## 配置

`scripts/install.sh` 默认进入「添加项目」，提供 SDK 选择（默认 OpenAI）及回答模型。
术语表沿用回答模型，避免重复填写；高级部署可在配置中单独设置 `glossaryModel`。
新环境术语表默认关闭，使用 `--with-glossary` 开启，默认每仓上限 400 文件；旧部署保留原选择。
也可编辑 `.local/projects.json` 中的项目：

```json
{
  "agent": {
    "sdk": "openai",
    "provider": "bedrock",
    "endpoint": "runtime",
    "model": "global.openai.gpt-6-astra",
    "glossaryModel": "global.openai.gpt-6-astra",
    "maxTurns": 60
  }
}
```

以上是项目内字段，不是完整文件；完整样例见
[`config/projects.example.json`](../config/projects.example.json)。
切换 Claude 时设置 `sdk: "claude"`，并将两个模型改成对应的
`global.anthropic.claude-opus-4-8` 等 Anthropic 模型。
不配置 `glossaryModel` 时使用回答模型。

部署通过区域的 system inference profile 列表解析同一模型的可用区域前缀，
不会降级到另一模型。默认名称不是所有区域可用的保证；无法查询时部署会告警，
实际可调用性仍需部署后验证。当前部署流程使用 system inference profile；
AWS Converse 也支持 application inference profile，但本项目尚未接入其创建与解析。
当前实现仅接入 `bedrock/runtime`。

**旧项目兼容**：未声明 `schemaVersion: 2` 的旧配置，项目缺少 `agent.sdk` 时继续使用 Claude，
保留原 `model` / `DEPLOY_MODEL`。已有 Runtime 仅带 `ANTHROPIC_MODEL` 时也保持 Claude。
安装器给新项目写明确的 `agent.sdk`，不会把同一文件里的旧项目默认切成 OpenAI。
不要给混合旧文件直接加 `schemaVersion: 2`；先为旧项目补明确的 `agent.sdk`。

选择来自部署配置，不接受问答 payload 覆盖 SDK、模型或 MCP 地址。

## 两条执行路径

| 环节 | OpenAI | Claude |
|---|---|---|
| 在线问答 | `openai-agents` 的 `Runner.run_streamed` | 原 `claude_agent_sdk.query`，保留冷启动重试 |
| 模型接入 | 自定义 `Model` 适配器 → Bedrock `ConverseStream`，AWS SDK SigV4 | `CLAUDE_CODE_USE_BEDROCK=1` |
| 代码工具 | 本机 SDK 调用项目 HTTP MCP；闭合只读白名单 | 同一白名单，通过 Claude MCP 配置 |
| 术语表 | OpenAI Agents SDK，仅当前批次的分页文件读取工具 | 保留已锁定的本地 Claude CLI 构建器 |
| 可观测性 | OpenInference OpenAI Agents scope → ADOT | 原 Claude OpenInference scope → ADOT |

OpenAI 问答和术语表均由 `bedrock_converse.py` 调用 `ConverseStream`，
不调用 `/openai/v1/responses`。OpenAI Agents SDK 继续管理工具循环；适配器将消息、
工具调用及结果转换成 Converse 格式，并完整保留推理块的签名和加密内容。
模型输入由当前调用的完整历史组成，不使用服务端 conversation 或 `previous_response_id`。
适配器只支持本项目所需的文本与本地 function/MCP 工具，不启用托管工具。
禁用重复的 OpenAI 自动插桩，
显式安装 OpenInference processor，替换 SDK 的默认 OpenAI trace exporter。
术语表构建关闭 SDK tracing；AWS 自身日志仍由账户配置控制。

网关消费版本化事件：`text_delta`、`tool_started`、`tool_finished`、
`run_completed`、`run_failed`，均带 `version/runId/seq`。
只有整个 Agent 循环完成、资源清理成功后才发 `run_completed`。
SDK 内部的单轮 `response.completed` 不代表任务完成，也不表示调用了 Responses API；
Converse 缺结束事件、缺 usage、输出截断或被拦截均按失败处理。
缺终态、事件丢失、超限或中断均不能作为成功答案。
网关暂时保留旧 Claude 流格式，支持分阶段升级。

## 升级与切换顺序

1. **以目标主机的完整项目清单为准**：核对 `/etc/source-truth-projects.json`、
   `/etc/index-projects/` 与本地 `.local/projects.json`，备份项目配置、Runtime 版本及镜像摘要。
   网关部署会覆盖共享路由文件，不能拿只包含一个项目的本地文件部署到多项目主机。
2. **先升级共享能力**：发布双 SDK 镜像、索引端构建代码和依赖，补齐两种模型的 IAM 权限，
   并升级能解析新旧协议的网关。已有双 SDK 部署可直接进入下一步。
3. **修改并部署项目选择**：同时设置 `agent.sdk`、`agent.model`、`agent.glossaryModel`，
   用 `install.sh` 的「重新部署现有项目」应用配置。`--model` 只是旧 Claude 配置的回退值。
4. **新会话验证**：等 Runtime 及 DEFAULT 入口 READY，再确认网关重启且 `/ready` 返回 200。
   重启会清除缓存的 Runtime 会话 ID，避免继续复用旧 SDK 的 microVM。
   用符合该项目的代码问题验证实际工具调用、出处及 `run_completed`，并检查下面的术语表状态。

查某次请求实际用了什么时，按卡片 `traceId` 查询对应 Runtime 日志：
`./scripts/trace.sh <traceId> --region <r> --runtime <runtime-id>`。
以该次调用的 `model` / `sdk` / `api` 字段和流事件为准；
OpenAI 新版本记录 `api: "ConverseStream"`。当前配置不会改变过去请求使用的 SDK 或 API。

## 术语表切换与运维

首建、git 定时刷新、本地仓上传均读取同一个项目 SDK 选择。
宿主机配置在 `/etc/index-project-<id>.env`；OpenAI 依赖装到按锁文件摘要隔离的
`/opt/idx/glossary-envs/<hash>`，不修改常驻 index bridge 的 Python 环境。

每个 `<repo>.jsonl.meta` 记录 SDK、模型、区域、API 和提示词的指纹及产物摘要。
这是启用 `GLOSSARY_CONFIG_FILE` 后的构建契约；未迁移的旧 Claude 产物可能没有 `.meta`，
仅升级代码时仍可沿用旧增量路径。显式切换 SDK 时启用指纹检查并全量重建。
文件上限 `GLOSSARY_MAX_FILES` 也计入 format 2 指纹；旧产物在下次启用的刷新中会一次性重建，
禁用术语表时不会仅因升级代码就调用模型。
指纹不匹配时，即使代码没有改动也全量重建；切换或调整上限会产生一次全量模型费用。
从旧 Responses 接入升级到 Converse 同样会触发 OpenAI 术语表全量重建。
重建期间仍可读取上次有效术语表。失败不更新指纹，旧条目保留，下一次刷新重试；
没有定时器的本地仓需重新部署或推送来重试。
增量变化超过文件上限时，未处理路径会保留到后续刷新；Git 的 `.meta` 记录
`pending_files` / `pending_revision`，全部处理后才推进 `source_revision`。
本地仓用 `<repo>.jsonl.pending` 记录未完成变化，下次推送触发增量刷新时继续处理；
显式本地源配置优先于残留的 `.git` 目录。
部署更新与产物发布使用配置锁，旧配置构建不能覆盖新配置产物。
排队的 `glossary_worker.sh` 在取得仓库锁后重新读取当前配置并选择解释器，避免沿用排队前的 SDK。

OpenAI 每批最多 20 个文件，给逐文件读取、分页和最终输出留出执行轮次；
Claude CLI 保留每批 300 文件。每次构建的并发由 `GLOSSARY_BUILD_CONCURRENCY` 控制，
它与跨仓并发叠加；共享主机上应控制同时重建的仓库数。每次构建的文件上限由
`GLOSSARY_MAX_FILES` 决定，全量构建只扫描上限内的候选，增量构建超出的变化留待后续处理。
OpenAI 读取长行时按 `start_line` / `start_column` 续读。候选筛选与来源校验复用
`glossary_source.py`：拒绝凭据、索引内部路径与越界符号链接，并在打开文件时防止路径替换。

术语表构建仍是后台任务：Runtime READY 或部署完成**不表示术语表已经重建成功**。
在 index 主机检查对应构建日志及指纹：

```bash
sudo journalctl -u 'glossary-build-<project>-<repo>.service' -n 80
sudo tail -n 30 /var/log/glossary-build-<project>-<repo>.log
sudo cat /data/glossary/<project>/<repo>.jsonl.meta
```

日志 `glossary_gen_done` 和匹配当前配置的 `.meta` 表示本次构建成功。增量追平还需确认：
Git 的 `pending_files` 为空且 `source_revision` 与当前提交一致；本地仓没有 `.pending` 文件。
`glossary_gen_cc_failed` 或 `glossary_config_rebuild_empty` 表示重建失败。
回滚时恢复项目的 `agent` 配置并重新部署，
两条执行路径一起恢复；旧 SDK 的术语表同样需要重新生成。

在 index 主机做只读指纹核对（替换项目与仓库名；不会触发模型调用）：

```bash
cd /opt/idx/app
sudo python3 - <<'PY'
from pathlib import Path
import shlex
import glossary_config
project, repo = "<project>", "<repo>"
cfg = dict(line.split("=", 1) for line in Path(f"/etc/index-project-{project}.env").read_text().splitlines() if "=" in line)
if cfg.get("GLOSSARY_ENABLED", "true") == "false":
    raise SystemExit("glossary disabled")
expected = glossary_config.fingerprint(
    *(shlex.split(cfg[key])[0] for key in ("AGENT_SDK", "MODEL", "REGION")),
    max_files=int(shlex.split(cfg["GLOSSARY_MAX_FILES"])[0]),
)
print(glossary_config.matches(f"/data/glossary/{project}/{repo}.jsonl", expected))
PY
```

`True` 才表示产物与当前构建配置匹配；事件名中的 `cc` 是历史命名，不能据此判断 SDK。

Runtime 和 index 角色同时保留 Anthropic、OpenAI 模型权限，避免同机不同项目互相撤权。
Converse 使用 `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream`，
没有名为 `bedrock:Converse` 的独立 IAM action。现有策略中的 `project/default`
权限用于兼容旧 Responses 部署；新路径不依赖 Responses 接口。
无须新增 Mantle 权限；现有 NAT 出站仍用于 Bedrock 调用。

## 验证与依赖

固定版本见 `agent-container/requirements.txt`。原 Claude SDK、基础镜像未升级；
新增 OpenAI Agents SDK 0.22.1、OpenAI SDK 3.10.0、OpenInference 2.2.0。
完整 ARM64 依赖锁由 uv 生成，术语表独立锁为其中的子集。
更新后用已安装完整锁的 Python 运行 `scripts/generate-python-licenses.py` 重生成许可表。
CI 用 Python 3.11 安装 agent 完整锁、Python 3.12 分别安装索引与术语表依赖并运行现有测试；
同时用 `generate-python-licenses.py --check` 核对许可元数据。只豁免缺少 ARM64
CodeGraph 二进制的两个集成测试模块，按来源与原因校验，其他跳过均使 CI 失败。

`./scripts/test.sh` 覆盖两套流协议、旧项目默认值、真实 SDK + 本地 HTTP MCP、
模拟 Bedrock 二进制事件流的签名请求、工具循环、推理块续接、越权、超限、截断与取消，
以及术语表切换、grounding 和失败保留。
模型网络在这些测试中被模拟；它们不证明特定 AWS IAM 角色、区域和模型有真实调用权限，
也不替代真实问题的质量与成本评估。
部署默认的 `e2e-probe.py --smoke` 必须观察到成功的 `codegraph_read_file` 或
`codegraph_read_table` 完成事件及源码引用；只有模型写出的文件名不能通过验收。
部署后可运行 `./scripts/test.sh --full` 验证真实 Runtime；这会产生模型调用费用。

官方依据（核对日期：2026-09-09）：

- [OpenAI Agents SDK](https://developers.openai.com/api/docs/guides/agents-sdk)
- [OpenAI 模型与 provider](https://developers.openai.com/api/docs/guides/agents/models)
- [AWS GPT-6 Astra：Converse 支持及区域可用性](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html)
- [AWS Converse 消息与推理上下文](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
- [AgentCore 对 OpenAI Agents 的支持](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-openai-agents.html)
