# 术语表构建：单仓内 batch 并发 + 退避重试 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把单个仓库内 `glossary_build.build()` 逐批串行的 cc 调用改为有界并发（默认 8），并给每个 batch 加节流退避重试，保持现有「全或无」写盘与 SKIP 语义。

**Architecture:** 只改 `index-service/glossary_build.py`。用 `ThreadPoolExecutor` 并发跑 batch，结果按序号回填保证输出顺序确定；新增薄封装 `_run_with_retry` 包住注入的 `run`，仅对节流/超时做有界指数退避重试，硬错立即上抛；任一 batch 最终失败则整体抛异常，冒泡到 `glossary_gen` 的既有 SKIP 路径。对外契约（`build()` 签名、返回类型、抛 `SubprocessError`/`OSError`）不变。

**Tech Stack:** Python 3.12、`concurrent.futures.ThreadPoolExecutor`、`subprocess`、pytest、monkeypatch。

## Global Constraints

- 只修改 `index-service/glossary_build.py` 与 `index-service/tests/test_glossary_build.py`；`glossary_gen.py` / `activate_project.sh` / `glossary_refresh.sh` 不动。
- 注入点不变：`build(runner=...)` 是唯一注入点；单测 monkeypatch `glossary_build.run_cc`，绝不 shell out。
- 失败语义：任一 batch 重试用尽仍失败 → `build()` 抛异常（`subprocess.SubprocessError` 子类）→ 上层 SKIP，绝不写部分结果。
- 输出顺序必须与串行一致：`raw_parts` 按 batch 序号回填后 `"\n".join()`。
- 结构化 JSON 日志经 `logger`（`logging.getLogger("glossary-build")`）。
- 遵循 ruff/black 默认、类型标注。
- env 默认值：`GLOSSARY_BUILD_CONCURRENCY=8`、`GLOSSARY_BUILD_RETRY_BASE_S=4`、`GLOSSARY_BUILD_MAX_RETRIES=3`；非法值一律回落默认。
- Conventional Commits，英文 message，不加 AI 署名 trailer。

---

### Task 1: 节流判定 + 退避重试封装 `_run_with_retry`

**Files:**
- Modify: `index-service/glossary_build.py`（新增 `_is_throttle_error`、`_run_with_retry`、三个 env 读取 helper；imports 增加 `os`、`random`、`time`、`concurrent.futures`）
- Test: `index-service/tests/test_glossary_build.py`

**Interfaces:**
- Consumes: 模块级 `run_cc(prompt, *, cwd, model, region, timeout)`、`logger`、`DEFAULT_TIMEOUT_S`。
- Produces:
  - `_is_throttle_error(exc: BaseException) -> bool` — True 当异常是 `subprocess.TimeoutExpired`，或 `subprocess.CalledProcessError` 且其 `stderr` 命中节流关键字（`throttl`/`429`/`too many requests`/`rate exceeded`，大小写不敏感）。
  - `_retry_base_s() -> float`、`_max_retries() -> int`、`_build_concurrency() -> int` — 读对应 env，非法/缺省回落 `4.0`/`3`/`8`。
  - `_run_with_retry(run, *, prompt, cwd, model, region, timeout, batch_idx, sleeper=time.sleep, rng=random.uniform) -> str` — 调 `run(prompt, cwd=..., model=..., region=..., timeout=...)`；捕获异常：可重试且未超 `_max_retries()` 则 `sleeper(_retry_base_s()*2**attempt + rng(0, _retry_base_s()))` 后重试并打 `glossary_build_retry` 日志；否则上抛。返回成功的 stdout。

- [ ] **Step 1: 写失败测试**

在 `tests/test_glossary_build.py` 末尾追加：

```python
import subprocess as _subp  # noqa: E402


def _throttle_err():
    return _subp.CalledProcessError(1, "claude", output="", stderr="ThrottlingException: rate exceeded")


def _hard_err():
    return _subp.CalledProcessError(2, "claude", output="", stderr="invalid --model foo")


def test_is_throttle_error_matches_429_and_timeout():
    assert glossary_build._is_throttle_error(_throttle_err()) is True
    assert glossary_build._is_throttle_error(_subp.TimeoutExpired("claude", 1)) is True
    assert glossary_build._is_throttle_error(_hard_err()) is False
    assert glossary_build._is_throttle_error(ValueError("x")) is False


def test_run_with_retry_retries_throttle_then_succeeds(monkeypatch):
    monkeypatch.setenv("GLOSSARY_BUILD_MAX_RETRIES", "3")
    monkeypatch.setenv("GLOSSARY_BUILD_RETRY_BASE_S", "1")
    calls = {"n": 0}

    def run(prompt, *, cwd, model, region, timeout):
        calls["n"] += 1
        if calls["n"] <= 2:
            raise _throttle_err()
        return '{"ok":1}'

    slept = []
    out = glossary_build._run_with_retry(
        run, prompt="p", cwd="/x", model="m", region="r",
        timeout=1, batch_idx=1, sleeper=slept.append, rng=lambda a, b: 0.0)
    assert out == '{"ok":1}'
    assert calls["n"] == 3
    assert len(slept) == 2  # two backoffs before the 3rd success


def test_run_with_retry_hard_error_no_retry(monkeypatch):
    monkeypatch.setenv("GLOSSARY_BUILD_MAX_RETRIES", "3")
    calls = {"n": 0}

    def run(prompt, *, cwd, model, region, timeout):
        calls["n"] += 1
        raise _hard_err()

    try:
        glossary_build._run_with_retry(
            run, prompt="p", cwd="/x", model="m", region="r",
            timeout=1, batch_idx=1, sleeper=lambda s: None, rng=lambda a, b: 0.0)
        assert False, "expected CalledProcessError"
    except _subp.CalledProcessError:
        pass
    assert calls["n"] == 1  # hard error: no retry


def test_run_with_retry_exhausts_then_raises(monkeypatch):
    monkeypatch.setenv("GLOSSARY_BUILD_MAX_RETRIES", "2")
    monkeypatch.setenv("GLOSSARY_BUILD_RETRY_BASE_S", "1")
    calls = {"n": 0}

    def run(prompt, *, cwd, model, region, timeout):
        calls["n"] += 1
        raise _throttle_err()

    try:
        glossary_build._run_with_retry(
            run, prompt="p", cwd="/x", model="m", region="r",
            timeout=1, batch_idx=1, sleeper=lambda s: None, rng=lambda a, b: 0.0)
        assert False, "expected CalledProcessError after exhausting retries"
    except _subp.CalledProcessError:
        pass
    assert calls["n"] == 3  # 1 initial + 2 retries


def test_build_concurrency_env_fallback(monkeypatch):
    monkeypatch.delenv("GLOSSARY_BUILD_CONCURRENCY", raising=False)
    assert glossary_build._build_concurrency() == 8
    monkeypatch.setenv("GLOSSARY_BUILD_CONCURRENCY", "not-a-number")
    assert glossary_build._build_concurrency() == 8
    monkeypatch.setenv("GLOSSARY_BUILD_CONCURRENCY", "0")
    assert glossary_build._build_concurrency() == 8  # <=0 falls back
    monkeypatch.setenv("GLOSSARY_BUILD_CONCURRENCY", "5")
    assert glossary_build._build_concurrency() == 5
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd index-service && python3 -m pytest tests/test_glossary_build.py -k "throttle or retry or concurrency" -v`
Expected: FAIL — `AttributeError: module 'glossary_build' has no attribute '_is_throttle_error'`（及其余新符号）。

- [ ] **Step 3: 实现**

在 `glossary_build.py` 顶部 imports 补齐（放在现有 `import subprocess` 附近，`from __future__` 之后）：

```python
import concurrent.futures
import os
import random
import time
```

在 `run_cc` 定义**之后**、`build` 定义**之前**插入：

```python
# --- concurrency + backoff for the batch loop -------------------------------
# Env-tunable knobs (illegal / non-positive values fall back to the default).
_DEFAULT_CONCURRENCY = 8
_DEFAULT_RETRY_BASE_S = 4.0
_DEFAULT_MAX_RETRIES = 3

# Bedrock throttle signatures. cc surfaces these on stderr when the model endpoint
# rate-limits; we retry ONLY these (plus timeouts), never hard errors (bad args,
# AccessDenied, non-throttle 4xx) — retrying those just wastes time and tokens.
_THROTTLE_MARKERS = ("throttl", "429", "too many requests", "rate exceeded")


def _env_int(name: str, default: int) -> int:
    try:
        v = int(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return v if v > 0 else default


def _env_float(name: str, default: float) -> float:
    try:
        v = float(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return v if v > 0 else default


def _build_concurrency() -> int:
    return _env_int("GLOSSARY_BUILD_CONCURRENCY", _DEFAULT_CONCURRENCY)


def _retry_base_s() -> float:
    return _env_float("GLOSSARY_BUILD_RETRY_BASE_S", _DEFAULT_RETRY_BASE_S)


def _max_retries() -> int:
    return _env_int("GLOSSARY_BUILD_MAX_RETRIES", _DEFAULT_MAX_RETRIES)


def _is_throttle_error(exc: BaseException) -> bool:
    """True iff exc is a retriable throttle/timeout. Timeouts count (a batch that timed
    out is usually the endpoint being slow under load). A CalledProcessError counts only
    when its stderr carries a throttle marker — a hard error (bad flag, AccessDenied) does
    NOT, so it bubbles up immediately without burning retries."""
    if isinstance(exc, subprocess.TimeoutExpired):
        return True
    if isinstance(exc, subprocess.CalledProcessError):
        stderr = (exc.stderr or "")
        low = stderr.lower() if isinstance(stderr, str) else ""
        return any(m in low for m in _THROTTLE_MARKERS)
    return False


def _run_with_retry(run: Callable[..., str], *, prompt: str, cwd: str, model: str,
                    region: str, timeout: int, batch_idx: int,
                    sleeper: Callable[[float], None] = time.sleep,
                    rng: Callable[[float, float], float] = random.uniform) -> str:
    """Call `run` for one batch with bounded exponential backoff on throttle/timeout.
    Backoff is base*2**attempt + jitter to de-correlate concurrent batches (avoid
    back-to-back retries all hammering the endpoint at once). Hard errors and a final
    exhausted throttle both raise — the caller (build) turns that into an overall failure
    so glossary_gen keeps the old slice (SKIP)."""
    base = _retry_base_s()
    max_retries = _max_retries()
    attempt = 0
    while True:
        try:
            return run(prompt, cwd=cwd, model=model, region=region, timeout=timeout)
        except Exception as exc:  # noqa: BLE001 - classify then re-raise
            if not _is_throttle_error(exc) or attempt >= max_retries:
                raise
            wait = base * (2 ** attempt) + rng(0.0, base)
            logger.warning(json.dumps({"event": "glossary_build_retry", "batch": batch_idx,
                                        "attempt": attempt + 1, "max": max_retries,
                                        "wait_s": round(wait, 2), "detail": str(exc)[:120]}))
            sleeper(wait)
            attempt += 1
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd index-service && python3 -m pytest tests/test_glossary_build.py -k "throttle or retry or concurrency" -v`
Expected: PASS（5 个新测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add index-service/glossary_build.py index-service/tests/test_glossary_build.py
git commit -m "feat(glossary): add throttle-aware backoff retry for cc batches"
```

---

### Task 2: `build()` 改为并发跑 batch

**Files:**
- Modify: `index-service/glossary_build.py:276-285`（`real_batches` 之后的串行 `for` 循环）
- Test: `index-service/tests/test_glossary_build.py`

**Interfaces:**
- Consumes: `_run_with_retry`、`_build_concurrency`（Task 1）、现有 `build_prompt`、`logger`、`real_batches`。
- Produces: `build()` 行为不变的对外契约；内部 `raw_parts` 按 batch 序号回填。

- [ ] **Step 1: 写失败测试**

追加到 `tests/test_glossary_build.py`：

```python
def test_build_batches_preserve_order_under_concurrency(tmp_path, monkeypatch):
    # 700 files -> 3 batches of 300/300/100. Runner tags output by first file in the
    # batch so we can assert the concatenated raw is in batch order regardless of which
    # thread finishes first. Each emits one valid symbol entry with a batch-ordinal concept.
    monkeypatch.setenv("GLOSSARY_BUILD_CONCURRENCY", "4")
    files = [f"src/f{i}.cs" for i in range(700)]

    def run(prompt, *, cwd, model, region, timeout):
        # the prompt lists the batch's files; find which batch by its first file index
        first = next(i for i in range(700) if f"src/f{i}.cs" in prompt)
        ordinal = first // 300
        return json.dumps({"concept_id": f"c{ordinal}", "kind": "symbol",
                           "value": f"Sym{ordinal}", "source": "src/f.cs",
                           "line": 1, "confidence": "high"})

    monkeypatch.setattr(glossary_build, "run_cc", run)
    ents = glossary_build.build(files, project="p", cwd=str(tmp_path), model="m", region="r")
    concepts = [e.concept_id for e in ents if e.kind == "symbol"]
    assert concepts == ["c0", "c1", "c2"]  # strict batch order, not completion order


def test_build_propagates_batch_failure_as_overall(monkeypatch, tmp_path):
    # One batch throttles forever -> retries exhaust -> build() raises (=> upstream SKIP).
    monkeypatch.setenv("GLOSSARY_BUILD_CONCURRENCY", "4")
    monkeypatch.setenv("GLOSSARY_BUILD_MAX_RETRIES", "1")
    monkeypatch.setenv("GLOSSARY_BUILD_RETRY_BASE_S", "1")
    monkeypatch.setattr(glossary_build.time, "sleep", lambda s: None)
    files = [f"src/f{i}.cs" for i in range(400)]  # 2 batches

    def run(prompt, *, cwd, model, region, timeout):
        if "src/f300.cs" in prompt:  # the second batch always throttles
            raise _subp.CalledProcessError(1, "claude", stderr="ThrottlingException")
        return json.dumps({"concept_id": "c0", "kind": "symbol", "value": "Sym0",
                           "source": "src/f.cs", "line": 1, "confidence": "high"})

    monkeypatch.setattr(glossary_build, "run_cc", run)
    try:
        glossary_build.build(files, project="p", cwd=str(tmp_path), model="m", region="r")
        assert False, "expected build() to raise on a batch that never succeeds"
    except _subp.CalledProcessError:
        pass
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd index-service && python3 -m pytest tests/test_glossary_build.py -k "preserve_order or propagates_batch" -v`
Expected: FAIL — 顺序测试可能通过（串行本就有序）但失败传播测试会因为当前 `run_cc` 直接抛未经重试而语义不同；更关键是并发未实现，`_run_with_retry` 未接入。（若两测试均意外通过，说明未真正改到并发路径，继续 Step 3。）

- [ ] **Step 3: 实现**

把 `glossary_build.py` 中这段串行循环：

```python
    real_batches = [b for b in batches if b != []]
    total = len(real_batches)
    raw_parts: list[str] = []
    for idx, batch in enumerate(real_batches, start=1):
        nfiles = "full-repo" if batch is None else len(batch)
        logger.info(json.dumps({"event": "glossary_build_batch", "project": project,
                                 "batch": idx, "batches": total, "files": nfiles}))
        prompt = build_prompt(batch, project=project)
        raw_parts.append(run(prompt, cwd=cwd, model=model, region=region, timeout=timeout))
    raw = "\n".join(raw_parts)
```

替换为：

```python
    real_batches = [b for b in batches if b != []]
    total = len(real_batches)

    def _one_batch(idx: int, batch: list[str] | None) -> str:
        nfiles = "full-repo" if batch is None else len(batch)
        logger.info(json.dumps({"event": "glossary_build_batch", "project": project,
                                 "batch": idx, "batches": total, "files": nfiles}))
        prompt = build_prompt(batch, project=project)
        return _run_with_retry(run, prompt=prompt, cwd=cwd, model=model, region=region,
                               timeout=timeout, batch_idx=idx)

    # Concurrency capped at the batch count (no idle threads for a small incremental set).
    # Results are keyed by batch index and reassembled IN ORDER, so output is identical to
    # the old serial join regardless of completion order. A batch whose retries are exhausted
    # raises here; we surface the FIRST such error (and stop consuming) so build() fails as a
    # whole -> glossary_gen keeps the old slice (SKIP). No partial slice is ever written.
    max_workers = min(_build_concurrency(), total) if total else 1
    raw_by_idx: dict[int, str] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        futs = {pool.submit(_one_batch, idx, batch): idx
                for idx, batch in enumerate(real_batches, start=1)}
        for fut in concurrent.futures.as_completed(futs):
            raw_by_idx[futs[fut]] = fut.result()  # re-raises this batch's exhausted error
    raw = "\n".join(raw_by_idx[i] for i in sorted(raw_by_idx))
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd index-service && python3 -m pytest tests/test_glossary_build.py -v`
Expected: PASS（全文件所有测试，含既有测试与两个新测试）。

- [ ] **Step 5: 提交**

```bash
git add index-service/glossary_build.py index-service/tests/test_glossary_build.py
git commit -m "feat(glossary): run cc batches concurrently, preserving output order"
```

---

### Task 3: 更新模块 docstring + 离线套件回归

**Files:**
- Modify: `index-service/glossary_build.py:11-18`（模块 docstring 的 TOKEN FRUGALITY 段，补一句并发说明）

**Interfaces:**
- Consumes: 无新符号。
- Produces: 无。

- [ ] **Step 1: 更新 docstring**

在 `glossary_build.py` 模块 docstring 的 `TOKEN FRUGALITY` 段落之后（`The cc invocation is injected...` 之前）插入一段：

```
CONCURRENCY (wall-clock, not token count):
  * A full scan loops MANY cc batches; build() runs them on a ThreadPoolExecutor
    (default 8, env GLOSSARY_BUILD_CONCURRENCY) instead of serially. Output is
    reassembled in batch order, so results are identical to the old serial path.
  * Each batch retries on Bedrock throttle/timeout with bounded exponential backoff
    + jitter (env GLOSSARY_BUILD_RETRY_BASE_S / GLOSSARY_BUILD_MAX_RETRIES); a hard
    error or an exhausted retry fails the whole build -> glossary_gen keeps the old
    slice (SKIP), never a partial write. Cross-repo parallelism (systemd-run per
    subdir) is unchanged and stacks on top of this.
```

- [ ] **Step 2: 跑完整离线套件**

Run: `cd index-service && python3 -m pytest tests/ -q`
Expected: PASS（全部 index-service 测试）。

- [ ] **Step 3: 跑仓库 lint / 结构自检**

Run: `./scripts/test.sh --lint`
Expected: PASS（ruff + check-versions + check-invariants）。若 `test.sh --lint` 不是有效子命令，改跑 `./scripts/test.sh`（离线默认 = lint + unit + typecheck）。

- [ ] **Step 4: 提交**

```bash
git add index-service/glossary_build.py
git commit -m "docs(glossary): document concurrent batch build and backoff knobs"
```

---

## Self-Review

**Spec coverage:**
- 并发跑 batch（默认 8、env 可调、顺序确定） → Task 2 + Task 1 `_build_concurrency`。✓
- 每 batch 有界退避重试（节流/超时重试、硬错不重试、抖动错峰、结构化日志） → Task 1。✓
- 失败即整体失败、保持全或无写盘 / SKIP → Task 2 Step 3 + `test_build_propagates_batch_failure_as_overall`。✓
- 注入点不变、单测不 shell out → 所有测试 monkeypatch `run_cc`/`_run_with_retry` 的 `run`。✓
- 六个测试点（顺序确定 / 重试成功 / 硬错不重试 / 用尽失败 / 退避不真等 / 并发度边界） → Task 1（后四）+ Task 2（前两，其中顺序 = 并发下确定，用尽失败 = 整体传播）。✓
- 对外契约、上层文件不动 → Global Constraints，仅改 2 文件。✓

**Placeholder scan:** 无 TBD/TODO；每个代码步骤含完整代码与确切命令。✓

**Type consistency:** `_run_with_retry` 的关键字签名（`prompt/cwd/model/region/timeout/batch_idx/sleeper/rng`）在 Task 1 定义、Task 2 调用一致；`_build_concurrency`/`_retry_base_s`/`_max_retries` 返回 int/float/int 一致；env 名 `GLOSSARY_BUILD_CONCURRENCY`/`_RETRY_BASE_S`/`_MAX_RETRIES` 全篇一致。✓
