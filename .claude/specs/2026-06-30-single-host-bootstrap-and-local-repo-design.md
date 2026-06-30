# 设计：单台 EC2 自举部署 + 本地仓接入

- 日期：2026-06-30
- 状态：已批准（待写实现计划）
- 触发场景：客户现场部署。两个诉求：① 业务代码在客户本地仓库，客户可接受手动跑命令上传；
  ② 希望先开一台 EC2，在这台 EC2 上跑一个脚本初始化整个环境。

## 1. 背景与现状

source-truth 当前的部署链路是**两台机器**：

- 一台**临时跳板机**（操作机）：跑 `scripts/install.sh` / `deploy-all.sh`，负责 build 镜像、调 AWS API 把
  其余资源创建出来。部署完即可销毁，不参与运行。
- 一台**常驻 index-service EC2**：由 `deploy-all.sh` 的 index-svc phase **新建**（ARM64，私有子网，
  user-data 跑 `index-service/bootstrap.sh`）。它同时跑 CodeGraph 索引、每项目一个 HTTP bridge
  (`index-bridge-<projectId>`)、定时 git pull 刷新、术语表构建，以及**飞书网关**
  (`bot-gateway@<projectId>.service`，与 index-service 同主机)。代码副本只在它本地磁盘 `/data/repo/<subdir>`。

此外还有一个**不在任何可登录 EC2 上**的托管组件：**AgentCore Runtime**（Firecracker microVM，AWS 托管，
每会话独立）。AI 引擎（Claude Code Agent SDK）在 microVM 内运行，这是产品「会话隔离」的核心。

代码接入当前是 **git-only**：`activate_project.sh` 用只读 git 凭证 clone 各仓，systemd timer 定时
`git pull`，codegraph file-watcher 增量重建——「最新主干、分钟级新鲜」由此而来。`projects.json` 每个 repo
条目形如 `{subdir, git, ref}`，`install.sh` 添加项目流程也只接受 git 地址。

## 2. 目标

1. **单台 EC2 自举**：客户手动开一台 ARM64 EC2，SSH 进去跑一个脚本，系统即起。省掉临时跳板机——
   初始化在这台常驻 EC2 上自举。AgentCore 仍为 AWS 托管（不占客户机器、免运维），这是现架构下「单台」
   的边界（见 §7 风险）。
2. **双代码接入**：同时兼容两种来源，且**同一项目可混用**（按 subdir 区分）：
   - **git 仓**：保持现状，`{subdir, git, ref}`，自动定时刷新。
   - **本地仓**：客户机用 `rsync`/`scp` over SSH 直推到 EC2，**手动刷新**（重跑上传命令才更新）。

## 3. 非目标

- 不把 AI 引擎从 AgentCore 搬到 EC2 自托管（那是推翻会话隔离的大改，超 MVP 边界）。
- 不为本地仓提供自动刷新（按客户诉求，本地仓「手动跑命令上传」即更新语义）。
- 不拆分 IAM 大/小权限（已选「方案 A，不拆 IAM」；残留风险记入 §7）。
- 不改动 AgentCore 之外的会话隔离、只读边界、术语表等既有不变量。

## 4. 方案选择记录

### 4.1 自举方式：方案 A（自托管自举）

- **A（已选）**：客户手动开 ARM64 EC2（带实例角色、能出网子网），在本机跑 `install.sh`。`deploy-all.sh`
  进入「本地模式」：网络 phase 复用本机所在 VPC/子网（不新建 VPC+NAT）；index-svc phase 直接在本机跑
  `bootstrap.sh`（不新建 EC2 + user-data）；image phase 本机 build/push（本机即 ARM64，原生镜像）；
  runtime phase 仍托管创建 AgentCore，`CODEGRAPH_MCP_URL` 指向本机 bridge。结果：全程只有这一台 EC2。
- B（弃）：跳板机用完自毁。改动最小但部署期仍是两台，与「省掉跳板机」矛盾。
- C（未选）：A + IAM 收口（初始化用临时大权限、运行只留窄角色）。客户选了不拆 IAM，故残留大权限实例角色。

### 4.2 本地仓上传：客户机 rsync/scp 直推（已选）

- **已选**：提供客户机本地跑的 `scripts/push-local-repo.sh <subdir> <本地路径>`——`rsync -az --delete`
  over SSH 推到 EC2 的 `/data/repo/<subdir>`，推完触发一次重建。直接、不经 S3。
- 弃：打包→S3→主机拉取（`resolve_repo.sh` 已部分支持 S3，但要接入刷新链，且多一跳）。

### 4.3 本地仓刷新语义：手动（已选）

重跑 `push-local-repo.sh` 才更新；本地仓**不挂** `index-refresh` timer。

## 5. 架构（落地后）

```
客户开 1 台 ARM64 EC2（实例角色 + 能出网子网）
  └─ SSH 进去跑 install.sh（本地模式）
       ├─ network：复用本机所在 VPC/子网，不新建 VPC+NAT
       ├─ index-svc：直接在本机跑 bootstrap.sh（不再新建 EC2）
       ├─ image：本机 build/push ARM64 镜像到 ECR
       ├─ runtime：AgentCore 托管创建（唯一不在这台机器上的部分）
       └─ gateway：本机 systemd 拉起 bot-gateway@<projectId>
  └─ 代码接入（每仓二选一，可混用，按 subdir 区分）
       ├─ git 仓：projects.json {subdir, git, ref}        → 自动定时刷新（现状不变）
       └─ 本地仓：projects.json {subdir, source:"local"}  → 客户机 push-local-repo.sh 直推 + 手动重建
```

运行态机器数：**1 台 EC2**（index + gateway + 自举）+ AgentCore 托管。

## 6. 改动清单（实现计划据此展开）

1. **`scripts/deploy-all.sh`**：新增「本地模式」（`--local` 显式开关，或自动探测运行在目标 EC2 上）。
   - network phase：复用本机所在 VPC/子网，跳过 VPC+NAT 新建；安全组仍按需创建/复用。
   - index-svc phase：检测「本机即索引主机」→ 直接幂等执行 `bootstrap.sh`，不新建 EC2、不走 user-data。
   - image phase：本机 build/push（已是 ARM64）。
   - runtime / gateway phase：基本不变；endpoint 指向本机 bridge（用本机私有 IP 或 DNS）。
2. **`index-service/bootstrap.sh`**：从「user-data 首启专用」剥离出**可在已运行主机上幂等重跑**的形态
   （安装依赖、codegraph-server、目录、env、git 凭证 askpass 等），供本地模式直接调用。
3. **`index-service/activate_project.sh` + 来源分流**：按 repo 条目的 `source` 字段分流——
   - `source` 缺省或 `"git"`：现状（git_fetch + 建 refresh timer）。
   - `source: "local"`：**跳过** git_fetch、**跳过** refresh timer，只建图（`index-build@<subdir>`）+ 纳入
     bridge 的 serve 范围。reconcile 与「删项目」逻辑要兼容无 git 仓（不能因为缺 git 字段报错）。
4. **`scripts/install.sh`**：添加项目流程支持「本地仓」类型——选本地仓时不问 git URL，确认 subdir 即可；
   写入 `{subdir, source:"local"}`。删项目/subdir 冲突检查/manifest 构建兼容无 git 仓。
5. **新增 `scripts/push-local-repo.sh`**（客户机侧）：参数 `<subdir> <本地路径> [--host <ec2>]`；
   `rsync -az --delete --exclude .git` over SSH 推到 `/data/repo/<subdir>`；推完触发一次重建
   （SSH/SSM 启动 `index-build@<subdir>.service`，复用单写者 flock）。幂等、可重复跑。
6. **`scripts/lib/render_manifest.py` + `.local/projects.json` schema**：repo 条目接纳可选 `source`
   字段（枚举 `git`|`local`，缺省 `git`）；`git`/`ref` 在 `source:"local"` 时可缺省，校验放宽但仍 fail-loud。
7. **文档**：
   - `docs/runbook.md`：新增「单台 EC2 自举部署」与「本地仓上传（push-local-repo.sh）」两节。
   - `docs/agent/invariants.md`：补「本地仓快照语义」——本地仓非持续最新主干，答案应标注快照时间。
   - 若动顶层目录则同步 `docs/structure_zh.md` / `_en.md`（预计不动顶层目录）。

## 7. 风险与已知取舍

1. **AgentCore 仍是 AWS 托管**——产品会话隔离的核心，不在这台 EC2 上。若客户把「单台 EC2」理解为
   「完全离线/内网无任何 AWS 托管服务」，则本方案不成立，须提前对齐预期。本方案的「单台」指：客户只需
   开/运维一台 EC2，AgentCore 由 AWS 托管、不占客户机器。
2. **本地仓失去「代码为唯一依据＝永远最新主干」的自动保证**——推一次才新一次，与产品核心价值有张力。
   缓解：对 local 仓的答案标注「快照时间」，并落到 invariants 文档与（可行时）答案输出。
3. **实例角色权限较大且长期留在常驻机**（能建 AgentCore/ECR/Secrets、删资源）——客户选了不拆 IAM，
   接受这一残留。将来收口路径＝方案 C（初始化用临时大权限、运行只留窄角色）。

## 8. 验收

- 在一台全新 ARM64 EC2（仅装好 aws/docker/git/python3 + 实例角色）上，SSH 跑一次脚本即完成全栈部署，
  过程中不另起第二台 EC2。
- 一个项目内可同时声明一个 git 仓与一个本地仓；git 仓自动刷新，本地仓经 `push-local-repo.sh` 推送后
  重建并可被问答取证到。
- `./scripts/test.sh`（离线套件）通过；新增逻辑（来源分流、manifest schema）有单测覆盖。
- `./scripts/check-invariants.sh` 通过；改动的文档双语配对（若涉及）成立。
