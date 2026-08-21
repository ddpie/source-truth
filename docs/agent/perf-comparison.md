# 性能对比：source-truth vs 本地原生 cc，以及模型选择

> 实际环境实测数据（东京 ap-northeast-1，飞书 E2E：发问 → 等 `card_closed` → 读卡片）。耗时 = 网关
> `invoke_timing.totalMs`（含建卡 + microVM 调度 + 模型 + 工具往返 + 流式结束处理），轮次/工具数取自
> 同一条 perf 日志。「本地原生 cc」= `claude -p`，**无 codegraph、同 system.md、同模型、同仓**。
> 单次延迟受「这一轮模型决定调几次工具」主导、方差大（同题可从 40s 跳到 120s），所以对比一律
> **多轮取中位 + 预热丢弃 + 串行**。

## 1. source-truth vs 本地原生 cc（同模型 opus-4-8）

测试仓 code-5x（含 10× 重复副本）。四次独立采样（2026-06-17 至 06-20，合计 10 问配对实测）结论一致：

| 采样 | 问题数 | cc 平均 | source-truth 平均 | 提速 | cc 轮次 | st 轮次/工具 |
|------|-----:|--------:|------------------:|-----:|--------:|-----------:|
| 第 1 批 | 4 | 210s | 58s | **3.6×** | 21.8 | 9.0 |
| 第 2 批 | 3 | 137s | 36s | **3.8×** | 15.0 | 5.3 |
| 第 3 批 | 1 | 265s | 52s | **5.1×** | 26 | 9 |
| 第 4 批 | 2 | 128s | 47.5s | **2.7×** | 13 | 4.5 |

**结论**：source-truth 稳定快 **2.7–5.1×**、轮次约一半到三分之一。根因：CodeGraph 直接定位符号 +
去重的本地检索，避开了原生 cc 耗时的全仓搜索与反复试探。

> 注：测试仓含 10 份完全相同的副本，放大了 cc 全仓搜索的劣势；单副本仓上差距会小一些，
> 但 codegraph 直接定位带来的轮次优势是结构性的、与重复无关。

## 2. 提速来自 codegraph，不是封装层

给原生 cc 接上**同一个 codegraph MCP**（`claude -p --strict-mcp-config` 连 index 主机 `:8080/mcp`，
同 system.md；测试仓 daggerfall-unity 单副本，2026-06-22）：3 问配对，cc+codegraph 平均 54.6s vs
source-truth 53.7s——**基本持平**。对照 §1（cc 无 codegraph 时慢 2.7–5.1×）可知：提速全部来自
codegraph 定位，封装层不增加耗时。

## 3. 耗时构成（一组基准问答，四个公开 OSS 仓库）

- **耗时与代码量无关**：在跨越两个数量级代码量的四个仓库上，中位耗时都落在约 50 秒，彼此相差不到
  10% → 瓶颈不在检索，也不随代码规模增长。
- **单次分解**：工具检索（中位 7 次往返）合计 **0.26s**（最大 1.1s）；**模型推理占 ~98%**。
  时间花在「工具轮次 × 每轮模型推理」上。
- **冷启动占 22%**：暖机中位 52s，冷启动中位 64s（多花 ~12s，尾部最长 546s）。
- 曾试过在 system.md 引导「独立 read 并发」，实测无提速已回滚——后续 read 多是依赖型探索链，
  模型正确地判断它们不独立。

## 4. 单次问答费用（基准样本统计）

算法：从 `agent_result` 日志取本轮 token 用量，乘以你所用模型的单价。
构成上大致是输出 token 占一半、prompt cache 读取占另一半（cache-read 单价约为输入的十分之一量级），
非缓存输入极少；CodeGraph 检索走本地磁盘，不产生模型费用。所以单次成本主要由输出长度决定，
与仓库规模基本无关 —— 用自己部署里的实际 token 数算，比套用别人的金额准。
总费用与提问频次成正比；按自己的日均提问量乘以上面算出的单次成本即可估算。

## 5. 模型选择

- **默认 Opus 4.8**（`ANTHROPIC_MODEL=global.anthropic.claude-opus-4-8`）。两批对比：浅题
  （code-5x，轮次相近）两者持平（85s vs 82s）；多轮探索型题（daggerfall）Opus 平均快 ~65%
  （56s vs 92s）——Sonnet 绕了 2–3 倍检索轮次（最多 29 vs 8），每轮夹一次模型往返。质量两者相当。
  对成本敏感且题型较浅的场景可切 Sonnet 4.6。
- **Haiku 4.5 已测试并排除**：冷启动工具调用泄漏最严重（且有独有格式
  `<attempt_{toolname}>`，剥离已覆盖，见 `strip-toolcall-leak.ts`）；答案常带大段冗长旁白，
  违背「结论先行」；在取证式负载上稳定性与质量明显弱于 Sonnet/Opus。

## 复现方式

§1–§3 的耗时数字不需要任何专用工具就能复现：在**你自己的飞书 / Lark 群里** @ 机器人提问（手机或
桌面客户端都行），等卡片跑完，再从网关日志里读这一轮的 `invoke_timing`。方差大，所以按开头的方法
学：同题多轮、丢弃第一轮预热、串行不并发，取中位数。

```bash
# source-truth：在群里 @机器人 问一题 → 等卡片标题的计时停住（card_closed）
# → 到索引主机上读这一轮的 invoke_timing（totalMs = 本文所有耗时数字的定义）
#   日志在索引主机的 /var/log/bot-gateway-<projectId>.log（每项目一个文件），
#   同时由 CloudWatch agent 送到日志组 /source-truth/bot-gateway
sudo grep invoke_timing /var/log/bot-gateway-<projectId>.log | tail -1   # totalMs / toolCalls / chars
# 多轮取中位：
sudo grep -o '"totalMs":[0-9]*' /var/log/bot-gateway-<projectId>.log \
  | cut -d: -f2 | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'

# 本地原生 cc 基线（无 codegraph、同 system.md、同模型）
claude -p --model global.anthropic.claude-opus-4-8 \
  --append-system-prompt "$(cat agent-container/prompts/system.md)" \
  --allowed-tools Read Glob Grep --output-format json "<问题>"   # duration_ms / num_turns

# 切换模型（只更新 Runtime 的 ANTHROPIC_MODEL，不更新镜像/索引）：
./scripts/deploy-all.sh --region ap-northeast-1 \
  --skip artifacts --skip iam --skip network --skip index-svc --skip image \
  --model global.anthropic.claude-opus-4-8
# 注意：仍存活的 microVM 持旧 env 直到老化，切换后早期 invoke 可能还是旧模型，重复发送几条或等待一段时间。
```

> 索引主机在私有子网、不开 SSH，用 `aws ssm start-session --target <instance-id>` 登录。不想登机器
> 也行：`scripts/trace.sh <traceId>` 从 CloudWatch 侧把网关与 agent microVM 两个日志组按 traceId
> 合并成一条全链路时间线。
