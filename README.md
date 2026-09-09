# source-truth

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![AWS: Bedrock AgentCore](https://img.shields.io/badge/AWS-Bedrock_AgentCore-FF9900)](https://aws.amazon.com/bedrock/agentcore/)
[![OpenAI Agents SDK](https://img.shields.io/badge/OpenAI-Agents_SDK-412991)](docs/dual-sdk_zh.md)
[![Claude Agent SDK](https://img.shields.io/badge/Claude-Agent_SDK-D97757)](docs/dual-sdk_zh.md)

**中文** | [English](#english)

## 中文

**在飞书 / Lark 中，以真实代码为依据进行只读问答，运行于 Amazon Bedrock AgentCore。**

直接提问游戏规则、计算公式或配置如何生效。source-truth 会检索代码仓库、读取实现，再通过流式卡片回答，
附上可复核的文件与行号，供研发、策划、QA 等需要从代码获取答案的人使用。

[快速开始](#快速开始) · [架构](#架构) · [文档导航](#文档导航) · [参与贡献](CONTRIBUTING.md)

### 能做什么

- **基于代码回答**：通过常驻 CodeGraph 索引和只读文件、配置表工具取证，答案附来源，便于核对。
- **连续追问**：CardKit 展示实时进度和流式答案，卡片宽度随聊天窗口调整，提供折叠依据区与推荐问题。
- **部署时选择 SDK**：新项目默认 OpenAI Agents SDK，也支持 Claude Agent SDK；都通过 Amazon Bedrock 调用模型，问答与可选术语表共用项目选择。
- **支持多仓、多项目**：每个项目拥有自己的机器人、Runtime 配置和索引服务进程；可选术语表把中文业务词映射到代码符号。

![飞书问答录屏：流式答案、代码出处与推荐追问](docs/assets/demo-qa.gif)

录屏以 3 倍速播放，卡片计时为实际耗时；用于展示交互，不代表延迟保证。

### 快速开始

需要准备：

- 具备部署权限的 AWS 账户、支持 AgentCore Runtime 的区域，以及所选 Bedrock 模型的访问权限。
- 已启用机器人能力和长连接事件的飞书 / Lark 应用，参见[应用配置](docs/runbook_zh.md#三接入飞书)。
- Linux 或 macOS 操作机，安装 **AWS CLI v2、Python 3 + 较新 boto3、Git、GNU tar，以及可构建 `linux/arm64` 镜像的 Docker**。
- 你有权索引的目标代码仓；私有目标仓需要单独配置只读访问凭证。

依赖安装、ARM 模拟、配额和可选工具见[完整前置条件](docs/runbook_zh.md#一前置条件一次性)。

```bash
git clone https://github.com/ddpie/source-truth.git
cd source-truth
./scripts/install.sh
```

安装器默认进入**添加项目**，底座不存在时自动创建。按提示填写区域、代码仓、SDK/模型和机器人凭证，
完成部署后会用真实代码问题验证。建议区域为东京 `ap-northeast-1`。
租户须与应用匹配：中国版飞书用 `--feishu-domain feishu`（默认），国际版 Lark 用 `--feishu-domain lark`。

新项目默认 **OpenAI Agents SDK**，通过 Bedrock `ConverseStream` 和 AWS 角色凭证调用，
不需要 OpenAI API key。新环境的术语表与监控**按需开启**；已有项目保留原选择。
配置和迁移步骤见[双 SDK 说明](docs/dual-sdk_zh.md)。

部署完成后，在群里 @机器人提问。检查代码出处和末尾的 2–3 个推荐问题按钮，再回复卡片继续追问。
[验收手册](docs/runbook_zh.md#五验证端到端冒烟)包含服务健康及完整飞书链路检查。

配置好 `.local/projects.json` 后，也可先只查看部署计划：

```bash
./scripts/deploy-all.sh --region ap-northeast-1 --dry-run
```

### 架构

![架构：飞书/Lark 连接同一 EC2 上的网关和索引服务，AgentCore 运行 Agent 并通过 HTTP 读取代码](docs/assets/architecture.svg)

1. **bot-gateway** 接收消息，调用项目对应的 AgentCore Runtime。
2. **agent-container** 运行所选 SDK，通过只读 HTTP 工具检索索引、读取源码。
3. **index-service** 保存仓库副本和索引；网关把最终答案流式写回 CardKit。

网关和索引进程共用**一台 EC2**，AgentCore 计算由 AWS 托管。发起安装的机器可以是你的电脑或 CI runner；
另一种 [`--local` 部署方式](docs/runbook_zh.md#手动部署在单台-ec2-上就地安装--local)直接在目标 EC2 上运行安装器。

每次调用创建新的 SDK 会话，只回放当前追问链；空闲 microVM 可以被串行复用。
microVM 挂载隔离的临时存储，**不挂载仓库文件系统**，源码始终经 index-service 读取。
Git 仓默认每 300 秒刷新一次；本地快照通过 [`push-local-repo.sh`](docs/runbook_zh.md#本地仓上传)手动更新。

| 组件 | 职责 |
| --- | --- |
| [agent-container/](agent-container/) | Python Agent、SDK 选择、Bedrock 适配与只读工具编排 |
| [bot-gateway/](bot-gateway/) | TypeScript / Node.js 24 网关、会话路由与流式卡片 |
| [index-service/](index-service/) | CodeGraph、仓库刷新、文件/配置表工具及可选术语表 |
| [scripts/](scripts/) | Bash / AWS CLI / boto3 部署、运维与测试 |
| [infra/](infra/) · [config/](config/) | 监控模板、项目配置示例与卡片多语言文案 |

当前部署使用脚本和 boto3，CDK stack 尚属规划。详见[架构说明](docs/agent/architecture.md)和[目录结构](docs/structure_zh.md)。

### 范围与限制

当前 MVP 提供**配置的主分支代码或上传快照上的只读问答**，不修改或提交代码、不跑游戏引擎、
不做玩法数值模拟，也不检索外部设计文档。多分支分析、共享记忆和 Codex SDK 集成尚不在范围内。

模型可能回答错误，仅靠提示词也无法消除提示注入。重要结论应核对引用源码。
系统分别通过只读工具白名单、服务端仓库与路径检查、AWS 权限和输出脱敏限制风险，
详见[安全不变量](docs/agent/invariants.md)。

新提交须等仓库刷新和索引完成后才会反映到问答。会话路由和追问历史保存在网关内存中，
网关重启可能中断旧卡片的上下文延续。

### 成本与清理

部署会创建付费资源：**EC2/EBS、NAT Gateway、ECR 接口端点、公网 IPv4、模型推理及存储/日志**。
常驻基础设施在无人提问时仍计费。费用取决于区域、模型、流量和启用的功能，
请结合 [AWS 服务清单](docs/aws-services_zh.md)和 [AWS Pricing Calculator](https://calculator.aws/)估算。

可选术语表会产生额外模型调用，部署默认每仓最多处理 **400 个源码文件**；
`--glossary-max-files 0` 才明确表示不限文件数量。文件数上限不是金额预算。
构建细节与历史测量见[术语表指南](docs/glossary.md)。

使用结束后，先查看删除计划，再清理部署：

```bash
./scripts/teardown.sh --region ap-northeast-1 --dry-run
./scripts/teardown.sh --region ap-northeast-1
```

检查脚本最后的保留资源清单：密钥、日志和共享资源可能仍存在。
共享资源删除与多区域检查见[运维手册](docs/runbook_zh.md#六日常运维day-2)。

### 文档导航

| 主题 | 中文 | English |
| --- | --- | --- |
| 部署、飞书/Lark 配置、验证与排错 | [部署手册](docs/runbook_zh.md) | [Runbook](docs/runbook_en.md) |
| OpenAI / Claude 选择与迁移 | [双 SDK 配置](docs/dual-sdk_zh.md) | [SDK configuration](docs/dual-sdk_en.md) |
| AWS 资源与计费项 | [服务清单](docs/aws-services_zh.md) | [Service inventory](docs/aws-services_en.md) |
| 仓库目录布局 | [目录结构](docs/structure_zh.md) | [Structure](docs/structure_en.md) |

[完整文档地图](docs/README.md)还包含架构、术语表、安全及调研记录。
历史[索引性能测量](docs/agent/perf-comparison.md)使用 Claude，不能据此推断 OpenAI 的性能。

### 开发与贡献

按 [CONTRIBUTING.md](CONTRIBUTING.md) 安装开发依赖后运行：

```bash
./scripts/test.sh
```

默认离线运行。留意 `SKIPPED:` 汇总，缺依赖而跳过检查不代表验证通过。
`--full` 还会对已有 AWS 部署发起真实调用，可能产生模型费用。

问题、使用疑问和功能建议请提交到 [GitHub Issues](https://github.com/ddpie/source-truth/issues)，欢迎中英文贡献。
另见[行为准则](CODE_OF_CONDUCT.md)、[安全问题报告](SECURITY.md)和[贡献者](https://github.com/ddpie/source-truth/graphs/contributors)。

### 许可证

[MIT](LICENSE)。第三方许可信息见 [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES)。

## English

**Read-only code Q&A in Feishu / Lark, powered by Amazon Bedrock AgentCore.**

Ask how a game rule, calculation, or configuration works. source-truth searches your repositories,
reads the implementation, and returns an answer with file and line references in a streaming chat card.
It is designed for developers, designers, QA, and other people who need answers from code.

[中文](#中文) | **English**

[Quick start](#quick-start) · [Architecture](#architecture) · [Documentation](#documentation) · [Contributing](CONTRIBUTING.md)

### What it does

- **Grounds answers in code:** uses a resident CodeGraph index and read-only source/configuration tools; answers include references for checking the evidence.
- **Supports contextual follow-ups:** streams progress and answers into CardKit, adapts card width to the chat window, and offers collapsible evidence and suggested questions.
- **Lets you choose the agent SDK:** OpenAI Agents SDK is the default for new projects; Claude Agent SDK is also supported. Both use Amazon Bedrock, and the choice applies to Q&A and optional glossary generation.
- **Connects multiple repositories and projects:** each project has its own bot, Runtime configuration, and index-service process. An optional glossary maps Chinese business terms to code symbols.

![A Feishu Q&A session with a streaming answer, source references, and follow-up questions](docs/assets/demo-qa.gif)

The recording is played at 3× speed; the card timer shows the actual elapsed time. It illustrates the interaction, not a latency guarantee.

### Quick start

You need:

- An AWS account with deployment permissions, an AgentCore Runtime supported region, and access to your selected Bedrock model.
- A Feishu or Lark app with bot capability and long-connection events configured. Follow the [app setup guide](docs/runbook_en.md#3-connecting-feishu--lark).
- A Linux or macOS deployment machine with **AWS CLI v2, Python 3 + recent boto3, Git, GNU tar, and Docker capable of building `linux/arm64` images**.
- A repository you are authorized to index. Private target repositories need their own read credentials.

See the [detailed prerequisites](docs/runbook_en.md#1-prerequisites-one-time) for installation, ARM emulation, quotas, and optional tools.

```bash
git clone https://github.com/ddpie/source-truth.git
cd source-truth
./scripts/install.sh
```

The installer defaults to **add project** and creates the shared environment if needed. It asks for the
region, target repositories, SDK/model, and bot credentials, then deploys and verifies a real code question.
Tokyo (`ap-northeast-1`) is the suggested region. Choose the tenant that matches your app:
`--feishu-domain feishu` for Feishu (default), or `--feishu-domain lark` for international Lark.

New projects default to **OpenAI Agents SDK**. The OpenAI path uses Bedrock `ConverseStream` with AWS role
credentials; no OpenAI API key is needed. Glossary generation and monitoring are **opt-in** for new
environments. Existing projects retain their choices. See [SDK configuration and migration](docs/dual-sdk_en.md).

When deployment completes, @-mention the bot with a code question. Check the source references and
2–3 suggested follow-up buttons, then reply to the card to continue. The [verification guide](docs/runbook_en.md#5-verification-end-to-end-smoke-test)
covers service health and the full chat flow.

For a preview without creating resources, after configuring `.local/projects.json`:

```bash
./scripts/deploy-all.sh --region ap-northeast-1 --dry-run
```

### Architecture

![Architecture: Feishu/Lark connects to gateway and index services on one EC2 host; AgentCore runs the agent and reads code through HTTP](docs/assets/architecture.en.svg)

1. **bot-gateway** receives chat events and invokes the project's AgentCore Runtime.
2. **agent-container** runs the chosen SDK, searches the index, and reads source through read-only HTTP tools.
3. **index-service** holds the repository copies and indexes. The gateway streams the resulting answer back to CardKit.

Gateway and index processes share **one EC2 host**; AgentCore compute is AWS-managed. The machine running
the installer can be your laptop or CI runner. The alternative [`--local` deployment](docs/runbook_en.md#manual-deploy-install-in-place-on-a-single-ec2---local)
runs the installer on the EC2 host itself.

Each invocation starts a fresh SDK session and replays only its follow-up chain. Idle microVMs may be
reused serially. They mount isolated temporary storage, **not repository filesystems**: repository reads
always go through index-service. Git repositories refresh on a timer (300 seconds by default); local
snapshots are refreshed with [`push-local-repo.sh`](docs/runbook_en.md#local-repository-upload).

| Component | Purpose |
| --- | --- |
| [agent-container/](agent-container/) | Python agent, SDK selection, Bedrock adapter, and read-only tool orchestration |
| [bot-gateway/](bot-gateway/) | TypeScript / Node.js 24 gateway, conversation routing, and streaming cards |
| [index-service/](index-service/) | CodeGraph, repository refresh, file/configuration tools, and optional glossary |
| [scripts/](scripts/) | Bash / AWS CLI / boto3 deployment, operations, and tests |
| [infra/](infra/) · [config/](config/) | Monitoring templates, project configuration example, and localized card text |

Deployment currently uses scripts and boto3. CDK stacks are planned. See the [architecture details](docs/agent/architecture.md) (Chinese) and [directory map](docs/structure_en.md).

### Scope and limitations

The current MVP provides **read-only Q&A over configured main-branch code or uploaded snapshots**.
It does not edit or commit code, run a game engine, simulate gameplay, or search external design documents.
Multi-branch analysis, shared memory, and Codex SDK integration are outside the current scope.

Model answers can be wrong, and prompt injection cannot be eliminated by instructions alone. Check the
cited code for important decisions. Read-only tool allowlists, server-side repository/path checks,
AWS permissions, and output redaction provide separate controls; see [security invariants](docs/agent/invariants.md) (Chinese).

Fresh commits appear after repository refresh and indexing complete. Conversation routing and follow-up
history are held in gateway memory, so a gateway restart can interrupt continuation of earlier cards.

### Costs and cleanup

A deployment creates billable AWS resources: **EC2/EBS, NAT Gateway, ECR interface endpoints, public IPv4,
model inference, and storage/logging**. The resident infrastructure incurs costs while running, including
when nobody is asking questions. Rates depend on region, model, traffic, and enabled features; use the
[AWS service inventory](docs/aws-services_en.md) and [AWS Pricing Calculator](https://calculator.aws/) to estimate your deployment.

Optional glossary generation makes additional model calls. Its deployment default is **400 source files
per repository**; `--glossary-max-files 0` explicitly removes that file cap. File count is not a dollar budget.
Details and historical measurements are in the [glossary guide](docs/glossary.md) (Chinese).

When finished, review the deletion plan and remove the deployment:

```bash
./scripts/teardown.sh --region ap-northeast-1 --dry-run
./scripts/teardown.sh --region ap-northeast-1
```

Read the retained-resource summary: secrets, logs, and shared resources can remain. The
[cleanup guide](docs/runbook_en.md#6-day-2-operations) explains shared-resource removal and multi-region checks.

### Documentation

| Start here for… | English | 中文 |
| --- | --- | --- |
| Deployment, Feishu/Lark setup, verification, and troubleshooting | [Runbook](docs/runbook_en.md) | [部署手册](docs/runbook_zh.md) |
| OpenAI / Claude selection and migration | [SDK configuration](docs/dual-sdk_en.md) | [双 SDK 配置](docs/dual-sdk_zh.md) |
| AWS resources and billing dimensions | [Service inventory](docs/aws-services_en.md) | [服务清单](docs/aws-services_zh.md) |
| Repository layout | [Structure](docs/structure_en.md) | [目录结构](docs/structure_zh.md) |

The [full documentation map](docs/README.md) also links architecture, glossary, security, and research notes.
Historical [index benchmarks](docs/agent/perf-comparison.md) used Claude; they do not establish OpenAI performance.

### Development and contributing

Follow [CONTRIBUTING.md](CONTRIBUTING.md) to install development dependencies, then run:

```bash
./scripts/test.sh
```

The default suite is offline. Read any `SKIPPED:` summary; missing dependencies are not a successful
verification. `--full` additionally exercises an existing AWS deployment and can incur model charges.

Use [GitHub Issues](https://github.com/ddpie/source-truth/issues) for bugs, questions, and feature proposals.
Contributions in English or Chinese are welcome. See the [Code of Conduct](CODE_OF_CONDUCT.md),
[security reporting instructions](SECURITY.md), and [contributors](https://github.com/ddpie/source-truth/graphs/contributors).

### License

[MIT](LICENSE). Third-party licensing information is in [THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES).
