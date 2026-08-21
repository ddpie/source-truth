# sample-code-qa-on-agentcore

![License: MIT-0](https://img.shields.io/badge/License-MIT--0-blue.svg)
![AWS Bedrock AgentCore](https://img.shields.io/badge/AWS-Bedrock%20AgentCore-orange.svg)
![Engine](https://img.shields.io/badge/Claude-Code%20Agent%20SDK-7c5cff.svg)

> For English documentation, see [README.md](README.md).

> 在飞书里 @ 机器人，用业务语言回答「这个技能 / 数值 / 规则到底怎么算」。答案来自项目**最新主分支的真实代码**，并附可复核的出处。

「这个技能的冷却怎么算」「负重上限和力量是什么关系」——答案都写在代码和配置表里，但策划查不动代码，研发被反复打断。source-truth 让策划在飞书直接问，AI 读真实代码、定位依据，再用业务语言回答。

## 四个特点

- **答得可信，且能复核**：以真实代码为唯一依据，每条结论附 `文件:行号` 出处（折叠在「供研发复核」区）；证据不足时提示转研发，不猜不编。
- **大代码库不拖慢定位**：常驻 CodeGraph 索引先定位、再精准读取。16 GB、7.5 万文件的工程上（其中约
  1.75 千个是被索引的代码文件，其余是美术资源与 `.meta`）定位稳定在 **1–5 毫秒**，整轮问答比原生
  Claude Code 快 **2.7–5.1 倍**（[数据与复现](docs/agent/perf-comparison.md)）。
- **中文提问也能命中英文代码**：「公会战」在代码里可能叫历史代号 `LeagueWar`，直接搜中文常一无所获。术语表离线把中文业务词映射到代码里真实出现的英文符号，作为检索线索；结论仍以查看代码为准（[术语表怎么来的](docs/glossary.md)）。
- **答案是会生长的交互卡片**：在飞书 @ 机器人即可。卡片实时显示进度、结论先行流式展开、能画图表 / 表格、出处自动折叠；点按钮或回复卡片就能带上下文追问，手机同样可用。

## 一次真实问答

飞书群里的真实录屏（接入一套 C++ 服务端代码）：策划问「默认背包有多少格子、怎么扩展」，又追问了仓库格子。卡片实时计时、结论流式展开、出处自动折叠：

![飞书群里一次真实问答的录屏：策划 @机器人提问背包格子，卡片实时显示分析进度与计时，结论先行流式展开，底部「供研发复核」折叠区列出代码出处，可点按钮继续追问](docs/assets/demo-qa.gif)

> 录屏为 3 倍速；卡片标题里的计时是真实耗时（首问 45 秒、追问 1 分 4 秒）。

从提问到出结论，系统内部走这样一条链路——先定位（CodeGraph + 术语表线索）、再精读相关文件、结论流式回填、出处折叠、可带上下文追问：

![一次问答的端到端时序图：飞书客户端、bot-gateway、AgentCore microVM、index-service、CardKit 五方泳道，从 @机器人提问到流式回填结论卡片](docs/assets/sequence-qa.svg)

> 逐步细节见 [`docs/agent/architecture.md`](docs/agent/architecture.md)；需求与架构权威依据见 [`docs/design/`](docs/design/)。

## 能力边界

定位是**只读的代码问答**：只查主分支、只回答，不改动任何东西。明确**不做**：

- 不跑游戏引擎、不做数值模拟
- 不写回代码、不提交、不改任何文件
- 不读设计文档、不跨多分支 / worktree、不做跨会话共享记忆
- 不接第二引擎（Codex）、不做完整的审计防线

规划中的能力见 [`docs/agent/architecture.md`](docs/agent/architecture.md) 与设计文档。

## 系统全貌

飞书客户端 →（经飞书开放平台长连接）网关 → 会话隔离的 microVM → index-service 上的只读代码副本，中间是三个常驻组件。每个会话在各自的 microVM 里互不可见，又都向本项目那份只读副本读代码核对。同一项目下的多仓库联合检索已支持，一台 index-service 主机可承载多个项目（各自独立进程与端口；会话各自跑在独立 microVM 上）。

![source-truth 架构图，按机器分三层：飞书侧 → 一台 EC2（每个项目的 bot-gateway 与 index-bridge 同机，都在 index-service 主机上）→ AgentCore 会话 microVM；事件经长连接推给网关，网关 invoke 会话，会话再经 HTTP 向 bridge 只读访问（定位代码 / 读文件·配置表 / 查术语表）](docs/assets/architecture.svg)

> **会话 microVM 不挂任何文件系统**：源码与配置表都经 index-service 的 HTTP 接口读取（只读文件工具，见 [`docs/agent/architecture.md`](docs/agent/architecture.md)），代码副本只在 index-service 本地磁盘（每项目各一份，不进 microVM、无第二处）。

## 组件一览（monorepo）

| 目录 | 职责 | 语言 |
|------|------|------|
| [`agent-container/`](agent-container/) | 会话 microVM 内运行的 Claude Code Agent：推理 + 编排 + 查代码 | Python |
| [`bot-gateway/`](bot-gateway/) | 飞书 Bot 长连接事件网关 + CardKit 流式卡片渲染 | TypeScript |
| [`index-service/`](index-service/) | 常驻 CodeGraph 索引服务 + MCP-over-HTTP 接口（定位 + 读文件） | Python |
| [`infra/`](infra/) | IaC：AgentCore Runtime / 索引服务 / 网关 | boto3 + CDK（渐进） |
| [`config/`](config/) | 集中配置：i18n 文案、告警阈值 | JSON |
| [`scripts/`](scripts/) | 部署 / 运维 / 测试生命周期 | Bash |

完整目录树见 [`docs/structure_zh.md`](docs/structure_zh.md)。

## 用到的 AWS 服务

部署在单一账号、单一区域（默认东京 `ap-northeast-1`）。核心是一台共用的 ARM EC2（常驻索引）、
每项目一套 Bedrock AgentCore Runtime（会话隔离的 microVM）、Bedrock 模型推理、S3 / ECR。
全部 23 项服务 / 资源的规格 / 数量 / 用途见 [`docs/aws-services_zh.md`](docs/aws-services_zh.md)。

## 前置条件

以下是**部署机**上的要求。部署脚本并不检查全部项，所以每条都标了缺失时的实际行为：

- **硬失败**——`deploy-all.sh` Phase 0 在创建任何计费资源之前就中止
- **告警**——打印一条可操作的警告，部署继续
- **不检查**——没有任何环节校验它，直到用到它的那一步失败才会发现

- **AWS 账号**，具备 EC2 / Bedrock / ECR / S3 / Secrets Manager / IAM 权限——**不逐项检查**。
  安装脚本只验证凭证能解析（`sts get-caller-identity`），缺权限会在部署中途以 API 拒绝的形式暴露。
- **Bedrock AgentCore** 可用（目标区域已开放 Runtime API）——**告警**。用
  `bedrock-agentcore-control list-agent-runtimes` 探测，失败不阻断部署。
- **Bedrock 模型访问**（所选模型）——**告警**。用 1 token 的 `invoke-model` 探测；被拒时部署仍会
  到 READY，但第一次真实提问会失败。
- **AWS CLI v2**（不支持 v1）——但**部署机上不检查版本**：那里只硬检查 `aws` 这个可执行文件存在。
  `aws-cli/2.` 的版本断言在之后的**索引主机**上执行（`index-service/bootstrap.sh`）。
- **Python 3**——**硬失败**——且 **boto3** 需新到含 `bedrock-agentcore-control`（**硬失败**，
  Phase 0 专门探测：Phase 5 是用 boto3 而非 CLI 配置 Runtime 的）。升级用
  `python3 -m pip install -U boto3`；在 PEP-668 系统（较新 macOS/Ubuntu）上要用 virtualenv 或加
  `--break-system-packages`，否则升级会静默无效。
- **Docker**，守护进程在跑、能构建 **linux/arm64**——三项都是**硬失败**（可执行文件、`docker info`
  存活、`docker buildx inspect` 里有 arm64 平台）。Agent 容器只有 ARM64。x86 机器先开模拟：
  `docker run --privileged --rm tonistiigi/binfmt --install arm64`
- **GNU tar**——**硬失败**——macOS 自带的是 BSD tar，产不出可复现归档。缺它则索引主机每次部署都把产物
  判为「有变化」并就地重跑 bootstrap，打断该机上的所有机器人。`brew install gnu-tar` 提供的 `gtar`
  会被自动识别。
- **On-Demand Standard vCPU 配额 ≥ 4**（配额 `L-1216C47A`）——**硬失败**——全新账号常低于索引主机
  （`t4g.large`）所需的 2 vCPU。`--force` 可跳过；EIP / VPC 余量只**告警**。`--local` 模式整段跳过。
- **Session Manager 插件**——⚠️ ***不检查*，且没有任何其他环节检查它。** 但它是每一次验证与日常运维
  的必需品（索引主机在私有子网、不开 SSH），且**不随 AWS CLI 一起安装**；缺它只会在整套栈起好之后、
  执行 `aws ssm start-session` 时才报错。请提前装好：
  [安装指引](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)。
- **git**——**硬失败**（`get.sh` 自己也会硬失败）。**`gh`**（`gh auth login` 登录过）——**告警**，
  仅用于从私有仓的 Release 自动下载 `codegraph-server`。
- **EC2 密钥对**及本地 `.pem`——**不检查**——只有 `--local` 需要（你要 SSH 登录那台主机）。
- **`rsync`**——**部署机上不检查**，且那里只有用 `scripts/push-local-repo.sh` 推本地仓快照时才需要。
  但它在**索引主机上是硬性要求**：每次按项目部署与网关激活都靠
  `rsync -a --delay-updates --delete-after` 把产物发布到正在服务的目录（逐文件 rename，运行中的进程
  保住自己的 inode 不受影响）；`index-service/bootstrap.sh` 与 `scripts/lib/activate_gateway.sh` 缺它时
  会直接 `BOOTSTRAP_FAILED` 中止，而不是做非原子发布。索引主机上无需你手动装——bootstrap 会
  `apt-get install`。
- **`zip`**——**告警**，可选：只有 DAU 预聚合 Lambda 用得到。缺它部署与机器人都正常，只是监控看板的
  日活组件为空。

本机**不需要** Node.js / Python 的**构建**工具链：网关在索引主机上编译，Agent 跑在容器里。上面的
`python3` + `boto3` 是例外——部署脚本本身就跑在它们上面。

## 部署与测试

交互式一键安装（全新账号 / 区域可跑、幂等）。在已配好 AWS 凭证的机器上，一行命令拉起。

仓库公开时，裸 `curl` 即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aws-samples/sample-code-qa-on-agentcore/main/scripts/get.sh)
```

仓库私有时，本机先 `gh auth login`（一次），再用 `gh` 取引导脚本（带认证，无需公开仓库）：

```bash
bash <(gh api repos/aws-samples/sample-code-qa-on-agentcore/contents/scripts/get.sh --jq '.content' | base64 -d)
```

它把仓库克隆到当前目录的 `source-truth/`（可用 `SOURCE_TRUTH_DIR` 覆盖）（私有仓自动走 `gh` 认证克隆），再进入交互式安装。`codegraph-server` 索引引擎缺失时由部署脚本自动下载，无需手动准备二进制。

已克隆仓库则直接跑脚本即可，离线测试无需 Docker / AWS：

```bash
./scripts/install.sh    # 问区域 / 代码仓 / 模型 / 飞书凭证，拉起后端 + 网关
./scripts/test.sh       # 离线套件：lint + unit + typecheck
```

两种部署拓扑：

- **默认（两台）**：在一台部署机上跑脚本，由它新建并配置索引主机 EC2。
- **单台 EC2（`--local`）**：一台机器既跑部署、又常驻索引与网关，不再单开部署机。在本地跑 `./scripts/launch-host.sh`：自动建网 + 建 IAM + 创建 ARM64 EC2，把部署脚本传上机并打印一条 `ssh` 登录命令；按它登录后运行该脚本（装依赖 → 登录 GitHub → 克隆 → 进入 `install.sh` 交互填代码仓/模型/飞书凭证），执行过程逐步可见。AgentCore Runtime 仍由 AWS 托管，不占本机。

完整部署流程（前置条件、`deploy-all.sh` 各阶段的命令行参数、`--local` 的角色与权限要求、连飞书、运维、排错）见
[`docs/runbook_zh.md`](docs/runbook_zh.md)。飞书凭证走 Secrets Manager，不落盘、不入仓库。

**飞书与国际版 Lark 都支持**：用 `--feishu-domain feishu` 接飞书（中国版，默认），
`--feishu-domain lark` 接国际版 Lark。这一个开关同时决定事件长连接与 REST base URL——
只改其中一个，会得到一个「能鉴权、但永远收不到事件」的应用。卡片文案语言由 `--locale zh|en` 决定，
默认随 `--feishu-domain`（`lark` → `en`，否则 `zh`），需要混搭时显式指定（比如国际版 Lark 租户上要
中文卡片）。

## 成本

这套栈是常驻的，起着就在花钱。成本地板由两项永远在跑的资源决定：

| 资源 | 大致成本 |
|------|---------|
| NAT Gateway（一个，常开） | 约 $32/月 + 数据处理费 |
| 索引主机 EC2（默认 `t4g.large`） | 按需约 $50/月 |
| Bedrock 模型调用 | 按 token 计，随提问量增长 |
| 术语表构建（可选，每仓一次性） | 大仓上可能达**数百美元**，见下 |

术语表构建会让模型扫一遍你的源码树，且**默认不设上限**。在一个 1.4 万文件的仓库上实测约 $372。
用 `--glossary-max-files` 给它设上限，或者干脆不开术语表。逐服务的完整清单见
[`docs/aws-services_zh.md`](docs/aws-services_zh.md)。

## 清理

用完记得拆——没有任何资源会自己过期：

```bash
./scripts/teardown.sh --region <r> --dry-run   # 先看删除计划
./scripts/teardown.sh --region <r>             # 删除该区域的资源
./scripts/teardown.sh --region <r> --include-shared   # 连账号级 IAM 角色 + S3 桶一起删
```

默认会**故意保留**几项账号级资源（Secrets Manager 条目、CloudWatch 日志组、产物桶）；teardown 会打印
它保留了什么，剩下的按需手动删。

## 代码怎么进入系统、怎么刷新

每个仓库 clone 到 index-service 本地，file-watcher 增量重建索引。两种代码来源：

- **git 仓**（默认）：systemd timer 定时 `git pull`，主分支改动分钟级内反映到问答、无需重部署、无需手动操作。
- **本地仓**（推不到 git 远端时）：用 `scripts/push-local-repo.sh` 经 rsync 把代码直推到主机，手动刷新——改了代码就重跑一次上传命令。

刷新机制与「为何必须建索引」的实测见 [`docs/agent/architecture.md`](docs/agent/architecture.md) 的「代码如何进入与刷新」一节；本地仓上传与单台 EC2 就地部署（`--local`）见 [`docs/runbook_zh.md`](docs/runbook_zh.md)。

## 安全设计

安全面有三类，且不只靠提示词约束、代码本身会强制执行：**防越权**（Agent 连写工具都不在上下文里，
服务端只注册一组只读工具）、**防泄露**（进群的字段全部脱敏，密钥 / 内网拓扑不进群；凭证走 Secrets Manager 不入库）、
**防注入**（工具读到的代码 / 注释一律当待分析数据，只信打包进镜像的 system prompt）。

![安全设计图：防越权、防泄露、防注入三道由代码强制执行的防线，三栏并列](docs/assets/security-defense.svg)

逐条「怎么强制 / 以谁为准 / 怎么自动检查 / 违反后果」见 [`docs/agent/invariants.md`](docs/agent/invariants.md)。

已知局限：模型可能幻觉、可能被提问里夹带的指令带偏（约束即上面的「答得可信」与三道防线）；
索引刷新是分钟级，刚推的提交需等一个刷新周期才反映。

## 文档导航

| 主题 | 链接 |
|------|------|
| 部署 / 连飞书 / 运维 / 排错（从零到能用） | [`docs/runbook_zh.md`](docs/runbook_zh.md) |
| 一次提问如何在系统里流转 | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| AI 协作约定 | [`AGENTS.md`](AGENTS.md) |
| 需求 / 架构设计权威依据 | [`docs/design/`](docs/design/README.md) |
| 完整文档地图（目录结构、术语表、不变量、变更手册、各调研记录） | [`docs/README.md`](docs/README.md) |

## 许可证

本项目使用 MIT-0 许可证。详见 [LICENSE](LICENSE) 文件。
