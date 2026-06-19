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

## 2. Opus 4.8 vs Sonnet 4.6（均在 source-truth 内、同仓同 prompt）

同 3 个问题，仅切换 Runtime 的 `ANTHROPIC_MODEL`：

| 问题 | Sonnet 用时 | Opus 用时 | Sonnet 工具 | Opus 工具 | Sonnet 字数 | Opus 字数 |
|------|-----------:|----------:|-----------:|----------:|-----------:|----------:|
| 怪物攻击力 | 97s | 108s | 11 | 11 | 2793 | 3062 |
| 负重上限 | 107s | 63s | 9 | 10 | 3017 | 2209 |
| 武器攻击力 | 78s | 88s | 16 | 15 | 2189 | 2260 |
| **平均** | **94s** | **86s** | **12.0** | **12.0** | **2666** | **2510** |

**结论**：在 source-truth 的取证式工作负载下，**两者耗时与轮次基本相当**（瓶颈是工具往返 + 取证
轮数，不是单纯的模型出 token 速度），Sonnet 略多写一点字。质量上两者都正确给出公式与配置可调性、
都带「供研发复核」精确出处；Opus 在多轮纠错/自我核实上略更主动（一次追问里主动纠正了上一轮被推断
的数值）。**默认模型已切到 Sonnet 4.6**（更省成本、质量足够）；对正确性要求极高的场景可切回 Opus。

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

# 切模型：改 .local/deploy-config 的 DEPLOY_MODEL，再
./scripts/deploy-all.sh --region ap-northeast-1 --repo <repo> \
  --skip artifacts --skip iam --skip network --skip efs --skip index-svc --skip image
```
