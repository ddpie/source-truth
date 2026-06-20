# 性能对比：source-truth vs 本地原生 cc，以及 Opus 4.8 vs Sonnet 4.6

> 真机实测数据（东京 ap-northeast-1，测试仓 code-5x，飞书 E2E：`+messages-send` 提问 →
> 等 `card_closed` → `+messages-mget` 读卡）。耗时 = 网关 `invoke_timing.totalMs`（含建卡 +
> microVM 调度 + 模型 + 工具往返 + 流式收尾），轮次/工具数取自同一条 perf 日志。
> 「本地原生 cc」= `claude -p`，**无 codegraph、同 system.md、同模型、同仓**（含 10× 重复副本），
> 取 `duration_ms` / `num_turns`。

## 1. source-truth vs 本地原生 cc（同模型 opus-4-8，公平对比）

同样 4 个「某数值怎么算 / 在哪调」的问题，配对实测：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 轮次 |
|------|--------:|------------------:|-----:|--------:|--------:|
| 怪物攻击力 | 221s | 89s | 2.5× | 18 | 12 |
| 负重上限 | 202s | 38s | 5.3× | 22 | 6 |
| 角色升级 | 224s | 40s | 5.6× | 25 | 7 |
| 武器攻击力 | 191s | 63s | 3.0× | 22 | 11 |
| **平均** | **210s** | **58s** | **3.6×** | **21.8** | **9.0** |

**结论**：source-truth 平均快 **3.6×**、轮次约一半。根因：CodeGraph 直接定位符号 + 去重的本地
检索，避开了原生 cc 在 10× 重复副本上反复的慢全仓 grep 与盲目探索。输出更短更聚焦（cc 更啰嗦）。
> 注：测试仓含 10 份完全相同的副本，放大了 cc 的全仓 grep 劣势；真实客户单副本仓上差距会小些，
> 但 codegraph 直接定位带来的轮次优势是结构性的、与重复无关。

**复测（2026-06-19，另一组 3 问，同模型同 prompt，结论一致）**：

| 问题 | cc 用时 | source-truth 用时 | cc 轮次 | st 工具调用 |
|------|--------:|------------------:|--------:|------------:|
| 弓箭攻击冷却 | 190s | 34s | 17 | 6 |
| 负重上限与力量 | 77s | 35s | 11 | 5 |
| 金币掉落在哪配置 | 144s | 40s | 17 | 5 |
| **平均** | **137s** | **36s** | **15.0** | **5.3** |

source-truth 快 **3.8×**、轮次约 **2.8×** 少（cc 三问 token 花费合计约 $2.99；codegraph 侧本地查询近乎免费）。
两组独立采样（3.6× / 3.8×）结论稳定。

**第三次抽样（2026-06-19，单问交叉验证，同模型同 prompt 同仓）**：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 工具调用 | cc 花费 |
|------|--------:|------------------:|-----:|--------:|------------:|--------:|
| 角色死亡损失什么 | 265s | 52s | 5.1× | 26 | 9 | $1.97 |

cc 在 10× 重复副本上全仓探索 26 轮、花 $1.97；source-truth 经 CodeGraph 直接定位 `PlayerDeath.cs`
/ `EntryBehaviour.cs`，9 次工具调用 52s 收尾，本地查询近乎免费。三次独立采样（3.6× / 3.8× / 5.1×）
一致印证：source-truth 结构性地快 3–5×、轮次约一半到三分之一。

**第四次抽样（2026-06-20，两问配对，同模型同 prompt 同仓）**：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 工具调用 | cc 花费 |
|------|--------:|------------------:|-----:|--------:|------------:|--------:|
| 护甲修理费用 | 99s | 46s | 2.1× | 13 | 6 | $0.95 |
| 毒药伤害/持续 | 157s | 49s | 3.2× | 13 | 3 | $1.17 |
| **平均** | **128s** | **47.5s** | **2.7×** | **13** | **4.5** | **$1.06** |

四次独立采样（3.6× / 3.8× / 5.1× / 2.7×）一致：source-truth 稳定快 **2.7–5.1×**、轮次约一半到三分之一，
codegraph 侧本地查询近乎免费（cc 每问 ~$1）。这一批两问都不算特别绕，所以提速倍数偏低端，仍 >2×。

## 2. Opus 4.8 vs Sonnet 4.6（均在 source-truth 内、同仓同 prompt）

**严谨多轮测法（排除干扰）**：每个问题先发 1 次**预热**（丢弃，吃掉冷 microVM / 首次索引成本），
再连发 **3 次计时**，**全程串行**（同一 warm microVM，排除冷启动 + 排队 + 并发污染），取**中位数**
（单次抽样噪声大——同一问题用时能从 40s 跳到 120s，取决于模型当轮走了几个工具回合）。仅切换 Runtime
的 `ANTHROPIC_MODEL`，其余完全一致。

| 问题 | Sonnet 中位 | (范围) | Opus 中位 | (范围) | Sonnet 轮次 | Opus 轮次 |
|------|-----------:|-------:|----------:|-------:|-----------:|----------:|
| 怪物攻击力 | 96s | 85–120 | 118s | 107–122 | 12 | 11 |
| 负重上限 | 71s | 59–71 | 41s | 39–59 | 10 | 8 |
| 武器攻击力 | 89s | 57–121 | 87s | 72–101 | 15 | 13 |
| **中位均值** | **85s** | | **82s** | | 12 | 11 |

**结论**：在 source-truth 的取证式工作负载下，**Sonnet 与 Opus 耗时基本打平**（85s vs 82s，差异远
小于同一问题不同轮次间的方差 40–120s）。**耗时的主导因素是工具往返次数 + 该问题需要几轮取证，不是
模型本身的出 token 速度**——这也是为什么单次跑的数字会大幅波动、必须多轮取中位。质量上两者都正确给出
公式与配置可调性、都带「供研发复核」精确出处；二者各有所长——Sonnet 往往更细、更结构化（如商人价格题
给全了物价指数钳制范围 250–4000、阈值、完整公式并尝试画图），Opus 更口语、在多轮纠错 / 自我核实上略更
主动。**当前默认模型：Opus 4.8**（`ANTHROPIC_MODEL=global.anthropic.claude-opus-4-8`）；对成本敏感且能
接受同等延迟的场景可切 Sonnet 4.6（质量相当、更省）。

## 3. Haiku 4.5（已测试并排除）

也实测了 `claude-haiku-4-5`，但**判定能力不足、不纳入候选**，原因（均为真机读卡观察）：
- **冷启动 MCP 工具未注册时的「工具调用泄漏」最严重**，且 Haiku 用一种**独有的泄漏格式**
  `<attempt_{toolname}>{JSON}</attempt_{toolname}>`（Opus/Sonnet 是 `<invoke>` / `<function_calls>`）——
  网关剥离与 agent 自动重试已扩展覆盖这第二种格式（见 `mcp-init-race-leak` 记忆 / `strip-toolcall-leak.ts`）。
- 答案正文前常带**大段 JA/EN 混合的啰嗦旁白**（"let me call the tool / 実際に呼び出します…"），违背「结论先行」。
- 综合：Haiku 在「严格基于代码取证 + 结构化作答」这个负载上稳定性与质量都明显弱于 Sonnet/Opus，故排除。

> 方法论教训：source-truth 的单次延迟受「这一轮模型决定调几次工具」主导，方差很大；**对比模型/版本
> 必须多轮取中位 + 预热丢弃 + 串行**，否则单次抽样会得出相反结论（早期单跑曾得 sonnet 94 / opus 86，
> 严谨重测后变成 85 / 82——本质是噪声，两者打平）。

## 复现方式

```bash
# source-truth：飞书发问 → 读 invoke_timing 的 totalMs/toolCalls
lark-cli im +messages-send --as user --chat-id <群> @机器人 "<问题>"
# 等 card_closed，再 +messages-mget 读回卡片
grep invoke_timing /tmp/bot-gateway.log | tail -1   # totalMs / toolCalls / chars

# 本地原生 cc 基线（无 codegraph、同 system.md、同模型）
claude -p --model global.anthropic.claude-opus-4-8 \
  --append-system-prompt "$(cat agent-container/prompts/system.md)" \
  --allowed-tools Read Glob Grep --output-format json "<问题>"   # duration_ms / num_turns

# 切模型（只更新 Runtime 的 ANTHROPIC_MODEL，不动镜像/索引）：
./scripts/deploy-all.sh --region ap-northeast-1 --repo-subdir code-5x \
  --skip artifacts --skip iam --skip network --skip index-svc --skip image \
  --model global.anthropic.claude-opus-4-8
# 注意：warm microVM 持旧 env 直到老化，切换后早期 invoke 可能还是旧模型，多发几条或稍等。
# 模型 id：opus=global.anthropic.claude-opus-4-8、sonnet=global.anthropic.claude-sonnet-4-6、
#         haiku=global.anthropic.claude-haiku-4-5-20251001-v1:0（已排除）。
```
