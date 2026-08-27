# 部署与运维手册（runbook）

从零部署 source-truth、接入飞书并完成日常运维的指引。工作原理见
[`agent/architecture.md`](agent/architecture.md)；本文只讲**怎么做**。

系统分两部分，由部署脚本一并启动：**后端**（S3 产物 → IAM → 网络 → index-service EC2 → 镜像 → AgentCore Runtime）和 **bot-gateway**（飞书长连接网关，与索引服务同主机，将群聊中 @ 机器人的消息路由到后端、答案流式写回卡片）。

部署入口有 `install.sh`（交互式，推荐）与 `deploy-all.sh`（命令行传参，适合 CI）；安装可从单独的操作机一键发起，或登录目标主机手动逐步发起（`--local`）。「快速开始」给出各自的命令，选型细节见[第二节](#二一键安装交互式推荐)。所有部署都**幂等**：中断后重跑，从断点继续。

## 快速开始

最简部署步骤，详细说明见后续各节。前提：本机已安装 `aws` CLI 并配置好凭证；飞书应用已按[第三节](#三接入飞书)创建，取得 `App ID` / `App Secret` / 机器人 `open_id`。

两种方式二选一——**一键部署**（默认，从一台操作机远程装好）或**手动部署**（`--local`，登录目标 EC2 逐步执行）；两者运行时都只有一台 EC2 跑服务，区别在从哪台机器发起安装，选型细节见[第二节](#二一键安装交互式推荐)。选定后只按对应一种执行。

### 方式 A · 一键部署（默认）

在操作机（你的电脑或 CI）上执行：

```bash
git clone https://github.com/aws-samples/sample-code-qa-on-agentcore.git && cd sample-code-qa-on-agentcore
./scripts/install.sh          # 按交互提示填写区域 / 代码仓 / 飞书凭证，一次装好后端与网关
```
详见[第二节](#二一键安装交互式推荐)；完成后按[第五节](#五验证端到端冒烟)验证。

### 方式 B · 手动部署（`--local`）

分三步：**创建主机 → 部署服务 → 推送代码**。

**第一步 · 创建主机**（本机执行）：创建 EC2 实例，脚本结束时会输出一条登录用的 `ssh` 命令，供下一步使用。

```bash
git clone https://github.com/aws-samples/sample-code-qa-on-agentcore.git && cd sample-code-qa-on-agentcore
./scripts/launch-host.sh
```

**第二步 · 部署服务**（用上一步输出的 `ssh` 命令登录实例后执行）：按 `install.sh` 的交互提示填写代码仓 / 模型 / 飞书凭证，完成后后端三个组件（bridge、runtime、gateway）全部就绪。

```bash
bash /tmp/prepare-local-host.sh   # 建议直接复制 launch-host 输出的命令
```

**第三步 · 推送代码**（本机执行，仅本地仓需要）：本地仓须先推送代码，机器人方可应答；此后每次代码变更，重新推送即完成刷新。

```bash
./scripts/push-local-repo.sh --host <ssh-host> [--identity <key>] <子目录> <本地路径>
```

各步细节（SSH 私钥、私有仓凭证、首次推送建立索引等）见[第二节末「手动部署：在单台 EC2 上就地安装」](#手动部署在单台-ec2-上就地安装--local)与[第九节末「本地仓上传」](#本地仓上传)；首次部署完成后按[附录 C](#附录-c首次部署后的真机核对清单)逐项核对。

**目录**

0. [快速开始](#快速开始)
1. [前置条件（一次性）](#一前置条件一次性)
2. [一键安装（交互式，推荐）](#二一键安装交互式推荐)
   - [手动部署：在单台 EC2 上就地安装（`--local`）](#手动部署在单台-ec2-上就地安装--local)
3. [接入飞书](#三接入飞书)
4. [网关运行位置](#四网关运行位置)
5. [验证（端到端冒烟）](#五验证端到端冒烟)
6. [日常运维（day-2）](#六日常运维day-2)
7. [多项目（一台机器多个机器人）](#七多项目一台机器多个机器人)
8. [排错（症状 → 原因 → 处置）](#八排错症状--原因--处置)
9. [边界与安全（务必知道）](#九边界与安全务必知道)
- [附录 A：手动 deploy-all.sh](#附录-a手动-deploy-allsh)
- [附录 B：本地手动启动网关（开发调试）](#附录-b本地手动启动网关开发调试)
- [附录 C：首次部署后的真机核对清单](#附录-c首次部署后的真机核对清单)
- [附录 D：手动刷新监控](#附录-d手动刷新监控)
- [附录 E：可观测性（AgentCore span 与 trace）](#附录-e可观测性agentcore-span-与-trace)
- [附录 F：评估（AgentCore Evaluations）](#附录-f评估agentcore-evaluations)

---

## 一、前置条件（一次性）

1. **AWS 账号 + 目标区域**：区域须支持 AgentCore（如 `ap-northeast-1` 东京）。本机配好可部署的 AWS 凭证。
2. **部署机（Linux 或 macOS）**：以下是部署**真正会检查并硬失败**的清单（与
   [`../README_zh.md`](../README_zh.md) / [`../README.md`](../README.md) 的 Prerequisites 一致）：

   - **`aws` CLI v2**——不支持 v1。
   - **`python3`**，且 **boto3 版本足够新、带 `bedrock-agentcore-control`**（配置 Runtime 用）。
     升级：`python3 -m pip install -U boto3`；在 PEP-668 系统（较新的 macOS / Ubuntu）上须用
     virtualenv 或加 `--break-system-packages`，否则升级会静默无效。
   - **Docker 且守护进程在运行**，并且能构建 **linux/arm64**（agent 容器只有 ARM64；Phase 4 要构建
     镜像，只装不启动会在依赖检查就被拦下，提示 `docker info` 验证）。x86 主机先装模拟器：
     `docker run --privileged --rm tonistiigi/binfmt --install arm64`。
   - **GNU tar**——macOS 自带的是 BSD tar，产不出可复现的归档；缺了它索引主机会把产物判定为「每次
     部署都变了」，于是每次都就地重跑 bootstrap，打断这台机器上的所有机器人。`brew install gnu-tar`
     装出的 `gtar` 会被自动识别。
   - **[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)**——验证与所有 day-2 运维都要进实例（`aws ssm start-session`），它不随 aws CLI 附带。
   - **`git`**；私有仓部署还需 **`gh`** 并已 `gh auth login`（用于克隆仓库 + 拉取 `codegraph-server`）。
   - **一对 EC2 key pair 及本地的 `.pem`**——仅 `--local` 需要（你要 SSH 登录它创建的那台主机）。
   - **`rsync`**——仅当代码走本地仓快照推送（不从 git clone）时需要。
   - **`zip`**——可选，仅监控的 DAU 预聚合 Lambda 打包用；缺了不影响问答与其余监控，只是「日活」
     widget 为空（`--local` 会自动装）。

   本机**不需要** Node.js / Python 工程工具链：网关在索引主机上构建，agent 跑在容器里。
   `codegraph-server` 二进制也无需手动准备——本地与 S3 都没有时，部署会从**上游自己的** Release 自动下载
   并校验其发布的 sha256（本仓不分发该二进制；也可自行编译，见 `index-service/README.md`）
   （私有仓经 `gh`，公开仓经直链）。
3. **Bedrock 模型访问**：确保部署身份有 `bedrock:InvokeModel`（AWS 已不再需要逐模型在控制台「Model access」开通）。
   模型推理档由部署按 `--region` 自动解析，无需手填——部署调 `bedrock list-inference-profiles` 查该区域实际提供的档、
   自动挑最优（地域档 `us.`/`eu.`/`jp.`/`au.` 优先，没有就用 `global.`；如默认模型在东京解析为 `jp.…`、在新加坡保留 `global.…`）。
   仅当查不到匹配档时 preflight 会 WARN 并列出该区域可用的档。
4. **目标代码仓**：要被问答的游戏代码仓，两种来源（同项目可混用）：
   - **git 仓**（推荐，配置里写 `source: "git"`，默认值）：`https://github.com/org/repo.git`、`https://gitlab.com/org/repo.git`、`git@host:org/repo.git`，可选分支 / 标签 / 提交。index-service clone 到本地、定时 `git pull`，主分支改动分钟级内反映到问答。私有仓需一份只读访问凭证（写入 Secrets Manager，由索引主机取用）。
   - **本地仓**（配置里写 `source: "local"`，用于代码只在本地、推不到任何 git 远端的情况）：部署后用 `scripts/push-local-repo.sh` 经 rsync 直推到索引主机（见[第九节末「本地仓上传」](#本地仓上传)）。推送的是某一时刻的快照，不会自动跟随代码变化——代码变更后需重新运行一次上传命令。
5. **飞书应用**（见第三节，可与部署并行准备）。同时定下**租户**：中国版飞书（`open.feishu.cn`，
   部署参数 `--feishu-domain feishu`，默认）还是国际版 Lark（`open.larksuite.com`，
   `--feishu-domain lark`）。这个选择在**首次部署时**就要给对，且必须与创建应用所用的那个控制台一致
   ——不一致时机器人能通过鉴权，却永远收不到事件（详见第三节）。

---

## 二、一键安装（交互式，推荐）

先准备好飞书应用（第三节），拿到 `App ID` / `App Secret` / 机器人 `open_id`。

安装命令见[快速开始](#快速开始)；还没克隆仓库时也可以一行命令引导（自动克隆到 `./source-truth/` 再进入交互安装）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aws-samples/sample-code-qa-on-agentcore/main/scripts/get.sh)   # 公开仓
bash <(gh api repos/aws-samples/sample-code-qa-on-agentcore/contents/scripts/get.sh --jq '.content' | base64 -d)   # 私有仓，先 gh auth login
```

`install.sh` 是一个交互菜单（键盘上下键选择、回车确认），四个流程见 [第七节 多项目](#七多项目一台机器多个机器人)。
首次部署的典型顺序：

1. **查依赖**：`aws` / `python3` / `docker`（含守护进程在运行）/ `git`，可选 `gh`（私有仓部署需要），并校验 AWS 凭证可用；
2. **选「添加项目」**（底座不存在会自动先建）：填 projectId → 逐个加仓库（**git 地址** + 子目录 + 分支）→
   索引服务端口（即该项目的 `index-bridge-<项目>` 进程监听端口，脚本自动建议）→ 飞书 App 凭证（自动写入
   `source-truth/feishu-<项目>`）→ 首次再给一个只读 git
   凭证（写入全局 `source-truth/git-credentials`，后续项目复用）；
3. 写入 `.local/projects.json` 并部署该项目（底座 + 该项目的 bridge + runtime + gateway）。

> 若想先把 AWS 环境建好、之后再配 git，选「**初始化环境（不挂项目）**」：只起共享底座，机型/磁盘见下表。

索引主机是整套系统唯一一台 EC2（同机跑 codegraph 索引 + 各项目 bridge + 各项目 bot-gateway，全 ARM）。
codegraph 索引占用内存较高，且随仓库增大而增长，按仓库规模选机型；磁盘存放各仓 git 副本与 `graph.db`，按总体积选容量：

| 机型 | vCPU / 内存 | 适用 |
|---|---|---|
| `t4g.large`（默认） | 2C / 8G | 小中型仓库，突发型实例更省成本 |
| `t4g.xlarge` | 4C / 16G | 中大仓 |
| `m7g.large` | 2C / 8G | 内存型，持续负载更稳 |
| `m7g.xlarge` | 4C / 16G | 大仓·稳定 |
| `m7g.2xlarge` | 8C / 32G | 超大仓 / 多仓 |

磁盘默认 30 GiB，可选 50 / 100 / 200 GiB 或自定义容量。

**术语表构建上限**（初始化环境时会询问一次「术语表构建文件上限」）：术语表将中文业务词对应到代码中
真实出现的英文符号，使策划用中文也能命中英文代码——它在 index 主机后台离线构建（首次启动时自动安装
本地 `claude` CLI（日志事件名里写作 `cc`） 作为构建引擎），不在问答路径上。该上限控制每次构建扫描的文件数：

| 选项 | 适用场景 | 成本量级（一次性） |
|---|---|---|
| `0`（不限，**默认**） | 全量、最高覆盖 | 随仓库大小线性增长，**大仓可达数百美元**（实测 1.4 万文件约 $372） |
| `4000` / `1000` | 大仓深度覆盖 / 更广覆盖 | 随文件数线性增长 |
| `400` | 控成本（可能漏掉中文密集文件） | 约 $10 量级 |

首次全量为一次性开销，之后仅扫描代码变更的增量，成本很低。**接大仓且需控成本时先选一个正数上限**；
纯英文 / 无中文项目无需在意——术语表会自动为空、零开销、不影响问答功能。事后调整该上限见第六节
「改术语表构建上限」（**不需要**重新初始化主机），常规运维中无需调整。

> 术语表为**后台异步**构建：部署完成后问答功能立即可用；大仓首次全量构建可能耗时数十分钟，其间问答
> 功能不受影响，仅中文冷僻词可能尚未对应。构建进度与结果记录在主机日志中（`journalctl` 查
> `glossary_gen_done` / `glossary_gen_cc_failed`）。构建失败（例如 cc 未成功安装）仅导致术语表暂时为
> 空，不影响问答功能。

成功后应看到：

- 底座各阶段完成，每个项目打印 `index-bridge-<项目>` 健康 + `bot-gateway@<项目> is active`，整体 `deploy-all complete`；
- 状态写进 `.local/deploy-config`（含每项目 `RUNTIME_ARN_<项目>`、`INDEX_SERVICE_IP` 等）；
- 直接按第五节验证即可（各项目网关已在 index 主机上以 `bot-gateway@<项目>.service` 长驻）。

> 无人值守 / CI：`./scripts/install.sh --yes` 接受所有预填值（首次仍需已存在的飞书密钥）。
> 租户与语言也可直接用参数给定，跳过交互提问：
> `./scripts/install.sh --feishu-domain lark --locale en`（不给时交互会问租户；`--locale` 不给时
> `lark` 默认 `en`、`feishu` 默认 `zh`）。

### 手动部署：在单台 EC2 上就地安装（`--local`）

`--local` 模式只用一台 EC2，在这台机器上既完成部署又常驻运行（省去单独的部署机）。这台 EC2 长期保留：部署状态保存在它的 `.local/` 目录中，升级时登录同一台机器重新运行即可。

**一条命令起步**——其余交给 [`scripts/launch-host.sh`](../scripts/launch-host.sh)：

```bash
./scripts/launch-host.sh          # 也可 --profile <名> --region <r> 跳过前两个提问；--dry-run 先预览计划
```

它按顺序执行（全自动、每步幂等）：选择 profile → 创建 / 复用 IAM 角色 → 若为私有仓，取本机 `gh` 的 token 存入 Secrets Manager（见下「GitHub 凭证」）→ **自动创建 source-truth 专用网络**（VPC + 公私子网 + IGW + NAT，账号中已有则复用，无需手动选择 VPC / 子网）→ 创建安全组（仅放行当前出口 IP 的 22 端口）→ 选择密钥 / 机型 / 磁盘 → 在公有子网创建一台 ARM64 EC2 并挂载实例角色。

创建完成后，脚本会**提示输入 SSH 私钥路径**（默认推断为 `~/.ssh/<所选 key pair>.pem`），据此将部署脚本 [`scripts/lib/prepare-local-host.sh`](../scripts/lib/prepare-local-host.sh) 传至 EC2，并**输出一条 `ssh` 登录命令**。按该命令登录实例并运行脚本：安装 install.sh 所需依赖（`aws` / `docker` / `git` / boto3）、用第一步存入的凭证登录 GitHub、克隆仓库，最后进入 `install.sh --local` 交互（填写代码仓 / 模型 / 飞书凭证）。**脚本刻意不自动执行**——执行过程逐步可见，若某一步中断（如 preflight 报告依赖缺失），可当场排查；连接断开后重连再次运行即可从中断处继续。

> 私钥留空、或无法连接（私钥不匹配、实例尚未启动完成）时，launch-host 改为输出三条命令（`scp` 上传 + `ssh` 登录 + 登录后运行）供手动完成——同样不含 token。

首次部署约 10–20 分钟（bootstrap 与镜像构建均在本机串行执行，比一键部署略慢）。

**中断后重新运行**：每一步均幂等，从中断处重新运行即可，无需从头执行。脚本已在实例上时，SSH 登录后重新运行 `bash /tmp/prepare-local-host.sh`（或 `cd source-truth && ./scripts/install.sh --local`）即可从中断处继续。若实例已创建、之后才中断，重新运行 `launch-host.sh` 会**自动复用该实例**（已停止的先启动），照常提示 SSH 私钥、重新传脚本并输出登录命令，不会重复创建；确需全新实例时加 `--new-host`。

**四点需要注意**

- **GitHub 凭证（私有仓必看）**：该 EC2 需自行克隆仓库、下载 codegraph 二进制（私有 Release）、后续 `git pull` 升级，因此需访问 GitHub。`launch-host.sh` 取本机 `gh` 的登录 token（若无则提示粘贴一个只读 PAT，scope 仅需 repo:read）存入 Secrets Manager；在实例上执行的 `prepare-local-host.sh` 通过实例角色取回，并在实例上 `gh auth login` 持久化（存于该机 `~/.config/gh`，权限 600）。后续升级与 Release 下载均自动携带凭证，无需再次传入。**公开仓可跳过**（提示 token 时留空即可）。更换实例或停用时，请及时吊销该 token。
- **机器规格**：必须为 ARM64（aarch64）、Ubuntu 24.04（镜像与 codegraph-server 均为 ARM，x86 会被拦下）；部署用户需具备免密 sudo。launch-host 已设置 IMDSv2 与 hop-limit 1。
- **权限较大、建议专机专用**：`--local` 调用 AWS 用的是这台机器的**实例角色**（不是你本地的 profile——登录 EC2 后即不再可用），它既需建资源的权限，也需运行期权限，**范围偏大，这台机器不建议与其它业务共用**。角色名 `source-truth-index-role` 与默认部署共用（IAM 角色为账号级、不分区域）：`create-iam.sh` 幂等复用、只补权限不重建；但需注意，**若同账号已有默认部署在使用该角色，补上部署期权限后那台机器也会一并获得**——如需让默认部署保持最小权限，请换一个账号运行 `--local`。
- **NAT 不可省略**：实例位于公有子网（有公网 IP 供 SSH），但 AgentCore Runtime 位于私有子网、经 **NAT** 访问 Bedrock——Runtime 的网卡由 AWS 托管、无公网 IP，无法经 IGW 访问外网，因此必须配置 NAT（固定费用约每月 $32 起）。部署还会创建 ECR 与 S3 的 VPC 端点，把拉镜像这段从 NAT 路径上移走——但调用 Bedrock 这段移不走，所以端点只是减少了对 NAT 的依赖，并不能省掉 NAT。bridge 端口（8080-8099）仅对同一安全组内成员开放，外部无法访问。

**升级**：登录**同一台实例**（部署状态 `.local/` 均保存于其上），运行 `cd source-truth && git pull && ./scripts/deploy-all.sh --region <r> --local`。部署就地更新这台机器：重跑 bootstrap 落地新的基础代码、重建镜像、更新 runtime、重启网关与索引服务，实例 ID / 私有 IP / 已建好的 graph.db 均保留，不新建实例。重跑 bootstrap 与重启服务期间会有一段服务中断（时长与首次部署相当），建议在低峰期操作。

## 三、接入飞书

**第 0 步 · 先定租户**（决定后面所有步骤打开哪个控制台）：

| 租户 | 开放平台地址 | 部署参数 | 卡片语言默认值 |
|---|---|---|---|
| 飞书 · 中国版（默认） | <https://open.feishu.cn> | `--feishu-domain feishu` | `--locale zh` |
| Lark · 国际版 | <https://open.larksuite.com> | `--feishu-domain lark` | `--locale en` |

这个选择在**首次部署时**就要给对（`install.sh` 会问，也可用命令行参数直接指定），并且**必须与你创建
应用所用的那个控制台一致**：中国版与国际版的应用互不相通，租户填错时长连接与 REST 会指向不同的租户，
结果是机器人**能通过鉴权、却永远收不到任何事件**——群里 @ 它完全没反应，日志里也看不到收消息事件。
`--locale` 决定卡片与提示文案的语言（`zh` / `en`）；不指定时：`--feishu-domain lark` 默认 `en`，
`feishu` 默认 `zh`。

下文用 `<开放平台>` 代表你那一侧的地址（中国版 `open.feishu.cn` / 国际版 `open.larksuite.com`）。

在 `<开放平台>`（[飞书](https://open.feishu.cn) / [Lark](https://open.larksuite.com)）按顺序配置应用
（后续步骤依赖前序：须先启用机器人才能开通发消息权限，权限 / 事件 / 机器人均配置完成后再发布生效）：

1. **创建企业自建应用**：「开发者后台」→「创建应用」→「企业自建应用」。建好后在「凭证与基础信息」页
   记下 `App ID`（`cli_...`）和 `App Secret`。
2. **启用机器人**：在「机器人」页打开机器人能力，记下它的 `open_id`（`ou_...`）——即 `FEISHU_BOT_OPEN_ID`
   （用于判断群里 @ 的是否为该机器人）。**须先启用机器人，后续的发消息权限才能生效。**
3. **权限（scope）**：在「权限管理」开通以下权限（缺少任一项，对应功能将静默失效）：
   - `im:message`、`im:message.group_at_msg`：读群里 @ 机器人的消息；
   - `im:message:send_as_bot`：以机器人身份发消息 / 回复 / 加「处理中」表情（调 `im/v1/messages` 及其
     `reactions` 子接口——表情回应由消息收发权限覆盖，无需单独的资源 scope）；
   - **CardKit 卡片**：在「权限管理」搜索「卡片」，按 `cardkit/v1/cards` 接口的依赖项勾选；缺少该权限将无法创建卡片。
4. **事件订阅**：选**长连接**模式（不是 webhook——本系统是长驻订阅，不暴露公网回调），订阅两个事件：
   - `im.message.receive_v1`：收到群消息；
   - `card.action.trigger`：卡片按钮点击（停止 / 追问 / 澄清）。
5. **创建版本并发布**：第 2–4 步的改动均需发布后才对线上生效（企业内部可走自助审批）。仅保存草稿而不发布，
   机器人不会响应。

发布之后，还有两件事（与飞书后台无关，顺序不限）：

- **把机器人拉进目标群**，记下群 `chat_id`（`oc_...`）。
- **凭证交给安装器**：`App Secret` 是敏感信息，**绝不入库**。第二节的 `install.sh`「添加项目」会问
  `App ID` / `App Secret` / 机器人 `open_id`，替你写进 **Secrets Manager**（密钥名按项目区分
  `source-truth/feishu-<projectId>`）；网关启动时由 `run.sh` 取出注入进程环境，不落盘。按提示粘贴即可，无需手建密钥。

  > 手动管理（不走 install.sh）：自建一个 Secrets Manager 密钥，内容为 JSON
  > `{"app_id":"...","app_secret":"...","bot_open_id":"..."}`，名字以 `source-truth/` 开头（IAM 已按此前缀授权），
  > 再填进 `.local/projects.json` 对应项目的 `feishuSecretId`（或部署时设 `FEISHU_SECRET_ID=<密钥名>`）。

---

## 四、网关运行位置

经 `install.sh`（或 `deploy-all.sh` 的 gateway 阶段）部署后，每个项目的网关都作为 **`bot-gateway@<项目>.service`**
（systemd 模板单元，如 `bot-gateway@mangos.service`）在 index-service 那台 EC2 上长驻运行——无需单独启动进程。
常用运维（把 `<项目>` 换成实际 projectId）：

```bash
# 查看网关状态 / 日志（经 SSM 进实例）：
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
#   sudo systemctl status 'bot-gateway@*'              # 所有项目网关
#   sudo tail -f /var/log/bot-gateway-<项目>.log        # 期望日志：sdk_wsclient_started → sdk_wsclient_connected
#   （单元用 StandardOutput=append: 直接写文件，journalctl -u 只有启停记录，看不到应用日志；
#     CloudWatch agent 同时把这个文件投到 /source-truth/bot-gateway）
#   curl -s 127.0.0.1:$(grep HEALTH_PORT /etc/bot-gateway-<项目>.env | cut -d\' -f2)/ready
#     # 就绪探针：200 = 长连接已连上；503 = 启动中 / 重连中 / 正在优雅退出（详见第五节）
```

> **只能有一个网关实例连接同一个飞书应用**：飞书长连接是集群模式，每个事件只投给一个 client，
> 同一 app 运行两个网关（例如本地额外启动一个）会互相争夺事件、导致行为异常。本地调试时应先停止实例上的对应服务。

本地启动网关（开发调试用）见 [附录 B](#附录-b本地手动启动网关开发调试)。

---

## 五、验证（端到端冒烟）

先跑机器能自己判定的第 1 步，再进实例看两个健康端点（2、3），最后才在群里人工确认（4）。

1. **离线套件 + 真实端到端探针**（在部署机上，不用进实例）：

   ```bash
   ./scripts/test.sh --full        # 离线套件（lint + unit + typecheck）+ e2e 探针
   ```

   `--full` 会调用 `scripts/e2e-probe.py`。也可以单独跑它，退出码就是结论：

   ```bash
   python3 scripts/e2e-probe.py   # 0 = 全部探针通过；1 = 有探针失败；2 = 无法运行（缺依赖 / 未部署 / 无 projects.json）
   ```

   探针走的是**与网关完全相同的 invoke 路径**（boto3 `InvokeAgentRuntime` + 同一形状的 payload），
   校验：流式返回非空且能解出答案、`permission_denials` 为空（只读边界未被突破）、答案带 `文件:行号`
   出处。`2` 视为 skip 而非失败——离线或尚未部署的环境跑 `--full` 不会被它阻塞。

2. **后端健康**（进 index-service 实例查，`8080` 是第一个项目的端口，其它项目用它在 `projects.json` 里的 `port`）：

   ```bash
   aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
   # 登录后：
   curl -s -w '%{http_code}\n' http://127.0.0.1:8080/health   # 期望 200 + healthy:true
   ```

   > 这里**不要加 `-f`**：`-f` 在非 2xx 时不打印响应体、直接以 22 退出，而你要看的恰恰是那个状态码。
   > `/health` **只绑 `127.0.0.1`**（有意如此），从 VPC 外、甚至从同 VPC 的其它机器都访问不到，必须
   > 先进实例。

   > 本地仓项目要先完成 Quick Start 第三步（推代码），否则 `/health` 非 200、机器人答「未找到」——这是推代码前的正常状态，不是故障。

3. **网关健康**（同一台实例，端口是该项目 bridge 端口 + 10000，第一个项目即 `18080`；`activate_gateway.sh`
   按项目把这个值写进 `/etc/bot-gateway-<项目>.env` 的 `HEALTH_PORT`，不确定时先 `grep HEALTH_PORT` 该文件）：

   ```bash
   curl -s 127.0.0.1:18080/health   # 存活：进程活着就 200，看响应体里的 wsState
   curl -s -w '\n%{http_code}\n' 127.0.0.1:18080/ready   # 就绪：期望 200 + "wsState":"connected"
   ```

   `/ready` 只在飞书长连接已连上、且进程不在优雅退出时才 200，否则 503——这是判断「长连接到底通不通」
   最快的一步，比翻日志直接。`/health` 在重连期间照样 200（有意如此：SDK 重连只要两秒，不该据此重启）。
   两条路由同样只绑 `127.0.0.1`，从 VPC 外访问不到。

4. **在群里 @ 机器人**并提问（如「装备耐久怎么算？」）。预期：
   - 几秒内出现一张卡片，标题带实时计时（思考→分析→完成）；
   - 结论先行、用业务语言表述，底部「供研发复核」折叠区列 `文件:行号` 出处；
   - 可点「继续追问」或直接回复卡片，延续上文继续提问。
   - 首次冷启动（新 microVM）会慢一些（含 MCP 注册），是正常现象。

> 仓库里唯一的机检闸门是 CI：[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)（push 到 main /
> 每个 PR / 手动触发）装齐依赖后跑 `scripts/test.sh`，并在任何一个子套件被 skip 时判失败。
> **没有** pre-commit / pre-push 钩子（也没有 gitleaks 钩子）——本地是否跑套件靠自觉，闸门在 CI。

---

## 六、日常运维（day-2）

> 运维聚合命令 `ops.sh status` 尚未实现（规划中，p2）；当前请使用下列手动命令。

**代码更新了，刷新索引**：**无需手动操作**。每个仓库按 `refreshIntervalSec`（默认 300 秒）由 systemd timer
定时 `git pull`，常驻 codegraph 的 file-watcher 在几秒内增量重建该仓的内存图——不重启、无中断。改频率就改
`.local/projects.json` 里该仓/该项目的 `refreshIntervalSec`，再「重新部署该项目」。多项目部署见第七节。

**升级索引服务自身的代码**（bridge / 网关及其依赖，与业务代码无关）：在部署机上 `git pull` 后重新运行
`deploy-all.sh --region <r>`。索引主机**就地更新**——部署发现 S3 上的基础代码产物有变化，就经 SSM 在同一台
实例上重跑 `bootstrap.sh`，实例 ID、私有 IP、EBS 卷与已建好的 graph.db 全部保留，不新建实例、不切 DNS。重跑
期间 bridge 与网关会重启，有短暂中断；产物没变化时部署直接复用，不做多余动作。换机型不在部署职责内（部署
从不替换实例）：确需更换就自行 `stop` → `modify-instance-attribute --instance-type` → `start`，带
`--instance-type` 重新部署只会在机型不一致时给出警告。

**改术语表构建上限（`GLOSSARY_MAX_FILES`）**——这是本文关于该上限的唯一权威说法：该值最终写在实例的
`/etc/index-service.env` 里，而写它的只有 bootstrap。部署时带 `deploy-all.sh --glossary-max-files <n>`
（`0` = 不限，见[附录 A](#附录-a手动-deploy-allsh)）**只在这一轮的基础代码产物签名有变化、因而触发就地重跑
bootstrap 时**才会落到实例上；产物签名没变时部署走快速复用、不重跑 bootstrap，这个参数就是个 no-op。
所以：树没变时请进实例手改 `/etc/index-service.env` 的 `GLOSSARY_MAX_FILES`，下一轮刷新构建即按新值跑。
**不需要**重新初始化主机、也不需要新建实例。日常无需调整。

**只重部署 runtime**（修改 agent 镜像 / system prompt 后）：重新运行 `deploy-all.sh`（镜像与 runtime 阶段幂等）。
注意仍存活的 microVM 会使用旧镜像约 15 分钟，直到被回收。

**调整 microVM 存活时长（追问命中率 vs 成本）**：`deploy-all.sh --idle-timeout <秒>`（默认 900，即 15 分钟，
范围 60–28800）。该参数同时设置 AgentCore 的 `idleRuntimeSessionTimeout` 与网关的 session 复用 TTL，二者自动对齐。
AgentCore 空闲时 CPU 免费、内存照常计费。调大延长 microVM 存活、提高追问命中存活实例的概率，代价是多付这段空闲期的内存。
多数会话在一次问答后即结束，故默认 15 分钟；追问密集（如客服式高频问答）可调大，需控制成本则调小。
详见 [`agent/architecture.md`](agent/architecture.md)「Runtime 调参与成本权衡」。

**查看网关日志**（每项目一个 `bot-gateway@<项目>.service`，结构化 JSON 日志写 `/var/log/bot-gateway-<project>.log`）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：sudo tail -f /var/log/bot-gateway-<项目>.log      # 应用日志在文件里，不在 journald
#         sudo systemctl status bot-gateway@<项目>          # 只看单元状态用这个
```

关键事件（网关侧）：`invoke_start`（开始调用 runtime）、`card_sent`（卡片已发出）、
`card_closed`（一次问答结束）、`reply_context_replayed`（追问带上上文）、
`card_write_dropped` / `finalize_error`（卡片写失败）、`invoke_http_error`（后端非 200）。
关键事件（agent microVM 侧，同 traceId）：`agent_run_start`（开跑，记 promptChars / repos / model）、
`tool_call`（工具调用开始）、`tool_latency`（每次工具调用耗时）。

**按 traceId 查全链路（网关 + agent microVM 合并时间线）**：一次问答横跨两个 log group
（网关 `/source-truth/bot-gateway` + agent 的 `/aws/bedrock-agentcore/runtimes/<runtime>-DEFAULT`），
二者用同一 `traceId` 关联。一条命令即可完成两侧查询与合并——只需提供 traceId（区域、两个 log group、
时间范围、查询、排序均自动处理）：

```bash
./scripts/trace.sh st-00000000000000000000000000000000   # 示例值，把它换成卡片底部或 answer_* 日志行里的真实 traceId
#   --since-hours N（默认 6）扩大回溯窗；--raw 不合并、两侧原样输出
#   --runtime <id> 指定 AgentCore runtime id（默认从 .local/deploy-config 的 RUNTIME_ARN_* 推导；
#     多项目时会取第一条并提示，查另一个项目就用这个参数指明）
```

输出按时间合并、标 `GW`/`AGT` 来源，并自动抽取关键字段（status / detail / error / reason / tool /
latencyMs / ttfbMs / numToolCalls / toolErrors / turnCount / evidenceCitationCount / num_turns /
cache_read）。后端 403/超时这类「卡片失败但不知卡在哪一段」的问题，可定位是网关、invoke、还是 agent 侧。

**查看 index-service 日志**（同一台实例）：

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# 实例内：journalctl -u index-bridge-<项目> -f   （建立索引的日志：index-build@<仓> 单元）
```

**重启网关**（实例内）：`sudo systemctl restart bot-gateway@<项目>`。修改飞书凭证后，重新运行
`install.sh`（或 deploy 的 gateway 阶段）会重写 `/etc/bot-gateway-<项目>.env` 并重启服务。

**监控：指标 / 看板 / 告警**——`deploy-all.sh` 的 Phase 7 已自动部署整套（CloudWatch 指标 filter、三页看板、告警 + SNS、DAU 预聚合 Lambda），**正常无需手动干预**。例外是**首次部署**：网关还没写过日志、log group 尚不存在时，指标 filter 与告警会建不出来（deploy 只 WARN 不失败）——在群里提一个问题后重跑一次 deploy（或[附录 D](#附录-d手动刷新监控) 的命令）即补齐。此外只在单独刷新看板/阈值、或 deploy 时 `--skip monitoring` 后需要补充执行时才手动运行。告警的 SNS 订阅需手动确认一次（邮件点确认链接）。

关键告警：`ToolcallLeakDetected`（工具调用指令文本漏进卡片）、`FinalizeFailed`（卡片未正常结束、停在「分析中」）、
`AnswerFailedBurst`（回答失败率激增）、`LogPipelineStalled`（网关每 60 秒发一次 `gateway_heartbeat` 心跳日志，
心跳断了才告警——日志管道中断或网关异常；空闲夜里仍有心跳，不会误报）。

**拆除整套资源（停止计费）**：试用完、或某次部署中途失败留下计费资源（NAT ~$32/月、EIP、EC2、两个 ECR Interface 端点按小时计费）时，一条命令按反依赖顺序清理：

```bash
./scripts/teardown.sh --region <r> --dry-run     # 先看将删除哪些资源，不动资源
./scripts/teardown.sh --region <r>               # 交互确认后删除（输入 yes）
./scripts/teardown.sh --region <r> --include-shared   # 连同 IAM 角色 + S3 桶（账号共享）一起删
```

资源从 `.local/deploy-config` 读、读不到则按 `source-truth-*` tag 发现（所以中途失败的残留也能清理）。
删完会提示一条核对命令确认没有遗留的计费 NAT。破坏性、不可逆。

---

## 七、多项目（一台机器多个机器人）

一台索引主机可承载多个互相隔离的项目：机器人（独立飞书 App）⟷ 项目 一一对应，项目 ⟷ 仓库 一对多。
项目间逻辑隔离（各自进程 + 端口 + 服务端 scope，A 档），同团队互信项目共机即可；互不信任的项目仍应分机器。

**唯一声明处**是 `.local/projects.json`（不入库）。每个项目一条：`port`（该项目 bridge 端口，全机唯一）、
`feishuSecretId`（由「添加项目」自动生成，**勿手填**）、`repos`（每个仓 `{subdir, source?, git, ref?,
refreshIntervalSec?}`，`source` 默认 `git`、本地仓写 `local`）。顶层 `refreshIntervalSec` 是全局默认刷新间隔。

全部操作走 `./scripts/install.sh` 的箭头菜单：

- **初始化环境（不挂项目）**：只启动共享底座（VPC/NAT/EC2/镜像），不挂任何项目。适合先搭建 AWS 环境、
  之后再凭 git 地址与凭证挂载项目（即「先部署环境、后配置 git」）。
- **添加项目**：交互填 projectId → 逐个加仓库（每个仓选 git 或本地：git 仓填地址 + 分支，本地仓选 local 后用 push-local-repo.sh 推送）→ 索引服务端口（自动建议下一个未用值）
  → 飞书 App 凭证（自动写入 `source-truth/feishu-<项目>`）→ 首次还会收一个**只读 git 凭证**写入全局
  `source-truth/git-credentials`（后续项目复用）。随后写入清单并部署该项目（其余项目不受影响）。
- **重新部署现有项目**：修改某项目的仓库集合 / 端口 / 刷新间隔后，选择该项目重新部署（幂等）。
- **删除项目**（破坏性，需输入项目名二次确认）：停止并删除该项目的 bridge/gateway/runtime、各仓代码副本（含本地仓的 `.incoming` 暂存目录）与术语表，并从清单移除；
  飞书密钥默认保留（会单独问是否删），**全局 git 凭证绝不删**；其余项目不受影响。

**代码来源**：git 仓与本地仓两种（见[前置条件 4](#一前置条件一次性)、[本地仓上传](#本地仓上传)）；S3 不支持。git 私有仓需要那一份只读
凭证（GitHub/GitLab PAT 或 deploy key，所有仓共用一份）。索引主机在私有子网经 NAT 出网 clone/pull。

排查某项目：主机上单元名都带项目/仓库标识——`index-bridge-<项目>.service`、`bot-gateway@<项目>.service`、
`index-refresh-<仓库>.timer`、`index-build@<仓库>.service`；日志 `journalctl -u <单元>`。各项目 bridge 在
各自端口（`curl 127.0.0.1:<port>/health`）。

> 直接用 `deploy-all.sh`（不走 install.sh）：它会起底座 + 遍历 `.local/projects.json` 部署每个项目；
> `--skip-projects` 只起底座。但**飞书 / git 凭证仍需先存在于 Secrets Manager**——这些只有 install.sh 的
> 「添加项目」会交互创建，所以新项目首次务必走 install.sh。

---

## 八、排错（症状 → 原因 → 处置）

| 症状 | 可能原因 | 处置 |
|------|----------|------|
| 部署显示成功，但每次问答都答不出内容（空答案 / 「未找到」） | **Runtime 到 bridge 的这一段不通**——部署的健康检查只探索引主机的 loopback，探不到这一层 | 按这三处依次查：① runtime 使用的安全组是否放行到索引主机的 **8080-8099**；② 私有子网到 **NAT** 的路由是否存在（Runtime 网卡由 AWS 托管、无公网 IP，必须经 NAT）；③ 私有域名能否解析——进实例跑 `dig +short index.<r>.source-truth.internal`，返回空说明私有托管区 / VPC DNS 属性有问题（见[附录 C](#附录-c首次部署后的真机核对清单)） |
| 卡片一直「正在分析…」不结束 | 后端流被中断 / finalize 异常 | 查看网关日志 `finalize_error` / `card_closed failed:true`；偶发时重新提问，持续出现则检查 runtime / index 健康 |
| 卡片里出现异常的 `<invoke>` 代码标记 | 冷启动那次问答，底层的代码检索工具尚未就绪，agent 就提前作答 | 网关会自动重试一次，预热后不再出现。查日志 `num_turns`/`cache_read` 确认是否冷启动 |
| 机器人在群里**完全无响应** | 网关未启动 / 未 @ 到机器人 / 同一 app 运行了两个网关争抢事件 / **租户填错**（应用建在国际版 Lark，却按中国版飞书部署，或反之） | 进实例先 `curl -s -w '%{http_code}\n' 127.0.0.1:<HEALTH_PORT>/ready`（端口见 `/etc/bot-gateway-<项目>.env`）：503 就是长连接没连上；再 `systemctl status 'bot-gateway@*'` 确认 active + 日志 `sdk_wsclient_connected`；确认 @ 的是 `FEISHU_BOT_OPEN_ID`；停止多余网关，只保留一个。若鉴权成功（拿到了 token）却始终没有收消息事件，检查租户：`grep -E 'FEISHU_API_BASE\|LOCALE' /etc/bot-gateway-<项目>.env`，与创建应用的控制台核对，不一致就带正确的 `--feishu-domain` 重新部署（见[第三节](#三接入飞书)） |
| 网关 `condition failed` 未启动 | `/etc/bot-gateway-<项目>.env` 尚未写入（runtime 未就绪 / gateway 阶段被跳过） | 重新运行 `install.sh` 或 `deploy-all.sh`（不跳 gateway）；确认 `FEISHU_SECRET_ID` 已配 |
| 卡片回「查询失败」/ 日志 `AccessDenied` | 部署身份缺 `bedrock:InvokeModel`，或该模型在此区域无可用推理档 | 给部署身份补 `bedrock:InvokeModel`；模型档由部署按区域自动解析，查不到时 preflight 会列出该区域可用的档（见前置条件 3） |
| 部署在 index-service 阶段超时 | 全新账号 NAT 路由未收敛 / 实例仍在冷启动建立索引 | 再等待一轮（bootstrap 对网络操作有重试）；查看 `/var/log/` 与 `journalctl -u 'index-build@*'` |
| `/health` 长期非 200 | 索引损坏 / graph.db 空 / worker 反复重启 | 进实例查看 index-bridge-<项目> 日志；基础代码落后就重新运行 `deploy-all.sh`（就地重跑 bootstrap，实例与 graph.db 不动）；图确实损坏则在实例上 `sudo systemctl start index-build@<仓库子目录>` 全量重建该仓的图。注：本地仓在首次 `push-local-repo.sh` 之前本就是空图、`/health` 非 200，属正常，推代码后恢复 |
| 每次问答都返回 `HTTP 424 Runtime health check failed`，约 3 秒就失败，而 `/health`、bridge、网关长连接全绿 | **容器根本没起来**——拉镜像失败。看起来最像应用故障，其实一层都没跑到。历史上有两个原因：① NACL 回程端口上界不够（AgentCore microVM 源端口高于 60999）；② 经 NAT 走公网到 ECR 的路径间歇性超时 | 先看 runtime 自己的日志组，拉取失败会明确写出来：`aws logs filter-log-events --log-group-name /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT --start-time <ms>` 里找 `Failed to pull image` 与 `i/o timeout`。确认后：查 VPC 端点是否齐备且 available——`aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=source-truth-vpce-* --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,State,PrivateDnsEnabled]'`，三个都要有、Interface 型的 `PrivateDnsEnabled` 必须是 `true`（否则端点在计费但不截流量）；重跑 `deploy-all.sh` 的 network 阶段即可收敛。子网内可直接验证解析是否落到端点私有 IP：`getent hosts api.ecr.<region>.amazonaws.com` 应返回 `10.1.1.x` |
| 重新部署后行为仍是旧版本 | 仍存活的 microVM 继续使用旧镜像（约 15 分钟）/ 网关未重启 | 等待该 microVM 回收；重启网关以确保运行新代码 |
| 中文问答未用上项目专属命名 / 术语表疑似为空 | 术语表后台构建未完成或失败（cc 未成功安装 / Bedrock 不可达或无权限） | 进实例查看 `journalctl` 与 `/var/log/glossary-build-*`，查 `glossary_gen_done`（成功）/ `glossary_gen_cc_failed`（构建失败）；不影响问答，问答会自动退回常规检索 |

> 独占写入约束：index-service 的 graph.db 同一时刻只能有一个进程写入，并发写会导致 0 节点损坏。
> 服务层已用 flock + 进程内锁 + orphan reaper 守护；**不要**在实例上手动再跑一个 codegraph-server 写同一份图。

---

## 九、边界与安全（务必知道）

- **只读**：MVP 全程不写代码 / 不提交 / 不运行引擎；答案只基于最新主分支的真实代码，并用 CodeGraph 核对验证。
- **密钥**：飞书 `App Secret`、`App ID` 等绝不入仓库；走环境变量 / Secrets Manager / SSM。
  机检落在 **CI**（[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)）：它装齐依赖后跑
  `scripts/test.sh`（含 `scripts/check-invariants.sh` 的结构与发布内容检查），任何子套件被 skip 即判失败。
  仓库里**没有** pre-commit / pre-push 钩子，也没有 gitleaks 钩子——提交前是否本地跑一遍靠自觉，闸门在 CI。
- **越界能力后置**：多分支、设计文档读取、写回、第二引擎等均为 post-MVP，详见
  [`../README_zh.md`](../README_zh.md) 的「MVP 边界」与设计权威依据 [`design/`](design/)。

### 本地仓上传

无法推送到 git 远端的代码，声明为本地仓（`projects.json` 里 `{subdir, source:"local"}`，`install.sh` 添加项目时选「本地仓」即可）。代码不自动同步，**改一次推一次**——推送就是刷新。在**你自己的机器**上：

```bash
./scripts/push-local-repo.sh --host <ec2-ssh-host> [--identity <key>] <subdir> <本地仓路径>
```

**如何确认成功**：命令输出 `REINDEX_LAUNCHED`，表示代码已上传、重建已转入后台（不阻塞命令，ssh 断开亦不影响后台执行）。重建完成的标志是后台日志中的 `REINDEX_DONE`：

```bash
sudo journalctl -u reindex-<subdir> -f          # 或 sudo tail -f /var/log/reindex-<subdir>.log
```

- **常规推送不中断服务**：代码就地增量同步，watcher 在数秒内更新索引，网关全程保持在线（与 git 仓的 `git pull` 走同一流程）。**首次推送例外**：此前尚未建立索引（`--local` 部署时本地仓的索引构建被延迟），需先停止网关、完整建立一次索引后再启动，索引构建与术语表构建并行进行；其间该项目短暂离线，索引构建完成后首次对外提供服务。
- **推送中断可恢复**：中断仅会遗留暂存目录 `/data/repo/<subdir>.incoming`，不影响正在使用的代码。`sudo ls -d` 该目录仍在，即表示上次未完成，重新推送即可恢复；`sudo cat /data/repo/<subdir>/.snapshot-time` 为上次成功推送的时间戳。
- **术语表**（中文词 → 代码符号）随推送在后台增量刷新，日志见 `/var/log/glossary-build-<projectId>-<subdir>.log`（`glossary_gen_done` 表示成功，`glossary_gen_cc_failed` 表示 cc 失败但不影响问答）。主机未开通 Bedrock 时跳过术语表，仅更新索引。
- **安全约束**：`rsync --delete` 使主机副本与本地保持一致（本地删除的文件在主机上同样删除）；排除 `.git`；拒绝符号链接（`--safe-links --no-links`）；仅接受 `--identity <key>`，不支持任意 `--ssh-opts`（防止命令注入）。首次连接以 `accept-new` 信任主机公钥，建议预先通过其它渠道（如 AWS 控制台的 system log）核对指纹，以防主机被冒充、源码泄露。

**最小 sudoers**——只放行这一个脚本（建暂存目录、切换、重建都在脚本里完成，参数先经 `^[a-z0-9][a-z0-9-]*$` 校验、systemd 单元名固定写死）：

```
# /etc/sudoers.d/source-truth-push  (仅推送用户)
<pushuser> ALL=(root) NOPASSWD: /bin/bash /opt/idx/app/reindex_local_repo.sh *
```

此处 `/bin/bash <固定脚本路径> *` 将可执行范围限定为这一个脚本，`*` 仅放开其后的参数。**请勿**写成裸 `/bin/bash *`（等同于放行任意命令），也不要将 `systemctl`/`mkdir`/`chown` 等通用命令加入 NOPASSWD——其通配符可被 `-R`、`..` 之类绕过，进而提权至 root。

---

## 附录 A：手动 deploy-all.sh

`install.sh` 是 `deploy-all.sh` 的交互式前端。代码仓库**不再走命令行**——它们在 `.local/projects.json` 里声明
（每仓 git 或本地两种来源），由 deploy-all 起底座后遍历部署。直接调用：

```bash
# 起底座 + 部署 .local/projects.json 里的每个项目。幂等、可重复、新账号可跑。
./scripts/deploy-all.sh --region ap-northeast-1 [--instance-type t4g.large] [--root-volume-gb 30] [--model <默认id>] \
  [--feishu-domain <feishu|lark>] [--locale <zh|en>]

# 只起共享底座、不挂项目（init-env）：
./scripts/deploy-all.sh --region <r> --skip-projects

# 只打印计划、不动资源：
./scripts/deploy-all.sh --region <r> --dry-run

# 跳过某阶段（可重复）：artifacts|iam|network|index-svc|image|projects|monitoring
# （runtime 与 gateway 已合入 projects 阶段，用 --skip projects 整体跳过）
./scripts/deploy-all.sh --region <r> --skip monitoring

# 部署/重部署单个项目（底座须已就绪）：
./scripts/lib/deploy_project.sh <r> <projectId>
```

其余参数（都可与上面组合）：

| 参数 | 默认 | 作用 |
|------|------|------|
| `--feishu-domain <feishu\|lark>` | `feishu` | 飞书租户：`feishu` = 中国版（`open.feishu.cn`），`lark` = 国际版（`open.larksuite.com`）。**必须与创建应用所用的控制台一致**，它同时决定事件长连接与 REST base URL；只对上其中一个，机器人会通过鉴权后永远收不到事件。首次部署就要给对（见[第三节](#三接入飞书)） |
| `--locale <zh\|en>` | 跟随租户：`--feishu-domain lark` 时为 `en`，否则 `zh` | 卡片与提示文案语言。写进 `/etc/bot-gateway-<项目>.env` 的 `LOCALE` |
| `--max-files <n>` | 10000 | 每个仓库 codegraph 建索引的文件数上限 |
| `--glossary-max-files <n>` | `0`（不限） | 每个仓库术语表构建的文件数上限。**这是控成本的主要旋钮**：不限时大仓一次全量构建可达数百美元（14000 文件实测约 $372）。注意它只在本轮触发就地重跑 bootstrap 时才会落到实例上，否则需进实例手改 `/etc/index-service.env`，见第六节「改术语表构建上限」 |
| `--idle-timeout <秒>` | 900 | microVM 空闲回收时长（60–28800），同时对齐网关的 session 复用 TTL |
| `--max-lifetime <秒>` | 28800（8h） | microVM 强制回收前的硬上限（60–28800）；语义见 [`agent/architecture.md`](agent/architecture.md) |
| `--force` | 关 | 跳过 Phase 0 的硬阻断预检（如 vCPU 配额不足），视为操作者已确认。已在提额、或确知检查结果过时时才用 |

**前提**：`.local/projects.json` 里每个项目的 `feishuSecretId` 指向的飞书密钥、以及全局
`source-truth/git-credentials`（私有仓只读凭证）**必须已存在于 Secrets Manager**。这些只有
`install.sh` 的「添加项目」会交互创建，所以**新项目首次务必走 install.sh**；deploy-all 只消费它们。

## 附录 B：本地手动启动网关（开发调试）

正常部署中，网关运行在 index 主机上（见第四节）。本地调试时可直接运行 TS：

```bash
cd bot-gateway
npm install
export AWS_REGION=ap-northeast-1
# deploy 按项目写 RUNTIME_ARN_<项目>（项目名里的 - 换成 _）到 .local/deploy-config，取你要调试的那个：
export RUNTIME_ARN="$(grep '^RUNTIME_ARN_<项目>=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx            # 不要写进仓库
export FEISHU_BOT_OPEN_ID=ou_xxx
# 可选：LOG_HASH_SALT、MAX_CONCURRENT_INVOKES（默认 8）、LOCALE（zh|en；线上由
#   activate_gateway.sh 按 --locale / 租户写入）
# 可选：HEALTH_PORT——健康端点端口（只绑 127.0.0.1）。不设时按 bridge 端口 + 10000 推导
#   （8080 → 18080）；线上由 activate_gateway.sh 按项目写进 /etc/bot-gateway-<项目>.env，
#   systemd 单元的启动探针读同一个值。端点语义（/health 存活、/ready 就绪）见第五节
node_modules/.bin/ts-node --transpile-only src/index.ts
```

> 注意：同一飞书 app 只能有一个网关连接。本地启动前，先停止 index 主机上对应项目的服务
> （`sudo systemctl stop bot-gateway@<项目>`），否则两个网关会争抢同一批事件。

## 附录 C：首次部署后的真机核对清单

第五节的冒烟测试（`test.sh --full` / `e2e-probe.py` + `/health` + 在群里提一个问题）确认了主流程可用。这份清单更细，用于**首次在一个新账号或新区域部署之后**逐项确认——重点是几个静态检查与离线测试都覆盖不到、必须在真实机器上验证的环节，其中有的即使部署显示成功、实际也未必可用（`--local` 手动部署尤其需要注意）。日常重复部署无需每次执行。命令中 `<r>` = 区域、`<I>` = 索引主机实例 id（取自 `.local/deploy-config` 的 `INDEX_SERVICE_INSTANCE`）。

**必须验证（交付前）**

| 项目 | 确认方式 | 未通过时的表现与处理 |
|---|---|---|
| **能 SSH 登录新建的机器**（`--local`） | `ssh ubuntu@<公网IP>` 可连接 | 连不上/超时 → 安全组放行的 22 端口来源不是你真实的出口 IP（`launch-host` 用 `curl checkip` 获取，经 NAT 或代理时可能不准）。在控制台给该安全组补一条你当前 IP 的 22 |
| **Runtime 访问 Bedrock、并连上 bridge** | 在群里提一个问题，卡片给出带 `文件:行号` 出处的答案 | 卡在「查询失败」或超时 → 私有子网到 NAT 的路由不通，或 runtime 使用的安全组未放行 8080-8099。答案为空（部署却显示成功）→ 见第八节「部署显示成功，但每次问答都答不出内容」，按 SG 8080-8099 / NAT 路由 / 私有域名解析三处依次排查 |
| **部署身份权限充足**（`--local` 复用角色后） | `deploy-all --local` 执行到 runtime 的 `InvokeAgentRuntime` 不报 AccessDenied | 卡在 runtime 阶段报 AccessDenied 或 PassRole 被拒 → 角色缺 `bedrock-agentcore:*` 或对 `SourceTruthAgentRuntimeRole` 的 `iam:PassRole`（见前置条件 3 与 `--local` 权限说明） |
| **私有域名可解析**（**仅**手工自建 VPC，或部署时 `modify-vpc-attribute` 被权限拒绝过时才需查） | 进实例（`aws ssm start-session ... --target <I>`），实例内跑 `dig +short index.<r>.source-truth.internal`，应返回一个私有 IP | 两种拓扑下部署都会显式对该 VPC 执行 `modify-vpc-attribute --enable-dns-support` 与 `--enable-dns-hostnames`（默认拓扑在建网阶段、`--local` 在复用本机 VPC 时），所以这一项通常不再需要人工确认。只有 VPC 是你手工建的、或部署日志里这两条 `modify-vpc-attribute` 报过权限错误时，才需要核对这两个属性是否都为 true |

**接入第一个新代码仓时验证**

| 项目 | 确认方式 | 说明 |
|---|---|---|
| **本地仓首次推送**（停 bridge、完整建立索引） | 运行 `push-local-repo.sh`，输出 `REINDEX_LAUNCHED`；再看后台日志 `sudo journalctl -u reindex-<subdir>`（或 `/var/log/reindex-<subdir>.log`）出现 `REINDEX_DONE ... mode=initial-build`，`graph.db` 不小于 64KiB，bridge 已启动 | 索引构建与术语表构建在后台并行；中文仓的 GBK 编码问题也会在这一步首次显现 |
| **本地仓增量推送**（不停 bridge） | 修改几个文件再推送，后台日志显示 `mode=incremental`，几秒后问答即用上新代码 | 网关全程不中断；术语表在后台增量刷新（查看 `/var/log/glossary-build-*`） |
| **中断后能恢复** | 推送过程中断网或 Ctrl-C，`.incoming` 暂存目录仍在，重新推送一次即可恢复到完整状态 | 详见第九节「本地仓上传」的中断说明 |
| **codegraph 二进制可用** | bootstrap 日志中 `codegraph-server --version` 通过 | 架构或 glibc 版本不匹配会直接报错退出（东京已验证，风险低） |

**了解即可（不影响交付）**

- **冷启动首次提问**：新 microVM 第一次提问会略慢，极偶尔出现 `<invoke>` 之类的原始标记——网关会自动重试一次，预热后即正常（见第八节排错表）。
- **复用与清理**：`launch-host` 复用一台已停止的机器时会先将其启动；本地仓从项目中移除后，下次部署会清除它的代码副本与 `.incoming`（调整仓库集合并重新部署后，用 `sudo ls /data/repo/` 确认无残留即可）。

> **真机上最易出问题的两处，交付前务必亲自确认**：一是「部署显示成功、问答却答不出内容」——原因几乎总在 Runtime 到 bridge 这一段（安全组未放行 8080-8099 / 私有子网到 NAT 的路由不通 / 私有域名解析失败），部署自身探不到，最难自行发现；二是安全组 22 端口放行的出口 IP 不对——无法登录刚创建的机器。

---

## 附录 D：手动刷新监控

`deploy-all.sh` 的 Phase 7 已自动部署整套监控，此处命令仅用于单独刷新看板/阈值、或 deploy 时 `--skip monitoring` 后补充执行。部署期身份需 `logs:PutMetricFilter`、`cloudwatch:PutDashboard`、`cloudwatch:PutMetricAlarm`、`sns:CreateTopic`（非运行时角色）。幂等、可重复运行，换区域改 `--region` 即可。

```bash
# 全量：看板 → 指标 filter → 告警 + SNS → DAU 预聚合 Lambda，顺序内置
./scripts/apply-monitoring.sh --region <r>          # 加 --dry-run 先看计划

# 只刷新某一部分：--only dashboards|filters|alarms|dau
./scripts/apply-monitoring.sh --region <r> --only alarms
```

- 告警阈值在 `config/alarm-thresholds.json`，可调整，修改后重跑 `--only alarms`。
- SNS 订阅需手动确认一次：`aws sns subscribe --region <r> --topic-arn <脚本打印的 ARN> --protocol email --notification-endpoint you@example.com`（邮件点确认链接）。
- 不跑 dau 阶段则看板「日活」widget 持续为空，其余 widget 不受影响。

## 附录 E：可观测性（AgentCore span 与 trace）

Agent 通过 `opentelemetry-instrument` 启动（见 `agent-container/Dockerfile` 的 `CMD` 注释），
因此会产出 OpenTelemetry span。**那层包装本身就是接入**：`aws-opentelemetry-distro` 曾长期
只是被钉在依赖里而没有它，结果是零遥测，而所有检查都是绿的。

"产出 span"和"能查到 span"是两件事，而后者需要**两处** AWS 侧配置，不是一处：

1. **CloudWatch Transaction Search**——账号加区域级。把 trace segment 指向 CloudWatch Logs，
   并允许 X-Ray 写入 `aws/spans` 日志组。
2. **按 runtime 的投递配置**——每个 agent runtime 都要为 `TRACES` 和 `APPLICATION_LOGS` 配
   投递源与目标。这一条很容易漏：AWS 文档把它放在控制台操作一节，而漏掉它时账号级开关看起来
   像是坏的。这里配好之前，每个 runtime 的日志流都是空的、`aws/spans` 一条 span 也没有——
   连应用自己的输出都没到。

两处由同一个幂等 stage 完成：

```bash
./scripts/apply-monitoring.sh --region <region> --only observability
```

它同时是 `deploy-all.sh` Phase 7 的一部分。每一步做完都回读校验，而不是以退出码为准——
因为这里所有的失败形态从外面看完全一样：一切都配好了，就是没有数据。

**怎么验证而不骗自己。** 不要用 `describe-log-streams` 的 `storedBytes` 判断——它是周期性统计的，
事件早已到达时仍可能读到 0，这恰好会让正常工作的系统看起来是坏的。要查事件：

```bash
aws logs filter-log-events --region <region> --log-group-name aws/spans \
  --start-time $(( ($(date +%s) - 1800) * 1000 )) --limit 20
```

正常时 runtime 自己的日志组里会有 span 记录，其 `scope.name` 包含
`amazon.opentelemetry.distro.instrumentation.mcp`（到索引服务的证据通道被埋点）、
`claude_agent_sdk._internal.transport.subprocess_cli` 与 `bedrock_agentcore.app`。

**会话关联是通的，改动后值得复核这一条。** span 的 `attributes.session.id` 与网关在
`invoke_start` 记录的 `sessionId` 一致，所以一个会话可以从飞书卡片一路跟到 agent 的工具调用。
这也是 AgentCore Evaluations 依赖的性质——它按 session 选 span。

**span 落在哪。** 默认进共享的 `aws/spans`。也可以让每个 agent 投到自己的
`/aws/bedrock-agentcore/runtimes/<id>-<endpoint>`，这更契合这里的布局：一台主机、多个项目、
每个项目本来就有自己的日志组，访问控制和加密可按项目收口。需要 ADOT >= 0.18.0（已钉 0.19.0，
满足）、runtime 上设 `UNIFIED_TRACES_DESTINATION_ENABLED=true`、以及给执行角色授予
`logs:PutResourcePolicy`。本仓未配置：这些 runtime 建于该特性之前，仍走共享组。

**成本与一个需要留意的点。** Transaction Search 会为 span 建索引并按此计费；在意的话用
`aws xray update-indexing-rule` 把采样降到 100% 以下。另外 ADOT 的自动埋点会增加启动开销——
接上之后实测一次冷启动到首 token 是 142 秒，而 AgentCore 的 runtime 初始化上限是 120 秒。
首 token 不等于初始化，所以这次没有触发，但余量比以前小了。若日后出现冷启动的
`HTTP 424 Runtime health check failed`，第一个该查的就是这里。

---

## 附录 F：评估（AgentCore Evaluations）

评估是**可选**的，不在部署必经路径上：机器人回答问题不需要它，它花的也是另一类钱（一个常驻 Lambda，
加上 LLM-as-judge 评估器每次判定的模型 token）。而且它需要一份**已经跑过真实问答**的遥测才有意义——
首次部署时就创建它，除了空跑什么都得不到。

### 前提：埋点

Evaluations 只接受来自固定白名单 instrumentation scope 的 span，不在名单内的输入会被直接拒绝：

```
ValidationException: Provided input has no spans with supported scope.
```

本项目通过 `openinference-instrumentation-claude-agent-sdk` 满足这一条（见
`agent-container/requirements.txt`）。它靠自己声明的 `[opentelemetry_instrumentor]` entry point 被
`opentelemetry-instrument` 自动加载，**没有任何 agent 代码调用它**。确认埋点已生效：

```bash
aws logs filter-log-events --region <r> \
  --log-group-name /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --limit 500 \
  | grep -c openinference.instrumentation.claude_agent_sdk
```

数字为 0 就先别往下走：评估器全部会以 `no spans with supported scope` 失败，而那不是评估器的问题。

### 先用内置评估器

`aws bedrock-agentcore-control list-evaluators` 会列出全部内置评估器（含 DeepEval / AutoEval 的第三方
评估器）。质量、相关性、简洁性、指令遵循、工具选择与参数、轨迹匹配、安全性都用内置的，**不要自己写**。
和本项目最相关的是 `Builtin.Faithfulness`——「回答中的信息是否被提供的上下文支撑」。

### 两个自定义评估器，以及它们为什么存在

`evaluations/evaluators.json` 里只有两个，每一条都写明了为什么内置的办不到：

| 评估器 | 类型 | 内置为什么不够 |
|---|---|---|
| `SourceTruthCitationAccuracy` | 代码型（Lambda） | `Builtin.Faithfulness` 判的是答案与 agent **拿到的内容**是否一致。它判不了那些内容本身对不对：检索若返回了错误行号，答案忠实引用它，Faithfulness 会判 Completely Yes。这不是它的缺陷，是它的输入决定的——LLM 评委看不到仓库 |
| `SourceTruthEvidenceDiscipline` | LLM-as-judge | `Builtin.Refusal` 把「回避 / 拒答」当负面指标。对本机器人恰好相反：仓库确实没有被问到的东西时，明说「代码里没有」就是**正确**答案。这个语义反转无法通过配置内置评估器解决 |

### 部署

```bash
./scripts/apply-evaluations.sh --region <r>              # 全部阶段
./scripts/apply-evaluations.sh --region <r> --dry-run    # 只打印计划
./scripts/apply-evaluations.sh --region <r> --only evaluators
```

阶段依次是 `package` → `iam` → `lambda` → `evaluators`，每步幂等。几点值得知道：

- **打包必须在容器里做。** `pydantic` 带 `pydantic-core` 二进制轮子，用本机 pip 装出来的包在 Lambda 上
  可能直接 import 失败，而那种失败只在真正评估时才暴露、并且会以「评估器故障」的形式出现在评估数据里。
  脚本用 Lambda 官方基础镜像装依赖，装完立刻在镜像内 import 一次，import 不过就拒绝上传。
- **Lambda 挂在私有子网、加入 `source-truth-index-svc` 安全组。** 这不是额外开口子：bridge 的入站规则
  就是「同安全组成员的 8080-8099」，评估器和 runtime 受同一条边界约束。
- **判据模块只有一份副本**，在 `index-service/citation_verify.py`，打包时复制进 Lambda。不在两处各存一份，
  因为漂移的那天，评估器和线上服务对「什么算合法出处」的判断会悄悄分叉。

### 跑一次评估

```bash
# 取某个会话的 span（Evaluate 的输入就是 span，不是问答文本）
aws logs filter-log-events --region <r> \
  --log-group-name /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT \
  --start-time <ms> --limit 3000 --output json > /tmp/events.json

aws bedrock-agentcore evaluate --region <r> \
  --evaluator-id <id> --evaluation-input file://spans.json
```

评估器 id 在 `apply-evaluations.sh` 运行时打印，也写进了 `.local/deploy-config` 的 `EVALUATOR_IDS`。
批量评估用 `StartBatchEvaluation`，它直接从 CloudWatch 日志组发现会话，不需要自己搭取数管道。

### 读结果时要注意的一件事

代码型评估器把「评估器自己出错」和「答案有问题」严格分开：bridge 不可达或读取途中失败会返回
`errorCode`（`BRIDGE_UNREACHABLE` / `BRIDGE_READ_FAILED`）加一个非评分 label `EvaluatorError`，**不会**
返回 `Fail`。原因是一次基础设施中断若被记成 `Fail`，评估数据里就会留下一条永久且错误的「答案引用不
成立」。同理，`Unverified` 表示一条出处都没能真正核对上（例如出处都没带行号），它和 `Pass` 不是一回事。

`explanation` 里可能出现「以下出处的文件未出现在 read_file 调用中」——这**只是参考信息、不计失败**。
`search_files` 的结果不在 span 里，所以一条出处完全可能来自搜索结果而非 `read_file`；把它判失败会制造
大量假失败。

### 成本与拆除

两个自定义评估器本身不产生常驻费用，但 Lambda 存在即计入请求/时长，LLM-as-judge 每次判定消耗模型
token。`./scripts/teardown.sh` 会按顺序删除：online evaluation config（被启用的 config 会**锁定**评估器，
不先删它就删不掉评估器）→ 两个自定义评估器 → Lambda，并等待它的 VPC ENI 释放，否则后面删安全组会
`DependencyViolation` 失败。
