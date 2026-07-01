# 术语表构建：单仓内 batch 并发 + 退避重试

日期：2026-07-01
范围：`index-service/glossary_build.py`（仅此一个文件）

## 背景

术语表构建（构建期引擎，AGENTS.md「构建期引擎」边界内）当前的并行情况分两层：

- **跨仓库层——已并行。** `activate_project.sh` 对每个 subdir 各起一个 `systemd-run`
  瞬态单元，各持 per-slice 锁写自己的 `<subdir>.jsonl`，互不阻塞。
- **单仓库内——单进程串行。** `glossary_build.build()` 把候选文件按
  `CC_BATCH_FILES=300` 切成多批，`for batch in real_batches` 逐批调用 `run_cc`，
  一批跑完才跑下一批。一次全量扫描 = 几十批串行 cc 调用（注释记为 2-3 小时）。

单仓内串行是最实际的提速点：各 batch 文件集不相交、无共享状态，输出只是末尾
`"\n".join(raw_parts)` 拼接，落盘只有一次 atomic write。瓶颈是墙钟，不是正确性。

真正的约束是 **Bedrock 限流**：`run_cc` 遇非零退出即抛，触发 `glossary_gen` 的 SKIP。
串行时天然错峰；并发后撞节流（429）概率上升，必须配退避重试兜底，否则会从「慢」
变成「被 SKIP」。

## 决策

- 单仓内 batch 并发度：默认 **8**，env `GLOSSARY_BUILD_CONCURRENCY` 可调。
- 单 batch 失败（尤其 429 节流）：**有界指数退避重试**，用尽才算整体失败 →
  保持现有「全或无」写盘与 SKIP 语义。绝不写部分结果。

## 架构

只改 `glossary_build.py`。对外契约保持不变：

- `build()` 签名、返回 `list[Entry]`、失败抛 `SubprocessError`/`OSError` 不变。
- `glossary_gen.py` / `activate_project.sh` / `glossary_refresh.sh` 不动。
- SKIP、原子写（`_write_atomic`）、跨仓 systemd-run 并行照旧。
- 注入点不变：`build(runner=...)` 仍是唯一注入点，单测继续 monkeypatch
  `glossary_build.run_cc`，不 shell out。

### 改动 1：并发跑 batch

把串行 `for batch in real_batches` 换成 `concurrent.futures.ThreadPoolExecutor`
（subprocess 阻塞，线程池足够）。

- 并发度 = `min(_build_concurrency(), len(real_batches))`；batch 数少于并发度时不起
  多余线程。
- `_build_concurrency()` 读 env `GLOSSARY_BUILD_CONCURRENCY`，非法/缺省回落 **8**。
- 结果按 batch 序号回填 `raw_parts`，最终仍 `"\n".join()`——**输出顺序确定**，
  不受完成先后影响，与串行完全一致。
- 每批的 `glossary_build_batch` 心跳日志保留（仍到 stderr，产物不落盘）。

### 改动 2：每 batch 有界退避重试

新增薄封装 `_run_with_retry(run, ...)` 包住注入的 `run`：

- **可重试** = `subprocess.TimeoutExpired`，或 `CalledProcessError` 且 stderr 命中节流
  关键字（`throttl` / `429` / `too many requests` / `rate exceeded`，大小写不敏感）。
- **硬错**（参数错、AccessDenied、非节流 4xx）**不重试**，立即上抛。
- 退避：`base * 2^n` + 随机抖动错峰。默认 `base=4s`、`max_retries=3`，均 env 可调
  （`GLOSSARY_BUILD_RETRY_BASE_S` / `GLOSSARY_BUILD_MAX_RETRIES`）。呼应既有经验：
  退避要错峰、别背靠背。
- sleep 通过注入的 sleeper（默认 `time.sleep`），便于测试不真的等。
- 每次重试打结构化日志 `glossary_build_retry`（batch idx / attempt / 等待秒数）。

抖动实现注意：workflow/脚本环境禁用 `Math.random` 类不确定源不是本处约束（这是普通
Python 进程），用 `random.uniform` 即可；抖动只为错峰，无需可复现。

### 改动 3：失败即整体失败（保持全或无）

任一 batch 重试用尽仍失败 → 该 future 的异常在 `build()` 中重新抛出，同时取消/等待
其余 in-flight batch，冒泡到 `glossary_gen` 的 `except (SubprocessError, OSError)` →
SKIP，旧 slice 原封不动。**绝不写部分结果**（全量扫描尤其不能写出残缺 slice）。

## 错误处理

| 情况 | 行为 |
|------|------|
| batch 节流 429 / 超时 | 有界退避重试；用尽后上抛 |
| batch 硬错（参数/权限/非节流 4xx） | 不重试，立即上抛 |
| 任一 batch 最终失败 | 整体抛异常 → 上层 SKIP → 保留旧 slice |
| 全部成功 | 按序拼接 → extract_entries → 返回 |
| `GLOSSARY_BUILD_CONCURRENCY` 非法 | 回落默认 8 |

## 测试（`tests/test_glossary_build.py` 新增）

1. **输出顺序确定**：runner 按 batch 内容返回可辨识行，乱序完成也拼回原序。
2. **节流重试成功**：runner 前 N 次抛节流 `CalledProcessError`、之后成功，断言最终
   拿到结果且重试计数正确。
3. **硬错不重试**：非节流错误只调用一次即上抛。
4. **重试用尽整体失败**：持续抛节流，断言 `build()` 最终抛异常（→ 上层 SKIP），且
   不产出部分 entries。
5. **退避不真等**：sleep 用注入 sleeper / monkeypatch，测试快速。
6. **并发度边界**：batch 数 < 并发度时不起多余线程；非法 env 回落 8。

lint / `check-invariants` 层不受影响。
