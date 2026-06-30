# 性能对比：source-truth vs 本地原生 cc，以及 Opus 4.8 vs Sonnet 4.6

> §1–3 测试仓 code-5x（含 10× 重复副本）；§4–7 为 2026-06-22 补充，测试仓 daggerfall-unity（单副本，
> 更贴近真实客户）。两批同走飞书 E2E。

> 实际环境实测数据（东京 ap-northeast-1，飞书 E2E：`+messages-send` 提问 →
> 等待 `card_closed` → `+messages-mget` 读取卡片）。耗时 = 网关 `invoke_timing.totalMs`（含建卡 +
> microVM 调度 + 模型 + 工具往返 + 流式结束处理），轮次/工具数取自同一条 perf 日志。
> 「本地原生 cc」= `claude -p`，**无 codegraph、同 system.md、同模型、同仓**（含 10× 重复副本），
> 取 `duration_ms` / `num_turns`。

## 1. source-truth vs 本地原生 cc（同模型 opus-4-8，公平对比）

同样 4 个「某数值如何计算 / 在哪里调整」的问题，配对实测：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 轮次 |
|------|--------:|------------------:|-----:|--------:|--------:|
| 怪物攻击力 | 221s | 89s | 2.5× | 18 | 12 |
| 负重上限 | 202s | 38s | 5.3× | 22 | 6 |
| 角色升级 | 224s | 40s | 5.6× | 25 | 7 |
| 武器攻击力 | 191s | 63s | 3.0× | 22 | 11 |
| **平均** | **210s** | **58s** | **3.6×** | **21.8** | **9.0** |

**结论**：source-truth 平均快 **3.6×**、轮次约一半。根因：CodeGraph 直接定位符号 + 去重的本地
检索，避开了原生 cc 在 10× 重复副本上耗时的全仓搜索与反复试探。输出更短更聚焦（cc 输出更冗长）。
> 注：测试仓含 10 份完全相同的副本，放大了 cc 全仓搜索的劣势；真实客户单副本仓上差距会小一些，
> 但 codegraph 直接定位带来的轮次优势是结构性的、与重复无关。

**复测（2026-06-19，另一组 3 问，同模型同 prompt，结论一致）**：

| 问题 | cc 用时 | source-truth 用时 | cc 轮次 | st 工具调用 |
|------|--------:|------------------:|--------:|------------:|
| 弓箭攻击冷却 | 190s | 34s | 17 | 6 |
| 负重上限与力量 | 77s | 35s | 11 | 5 |
| 金币掉落在哪里配置 | 144s | 40s | 17 | 5 |
| **平均** | **137s** | **36s** | **15.0** | **5.3** |

source-truth 快 **3.8×**、轮次约 **2.8×** 少（cc 三问 token 花费合计约 $2.99）。

**第三次抽样（2026-06-19，单问交叉验证，同模型同 prompt 同仓）**：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 工具调用 | cc 花费 |
|------|--------:|------------------:|-----:|--------:|------------:|--------:|
| 角色死亡损失什么 | 265s | 52s | 5.1× | 26 | 9 | $1.97 |

cc 在 10× 重复副本上全仓检索 26 轮、消耗 $1.97；source-truth 经 CodeGraph 直接定位到相关的死亡处理与入口逻辑文件，9 次工具调用 52s 完成。

**第四次抽样（2026-06-20，两问配对，同模型同 prompt 同仓）**：

| 问题 | cc 用时 | source-truth 用时 | 提速 | cc 轮次 | st 工具调用 | cc 花费 |
|------|--------:|------------------:|-----:|--------:|------------:|--------:|
| 护甲修理费用 | 99s | 46s | 2.1× | 13 | 6 | $0.95 |
| 毒药伤害/持续 | 157s | 49s | 3.2× | 13 | 3 | $1.17 |
| **平均** | **128s** | **47.5s** | **2.7×** | **13** | **4.5** | **$1.06** |

四次独立采样（3.6× / 3.8× / 5.1× / 2.7×）一致：source-truth 稳定快 **2.7–5.1×**、轮次约一半到三分之一。这一批两问都不算特别复杂，所以提速倍数偏低，仍 >2×。

## 2. Opus 4.8 vs Sonnet 4.6（均在 source-truth 内、同仓同 prompt）

**严格多轮测法（排除干扰）**：每个问题先发 1 次**预热**（丢弃，用于排除冷 microVM / 首次索引成本），
再连发 **3 次计时**，**全程串行**（同一个已预热的 microVM，排除冷启动 + 排队 + 并发污染），取**中位数**
（单次抽样噪声大——同一问题用时能从 40s 跳到 120s，取决于模型当轮执行了几个工具回合）。仅切换 Runtime
的 `ANTHROPIC_MODEL`，其余完全一致。

| 问题 | Sonnet 中位 | (范围) | Opus 中位 | (范围) | Sonnet 轮次 | Opus 轮次 |
|------|-----------:|-------:|----------:|-------:|-----------:|----------:|
| 怪物攻击力 | 96s | 85–120 | 118s | 107–122 | 12 | 11 |
| 负重上限 | 71s | 59–71 | 41s | 39–59 | 10 | 8 |
| 武器攻击力 | 89s | 57–121 | 87s | 72–101 | 15 | 13 |
| **中位均值** | **85s** | | **82s** | | 12 | 11 |

**结论**：在 source-truth 的取证式工作负载下，**Sonnet 与 Opus 耗时基本持平**（85s vs 82s，差异远
小于同一问题不同轮次间的方差 40–120s）。**耗时的主导因素是工具往返次数 + 该问题需要几轮取证，不是
模型本身的出 token 速度**——这也是为什么单次运行的数字会大幅波动、必须多轮取中位。质量上两者都能给出正确公式、都说明了配置在哪里可调，也都带「供研发复核」的精确出处；二者各有所长——Sonnet 往往更细、更结构化（如商人价格题
覆盖物价指数钳制范围 250–4000、阈值、完整公式并尝试画图），Opus 更口语、在多轮纠错 / 自我核实上略更
主动。**当前默认模型：Opus 4.8**（`ANTHROPIC_MODEL=global.anthropic.claude-opus-4-8`）；对成本敏感且能
接受同等延迟的场景可切换到 Sonnet 4.6（质量相当、更省）。

## 3. Haiku 4.5（已测试并排除）

也测试了 `claude-haiku-4-5`，但**判定能力不足，不纳入候选**，原因（均为实际读取卡片观察）：
- **冷启动 MCP 工具未注册时的「工具调用泄漏」最严重**，且 Haiku 用一种**独有的泄漏格式**
  `<attempt_{toolname}>{JSON}</attempt_{toolname}>`（Opus/Sonnet 是 `<invoke>` / `<function_calls>`）——
  网关剥离与 agent 自动重试已扩展覆盖这第二种格式（见 `mcp-init-race-leak` 记忆 / `strip-toolcall-leak.ts`）。
- 答案正文前常带**大段 JA/EN 混合的冗长旁白**（"let me call the tool / 実際に呼び出します…"），违背「结论先行」。
- 综合：Haiku 在「严格基于代码取证 + 结构化作答」这个负载上稳定性与质量都明显弱于 Sonnet/Opus，故排除。

> 方法说明：source-truth 的单次延迟受「这一轮模型决定调几次工具」主导，方差很大；**对比模型/版本
> 必须多轮取中位 + 预热丢弃 + 串行**，否则单次抽样会得出相反结论（早期单次运行曾得到 sonnet 94 / opus 86，
> 严格重测后变成 85 / 82——本质是噪声，两者持平）。

---

# 补充测试（2026-06-22，测试仓 daggerfall-unity，单副本真实仓）

> 与上面 code-5x（含 10× 重复副本）不同，这批用单副本仓，更贴近真实客户环境。

## 4. source-truth vs 原生 cc **+ 同一个 codegraph**（同模型 opus-4-8）

上面 §1 比的是「cc **无** codegraph」。这次给原生 cc 接上**同一个 codegraph MCP**（`claude -p --strict-mcp-config`
连 index 主机 `:8080/mcp`，并放开 `Read/Glob/Grep` + `codegraph_*` 工具，同 system.md），隔离出「我们这套封装
相比裸 cc + 同样 codegraph 多了多少」。

| 问题 | cc+codegraph | source-truth | cc 轮次 |
|------|-------------:|-------------:|--------:|
| 生命值上限 | 54s | 55s | 9 |
| 负重→移速 | 56s | 55s | 11 |
| 角色死亡 | 54s | 51s | 10 |
| **平均** | **54.6s** | **53.7s** | **10** |

**数据**：接上同一个 codegraph 后，两者耗时基本持平（54.6s vs 53.7s，差异在噪声内）。对照 §1（cc **无**
codegraph 时慢 2.7–5.1×）可见：该提速来自 codegraph，与是否经过 source-truth 封装层无关。

## 5. 耗时构成分析（113 次历史问答，四项目）

- **各项目耗时与代码量无关**：temporal（86 万行）56s、daggerfall（30 万行）53s、mangos（50 万行）51s、
  source-truth（1.3 万行）49s——中位数几乎一致 → **瓶颈不在检索 / 代码规模**。
- **单次问答分解**：工具检索（中位 7 次往返）合计 **0.26s**（最大 1.1s）；首字延迟暖机 0.6s；
  **模型推理占 ~98%**。codegraph 飞快，时间全花在「工具轮次 × 每轮模型推理」上。
- **冷启动占 22%**：暖机中位 52s，冷启动中位 64s（多花 ~12s，尾部最长 546s）。

## 6. 单次问答费用（2026-06-25 统计，近 30 天 843 次）

从 `agent_result` 日志取 token 用量，按 Bedrock Opus 4.8 单价折算：

| 指标 | 费用 |
|------|-----:|
| 均值 | $0.167/次 |
| 中位 | $0.146/次 |

费用构成：输出 token 占一半（均值 3,400 tok/次），prompt cache 读取占另一半
（均值 16 万 tok/次，按 cache-read $0.5/M 计）。非缓存输入极少——system prompt
和检索结果几乎全部命中缓存。CodeGraph 检索走本地磁盘，不产生模型费用。

当前规模：4 个游戏仓库（temporal 86 万行、daggerfall 30 万行、mangos 50 万行、
source-truth 1.3 万行），日均 28 次问答。

## 7. 并行检索引导（prompt 改动，实测无效，已回滚）

试过在 system.md 加「独立的多个 read 并到一轮并发」引导。**实测提速不明显**（49–54s，与改前无统计差异）：
后续 read 多是**依赖型探索链**（读了 search 结果才知道读哪个、读了 A 才知道要读 B），模型正确地判断它们不独立、
仍串行。那 ~1s 间隔的本质是**模型的探索推理**，不是「本可并行却没并行」。已回滚。

## 8. Opus 4.8 vs Sonnet 4.6 复测（daggerfall，同镜像同题，4 题各暖机后计时）

| 问题 | Opus | Sonnet | Opus 轮次 | Sonnet 轮次 |
|------|-----:|-------:|----------:|------------:|
| 生命值上限 | 52s | 88s | 8 | 17 |
| 每级生命点数 | 83s | 158s | 8 | 29 |
| 角色死亡 | 55s | 75s | 8 | 12 |
| 负重上限 | 33s | 47s | 8 | 7 |
| **平均** | **56s** | **92s** | 8 | 12–29 |

**数据**：这批题上 Opus 平均快 ~65%（56s vs 92s）。差异来自轮次——Sonnet 为完成同样的题绕了 2–3 倍的检索轮次
（最多 29 vs 8），每轮夹一次模型往返，累计耗时更长（Sonnet 单轮推理本身更快）。质量两者相当：都拒绝在「每级生命」
题硬编不在仓库的数值、都给出准确出处。与 §2（code-5x 上两者持平）的差异在于题型——daggerfall 这批更吃多轮探索，
放大了轮次差距；code-5x 那批题较浅，轮次相近故耗时相近。

## 复现方式

```bash
# source-truth：飞书发问 → 读 invoke_timing 的 totalMs/toolCalls
lark-cli im +messages-send --as user --chat-id <群> @机器人 "<问题>"
# 等待 card_closed，再 +messages-mget 读取卡片
grep invoke_timing /tmp/bot-gateway.log | tail -1   # totalMs / toolCalls / chars

# 本地原生 cc 基线（无 codegraph、同 system.md、同模型）
claude -p --model global.anthropic.claude-opus-4-8 \
  --append-system-prompt "$(cat agent-container/prompts/system.md)" \
  --allowed-tools Read Glob Grep --output-format json "<问题>"   # duration_ms / num_turns

# 切换模型（只更新 Runtime 的 ANTHROPIC_MODEL，不更新镜像/索引）：
./scripts/deploy-all.sh --region ap-northeast-1 --repo-subdir code-5x \
  --skip artifacts --skip iam --skip network --skip index-svc --skip image \
  --model global.anthropic.claude-opus-4-8
# 注意：仍存活的 microVM 持旧 env 直到老化，切换后早期 invoke 可能还是旧模型，重复发送几条或等待一段时间。
# 模型 id：opus=global.anthropic.claude-opus-4-8、sonnet=global.anthropic.claude-sonnet-4-6、
#         haiku=global.anthropic.claude-haiku-4-5-20251001-v1:0（已排除）。
```
