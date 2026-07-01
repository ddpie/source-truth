"""Build-time glossary generator — runs a LOCAL `claude` (cc) CLI over the index
host's repo copy to produce the Chinese-term -> code-symbol map.

ARCHITECTURE NOTE (deliberate, scoped MVP exception): this is a BUILD-TIME engine
running on the index host, OUTSIDE the answering microVM. The MVP rule "no engine
outside the microVM" is about the per-query answering path (user input, session
isolation); building a glossary is an OFFLINE, no-user-input pass over code the host
already holds. cc reads the local copy with its own tools and we write the result to
/data/glossary/<project>/. See AGENTS.md "构建期引擎" boundary.

TOKEN FRUGALITY (engineering, by request):
  * INCREMENTAL by default — only the files a git-diff changed are handed to cc, never
    the whole repo. merge_incremental() splices the rebuilt slice into the existing
    index using per-source accounting (glossary.drop_sources), so a concept spanning
    several files keeps the parts that didn't change.
  * cc is told to emit JSONL ONLY (no prose / no markdown) to minimize OUTPUT tokens;
    extract_entries() still salvages valid lines if cc adds chatter anyway.
  * Empty diff -> no cc call at all (caller skips).

CONCURRENCY (wall-clock, not token count):
  * A full scan loops MANY cc batches; build() runs them on a ThreadPoolExecutor
    (default 8, env GLOSSARY_BUILD_CONCURRENCY) instead of serially. Output is
    reassembled in batch order, so results are identical to the old serial path.
  * Each batch retries on Bedrock throttle/timeout with bounded exponential backoff
    + jitter (env GLOSSARY_BUILD_RETRY_BASE_S / GLOSSARY_BUILD_MAX_RETRIES); a hard
    error or an exhausted retry fails the whole build -> glossary_gen keeps the old
    slice (SKIP), never a partial write. Cross-repo parallelism (systemd-run per
    subdir) is unchanged and stacks on top of this.

The cc invocation is injected (``runner``) so the orchestration is unit-testable
without shelling out; run_cc() is the default subprocess runner.
"""

from __future__ import annotations

import concurrent.futures
import json
import logging
import os
import random
import subprocess
import time
from dataclasses import replace
from typing import Callable

import glossary

logger = logging.getLogger("glossary-build")

# cc model/env on the index host (Bedrock). Kept here so the build path is explicit.
CC_BIN = "claude"
DEFAULT_TIMEOUT_S = 1200  # one cc batch; a full scan loops MANY batches under this per-batch limit
# Files per cc invocation. The whole file list goes into the `claude -p "<prompt>"` ARGV, so a
# large set (e.g. a full build of a repo with tens of thousands of files) blows the OS arg limit (Errno 7 "Argument list too
# long"). build() chunks `files` into batches of this size, one cc call each, and concatenates the
# outputs — keeping every argv well under the limit and bounding each call's runtime/cost.
CC_BATCH_FILES = 300

# LOCKDOWN for the build-time engine. Unlike the microVM answering agent (which mounts no
# filesystem and runs with tools=[]), the build engine HAS the repo on disk and legitimately
# needs READ tools (Read/Glob/Grep) to scan it. But it must NOT be able to write, execute, reach
# the network, or spawn subagents — otherwise a malicious file committed into an indexed repo
# (a poisoned comment, README, or .claude/settings.json) could drive cc to run Bash/Write/
# WebFetch on the index host, which holds the git token, Bedrock creds, and the only repo copy
# (host-side RCE / code-exfiltration). We deny the dangerous tools explicitly AND refuse to load
# any settings from the repo cwd (the .claude/CLAUDE.md instruction channel the microVM agent
# closes with setting_sources=[]). Mirrors agent_lib.WRITE_EXEC_TOOLS minus the read tools.
CC_DISALLOWED_TOOLS = (
    "Bash", "Write", "Edit", "MultiEdit", "NotebookEdit",
    "WebFetch", "WebSearch", "Task",
)


def build_prompt(files: list[str] | None, *, project: str) -> str:
    """Construct the cc build prompt. ``files`` None => full repo scan; a list =>
    scan ONLY those files (incremental, token-frugal). The schema block is identical
    either way so extract_entries() can parse both.

    The prompt demands JSONL-only output (no prose, no markdown fence) to keep OUTPUT
    tokens minimal; extract_entries() is the safety net if cc adds chatter regardless.
    """
    # TERSE + imperative ON PURPOSE: a long/explanatory prompt makes cc burn turns
    # "understanding the task" (observed: a verbose prompt times out >180s; this terse
    # form finishes in ~20s) AND costs more tokens. Keep it command-shaped.
    if files:
        scope = "Read ONLY these files (no others): " + ", ".join(files) + "."
    else:
        scope = ("Scan the repo for player-facing game concepts (races, classes, stats, "
                 "levels, loot, factions): code enums/fields, config keys, SQL table+column "
                 "names, data-table headers, AND docs/READMEs/design notes (where Chinese terms "
                 "and their English code names are often spelled out together). Skip vendored code.")
    return (
        f"Build a term glossary for game project '{project}'. {scope}\n"
        "Output ONLY JSONL — one JSON object per line, NO prose, NO markdown fences.\n"
        'Each line: {"concept_id":"<lower_slug>","kind":"symbol"|"alias","value":"<x>",'
        '"source":"<repo-relative path>","line":<int>,"confidence":"high"|"med"|"low"}\n'
        "kind=symbol: a code identifier/column/key that ACTUALLY appears in the file. "
        "kind=alias: a Chinese/colloquial term — BUT ONLY a Chinese string that LITERALLY "
        "appears in the code, a comment, a string literal, or config at that source:line.\n"
        "⭐ THE GOAL is BRIDGING: pair each Chinese term with the ENGLISH code symbol it names, "
        "under ONE concept_id. A concept is only useful if it has BOTH a symbol line AND an alias "
        "line sharing that concept_id. When Chinese text and an English identifier appear together "
        "or adjacent (a comment annotating a field/function, a config key with a Chinese label, a "
        "SQL column with a Chinese header), emit TWO lines with the SAME concept_id: one "
        "kind=symbol (the identifier) + one kind=alias (the Chinese). Do NOT put the Chinese in a "
        "concept of its own divorced from the symbol — that bridges nothing.\n"
        "Example — file has `int combatPower; // 战力，角色综合战斗力`:\n"
        '  {"concept_id":"combat_power","kind":"symbol","value":"combatPower","source":"S.cs","line":7,"confidence":"high"}\n'
        '  {"concept_id":"combat_power","kind":"alias","value":"战力","source":"S.cs","line":7,"confidence":"high"}\n'
        '  {"concept_id":"combat_power","kind":"alias","value":"战斗力","source":"S.cs","line":7,"confidence":"high"}\n'
        "🚫 HARD RULES — do NOT break:\n"
        "1. NEVER translate. NEVER invent or guess a Chinese alias. If a symbol has no Chinese "
        "text next to it in the actual file, emit ONLY its symbol line and NO alias line. An "
        "all-English file with no Chinese → emit symbol lines only, zero alias lines.\n"
        "2. Every alias `value` must be copy-pasted from text you actually read; `line` must be "
        "where that exact Chinese text appears. If you can't point to it in the file, don't emit it.\n"
        "3. When unsure, emit less. A missing alias is fine; a fabricated one is a bug.\n"
        "4. A Chinese term in PROSE (a doc paragraph) with no nearby code identifier you can name "
        "→ either pair it with the real symbol it refers to (if you can identify one in the repo) "
        "or DROP it. An alias with no symbol in its concept is near-useless; prefer pairing.\n"
        "Synonyms of the SAME concept share one concept_id (e.g. a SQL column, a config key, and "
        "a code field that are literally the same thing). confidence: high = symbol/alias text is "
        "right there at the cited line; med = inferred from nearby context; low = weak. Never use "
        "confidence to launder a guess — if the Chinese isn't in the file, it's not an alias at all."
    )


# Runs of CJK/East-Asian script for alias grounding. Covers Han (BMP U+4E00–9FFF + Ext-A
# U+3400–4DBF + Ext-B U+20000–2A6DF), plus Hiragana/Katakana (U+3040–30FF) and Hangul
# (U+AC00–D7AF + Jamo U+1100–11FF). Without the kana/hangul ranges, a fabricated Japanese/Korean
# alias would yield NO run → `_alias_grounded` returns True unconditionally (bypassing the guard
# that exists to drop cc's invented translations). The guard targets "invented non-Latin term for
# code"; covering the East-Asian scripts a game repo might use closes that bypass.
_CJK_RE = __import__("re").compile(
    r"[㐀-䶿一-鿿぀-ヿᄀ-ᇿ가-힯\U00020000-\U0002a6df]+")


def extract_entries(raw: str, *, reader: Callable[[str], str] | None = None) -> list[glossary.Entry]:
    """Salvage glossary Entries from cc's raw stdout. Tolerant by design: cc prepends
    prose and wraps output in ``` fences even when told not to, so we scan line by line,
    keep only lines that parse as a JSON OBJECT with the required entry fields, and run
    them through the SAME validation aggregate() uses (bad-charset symbols dropped here,
    before anything is written to disk). Non-entry JSON and prose are silently skipped.

    GROUNDING GUARD (deterministic, does not trust cc): cc demonstrably INVENTS Chinese
    aliases by translating English identifiers (observed on the host: 49 aliases for a header
    with ZERO Chinese chars). The prompt forbids this, but a prompt can't enforce it. So when
    ``reader`` is given (maps a repo-relative source path → its text), every `alias`'s CJK runs
    must LITERALLY appear in its cited source file, else the alias is dropped. Fail-closed: if
    the file can't be read, the alias is dropped. `symbol` entries are NOT grounding-checked
    (they're English identifiers validated by the charset whitelist; and a symbol cc emits that
    isn't in the file just yields an empty search, not a fabricated Chinese mapping). Without a
    reader (unit tests / callers without source access) grounding is skipped."""
    out: list[glossary.Entry] = []
    _cache: dict[str, str] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("{") or not line.endswith("}"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        try:
            e = glossary.Entry.from_dict(obj)
        except (KeyError, TypeError, ValueError):
            continue
        if e.kind not in glossary.VALID_KINDS:
            continue
        if not glossary.is_valid_concept_id(e.concept_id):
            continue
        if e.kind == "symbol" and not glossary.is_valid_symbol(e.value):
            continue  # drop injection / non-identifier seeds at the source
        if not e.value.strip():
            continue
        if e.kind == "alias" and reader is not None and not _alias_grounded(e, reader, _cache):
            continue  # fabricated/ungrounded Chinese alias — drop it (no translation/guessing)
        # CODE AS TRUTH: a term harvested from a DOC (non-code source) is secondary — docs describe
        # intent/plans that may diverge from code. Demote its confidence one notch so that for the
        # SAME concept a code-sourced entry always outranks it (aggregate takes the max), keeping
        # doc-only terms out of the prominent index and in the on-demand lookup layer. The alias is
        # still grounded (the Chinese literally appears in the doc); we just trust it less.
        if not glossary.is_code_source(e.source):
            e = replace(e, confidence=glossary.demote_confidence(e.confidence))
        out.append(e)
    return out


def _alias_grounded(e: glossary.Entry, reader: Callable[[str], str], cache: dict[str, str]) -> bool:
    """True iff every CJK run in the alias value literally appears in its source file. An alias
    with no CJK (e.g. a romanized/English colloquialism) is allowed through unchecked — the guard
    targets the specific failure of INVENTING Chinese for English code."""
    cjk_runs = _CJK_RE.findall(e.value)
    if not cjk_runs:
        return True
    if e.source not in cache:
        try:
            cache[e.source] = reader(e.source) or ""
        except Exception:  # noqa: BLE001 - unreadable source → fail closed below
            cache[e.source] = ""
    text = cache[e.source]
    if not text:
        return False  # can't verify → drop (never keep an unverifiable Chinese alias)
    return all(run in text for run in cjk_runs)


def merge_incremental(existing: list[glossary.Entry], *, changed: set[str],
                      deleted: set[str], rebuilt: list[glossary.Entry]) -> list[glossary.Entry]:
    """Splice a rebuilt slice into the existing index by per-source accounting.

    Drops every existing entry whose source is in `changed` OR `deleted` (so a removed
    symbol in a changed file doesn't linger), then appends `rebuilt` (the fresh entries
    for the changed files; deleted files contribute nothing). Entries from untouched
    files are preserved, keeping cross-file concepts intact.
    """
    kept = glossary.drop_sources(existing, changed | deleted)
    return kept + list(rebuilt)


def run_cc(prompt: str, *, cwd: str, model: str, region: str,
           timeout: int = DEFAULT_TIMEOUT_S) -> str:
    """Default cc runner: invoke the local claude CLI headless on Bedrock, return stdout.

    Raises subprocess.* on launch/timeout failure (caller decides whether a failed build
    is fatal or a skip). Env mirrors the microVM agent: CLAUDE_CODE_USE_BEDROCK=1 + model.
    """
    import os
    env = dict(os.environ)
    env["CLAUDE_CODE_USE_BEDROCK"] = "1"
    env["ANTHROPIC_MODEL"] = model
    env["AWS_REGION"] = region
    argv = [
        CC_BIN, "-p", prompt, "--output-format", "text",
        # Deny write/exec/network/subagent tools (read tools stay available for scanning).
        "--disallowed-tools", *CC_DISALLOWED_TOOLS,
        # Headless, non-interactive: never wait for an (absent) human to approve a tool.
        # 'default' keeps each tool's own permission rules; combined with the disallow list
        # above, the dangerous tools are gone and the read tools run without prompting.
        "--permission-mode", "default",
        # ISOLATION: load NO settings from disk — in particular NOT the repo cwd's
        # .claude/settings.json or CLAUDE.md, which a malicious repo could use as a trusted
        # instruction channel (the exact hole agent_lib closes with setting_sources=[]).
        "--setting-sources", "",
    ]
    proc = subprocess.run(  # noqa: S603 - fixed argv, no shell
        argv,
        cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout, check=False,
    )
    # A non-zero exit (Bedrock 429/403, OOM-SIGKILL, cc internal error) often comes WITH partial
    # or empty stdout. Returning that would let the caller merge an empty/garbage result and, on an
    # incremental build, silently DROP the changed files' entries (shrinking the slice). Raise so
    # glossary_gen's `except (SubprocessError, OSError)` SKIP path engages → the existing slice is
    # preserved intact rather than overwritten with degraded data.
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, argv[0], output=proc.stdout,
                                            stderr=(proc.stderr or "")[:200])
    return proc.stdout or ""


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
        stderr = exc.stderr or ""
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


def build(files: list[str] | None, *, project: str, cwd: str, model: str, region: str,
          runner: Callable[..., str] | None = None, timeout: int = DEFAULT_TIMEOUT_S) -> list[glossary.Entry]:
    """Run cc for the given scope and parse its output into entries. `files` None =>
    full scan; a (non-empty) list => incremental over just those files. Returns [] if
    cc produced nothing parseable (caller decides how to treat an empty build).

    `runner` defaults (None) to the module-level run_cc resolved AT CALL TIME, so a test
    monkeypatching glossary_build.run_cc takes effect (a bound default arg would not).

    Passes a source ``reader`` confined to ``cwd`` to extract_entries, so every Chinese alias
    is grounding-checked against the real file (drops cc's invented translations)."""
    import os
    run = runner if runner is not None else run_cc
    root = os.path.realpath(cwd)

    # Run cc in batches: the file list rides in the ARGV of `claude -p`, so passing thousands of
    # paths at once overflows the OS arg limit. A full scan (files is the whole candidate set) thus
    # loops many cc calls; a small incremental set is a single batch. files is None => full-repo
    # prompt with no list (a single call, no arg-limit risk).
    if files is None:
        batches: list[list[str] | None] = [None]
    else:
        batches = [files[i:i + CC_BATCH_FILES] for i in range(0, len(files), CC_BATCH_FILES)] or [[]]
    # Progress visibility: a full scan loops dozens of cc batches over 2-3 hours with NO output
    # until the very end (the slice is written atomically once, on completion). Without a per-batch
    # heartbeat there is no way to tell "still working" from "hung" except reverse-engineering the
    # process tree. Emit one structured line per batch (to logging => stderr) so the build is
    # observable; cc's JSONL product still goes only to the runner's captured stdout, unpolluted.
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

    repo_base = os.path.basename(root)

    def _candidate_rels(rel: str):
        # cc doesn't always emit a clean repo-relative path: it may use an absolute path, a "./"
        # prefix, backslashes, or prefix the repo dir name. Yield normalized candidates to try, so
        # a benign path-format quirk doesn't fail-close and drop a LEGITIMATE grounded alias.
        rel = rel.replace("\\", "/")
        cands = [rel, rel.lstrip("/")]
        # strip a leading "<repo>/" the agent sometimes carries over from cited paths
        if "/" in rel:
            head, tail = rel.lstrip("/").split("/", 1)
            if head == repo_base:
                cands.append(tail)
        # absolute path that already points inside the repo → relativize
        if rel.startswith("/"):
            try:
                ap = os.path.realpath(rel)
                if ap == root or ap.startswith(root + os.sep):
                    cands.append(os.path.relpath(ap, root))
            except OSError:
                pass
        seen = set()
        for c in cands:
            if c and c not in seen:
                seen.add(c)
                yield c

    def reader(rel: str) -> str:
        # Read a source file for alias grounding, confined under cwd. Tries normalized candidates;
        # a path that escapes the repo (after all normalizations) is refused → aliases fail closed.
        for cand in _candidate_rels(rel):
            p = os.path.realpath(os.path.join(root, cand))
            if p != root and not p.startswith(root + os.sep):
                continue
            try:
                with open(p, encoding="utf-8", errors="ignore") as fh:
                    return fh.read()
            except OSError:
                continue
        return ""

    return extract_entries(raw, reader=reader)
