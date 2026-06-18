# source-truth

> 飞书机器人驱动的「代码为唯一依据」游戏研发代码问答助手。

策划 / QA / 客户运营在飞书里 @机器人提问，AgentCore microVM 内的 **Claude Code Agent** 通过远程
**CodeGraph 索引**定位代码、只读挂载 **EFS** 读取最新主分支源码与配置表，再以 **CardKit 流式卡片**
回答——答案永远以仓库里的真实代码为准（code as the single source of truth），不依赖可能过时的文档或记忆。

本项目是飞书设计文档《游戏研发智能助手 POC 方案》的工程实现。需求与架构真相源见
[`docs/design/`](docs/design/)；AI 协作约定见 [`AGENTS.md`](AGENTS.md)。

## 端到端链路

```
策划 ──@助手──▶ 飞书 ──长连接事件──▶ bot-gateway (TS 长驻网关)
                                         │  SigV4 InvokeAgentRuntime（按会话路由）
                                         ▼
                            AgentCore Runtime (Firecracker microVM)
                                         │  microVM 内运行 agent-container (Python)
                                         │  └─ Claude Code Agent SDK (CLAUDE_CODE_USE_BEDROCK=1)
                          ┌──────────────┼───────────────────────┐
                          ▼              ▼                        ▼
              CodeGraph MCP-over-HTTP   EFS /mnt/repo (只读)   Session Storage /mnt/workspace
              (index-service 常驻)       最新主分支代码+配置表   (per-session 临时文件)
                          ▲
                          │ git push webhook → git pull → inotify → CodeGraph 增量
                  内网 GitLab（反向拉取 / 打包至 AWS）
```

CardKit 流式卡片把 Agent 的输出实时渲染回飞书：单一 markdown 组件适配所有格式，完成后按内容动态追加
按钮 / 图表 / 「转研发」组件。

## 组件（monorepo）

| 目录 | 职责 | 语言 |
|------|------|------|
| [`agent-container/`](agent-container/) | 会话 microVM 内运行的 Claude Code Agent；推理 + 编排 + 取证 | Python |
| [`bot-gateway/`](bot-gateway/) | 飞书 Bot 长连接事件网关 + CardKit 流式渲染 | TypeScript |
| [`index-service/`](index-service/) | 常驻 CodeGraph 索引服务 + MCP-over-HTTP 桥 | TBD |
| [`infra/`](infra/) | IaC：AgentCore Runtime / EFS / 索引服务 / 网关 | boto3 + CDK（渐进） |
| [`shared/`](shared/) | 跨包共享：结构化日志、契约类型 | — |
| [`config/`](config/) | 配置驱动：i18n 文案、告警阈值 | JSON |
| [`scripts/`](scripts/) | 部署 / 运维 / 测试生命周期 | Bash |

完整目录树见 [`docs/structure_zh.md`](docs/structure_zh.md)。

## MVP 边界

第一版**仅查主分支、仅只读问答**——不跑引擎、不写回、不提交代码。单引擎 Claude Code（走 Bedrock 计费）、
CodeGraph 类索引、EFS 共享存储、每游戏项目一个机器人、机器人内按会话隔离。设计文档读取、多分支
worktree、共享记忆、完整审计护栏、Codex 第二引擎、数值模拟均为 post-MVP（见
[`docs/agent/architecture.md`](docs/agent/architecture.md) 与设计文档）。

## 快速上手

当前为初始化骨架阶段，已可用的命令：

```bash
./scripts/check-invariants.sh   # 结构自检：AGENTS / CLAUDE / structure / 双语配对 / 顶层目录
```

规划中的统一入口（尚未实现，见 [`scripts/README.md`](scripts/README.md) 的阶段标注）：

```bash
./scripts/test.sh          # (p1) 离线默认：unit + lint + typecheck
# 一键部署（全新账号/区域可跑，幂等）：artifacts→IAM→network→EFS→index-service→镜像→Runtime
./scripts/deploy-all.sh --region <region> --repo <local-repo-path>   # 加 --dry-run 仅打印计划
# deploy.sh 已废弃，仅作兼容垫片转发到 deploy-all.sh
```

> ⚠️ MVP 阶段基础设施先用 `agentcore` starter toolkit + boto3 起步跑通主流程与 POC，待 CodeGraph /
> EFS / inotify 三大待验证点验证后再渐进 CDK 化。
