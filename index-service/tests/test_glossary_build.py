"""Unit tests for glossary_build.py — the build-time generator orchestration.

The generator runs a LOCAL `claude` (cc) CLI against the index host's repo copy and
turns its output into glossary entries. cc output is NOT trusted to be clean (it
prepends prose and wraps JSONL in ``` fences even when told not to — observed on the
host), so extract_entries() must salvage the valid JSONL lines from messy output.

Incremental orchestration (merge_incremental) is pure given the pieces: existing
entries + changed/deleted files + freshly-built entries -> the new entry list, using
glossary.drop_sources for per-file accounting. The cc subprocess itself is injected so
these tests never shell out.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import glossary  # noqa: E402
import glossary_build  # noqa: E402


# --- extract_entries: salvage JSONL from messy cc output ----------------------
def test_extract_skips_prose_and_code_fences():
    raw = (
        "Enums live in SharedDefines.h. Producing the glossary:\n"
        "```\n"
        '{"concept_id":"player_race","kind":"symbol","value":"RACE_HUMAN","source":"a.h","line":37,"confidence":"high"}\n'
        '{"concept_id":"player_race","kind":"alias","value":"人类","source":"a.h","line":37,"confidence":"high"}\n'
        "```\n"
        "That's all.\n"
    )
    entries = glossary_build.extract_entries(raw)
    assert [e.value for e in entries] == ["RACE_HUMAN", "人类"]
    assert entries[0].concept_id == "player_race"


def test_extract_ignores_non_entry_json_objects():
    # A stray JSON object that isn't an entry (missing required fields) is skipped,
    # not fatal — the surrounding real entries still load.
    raw = (
        '{"some":"other","json":1}\n'
        '{"concept_id":"c","kind":"symbol","value":"foo","source":"f","line":1,"confidence":"high"}\n'
    )
    entries = glossary_build.extract_entries(raw)
    assert [e.value for e in entries] == ["foo"]


def test_extract_drops_invalid_symbol_values():
    # Defense-in-depth: a symbol whose value isn't identifier-shaped (injection) is
    # dropped at extraction, before it can ever be written to disk.
    raw = (
        '{"concept_id":"c","kind":"symbol","value":"rm -rf /","source":"f","line":1,"confidence":"high"}\n'
        '{"concept_id":"c","kind":"symbol","value":"goodSym","source":"f","line":2,"confidence":"high"}\n'
        '{"concept_id":"c","kind":"alias","value":"任意中文","source":"f","line":3,"confidence":"high"}\n'
    )
    entries = glossary_build.extract_entries(raw)
    vals = [(e.kind, e.value) for e in entries]
    assert ("symbol", "goodSym") in vals
    assert ("alias", "任意中文") in vals
    assert all(v != "rm -rf /" for _, v in vals)


def test_extract_empty_output_is_empty_list():
    assert glossary_build.extract_entries("") == []
    assert glossary_build.extract_entries("no json here at all\n```\n```") == []


# --- grounding guard: aliases must LITERALLY appear in their source file ------
def test_extract_drops_alias_not_present_in_source():
    # cc demonstrably INVENTS Chinese aliases for all-English code (observed on host:
    # 49 aliases for a 0-CJK-char header). The deterministic guard: an alias survives only
    # if its Chinese text is actually in the cited source file. `reader` returns file text.
    raw = (
        '{"concept_id":"race","kind":"symbol","value":"RACE_HUMAN","source":"a.h","line":1,"confidence":"high"}\n'
        '{"concept_id":"race","kind":"alias","value":"种族","source":"a.h","line":1,"confidence":"high"}\n'  # NOT in file
        '{"concept_id":"skill","kind":"alias","value":"火球术","source":"b.cs","line":3,"confidence":"high"}\n'  # IS in file
    )
    files = {"a.h": "enum Races { RACE_HUMAN };\n", "b.cs": "// 火球术 fireball\n"}
    entries = glossary_build.extract_entries(raw, reader=lambda p: files.get(p, ""))
    kinds = {(e.kind, e.value) for e in entries}
    assert ("symbol", "RACE_HUMAN") in kinds      # symbols never grounding-checked (English ids)
    assert ("alias", "种族") not in kinds          # invented → dropped
    assert ("alias", "火球术") in kinds            # grounded → kept


def test_extract_without_reader_keeps_aliases_backcompat():
    # No reader supplied (unit tests / callers that can't read source) → no grounding check,
    # aliases pass through (the charset/concept-id validation still applies).
    raw = '{"concept_id":"c","kind":"alias","value":"任意","source":"x","line":1,"confidence":"high"}\n'
    entries = glossary_build.extract_entries(raw)
    assert [e.value for e in entries] == ["任意"]


def test_extract_alias_reader_missing_file_drops_alias():
    # If the source file can't be read (reader returns ""), an alias can't be grounded → drop it
    # (fail closed: never keep an unverifiable Chinese alias).
    raw = '{"concept_id":"c","kind":"alias","value":"中文","source":"gone.cs","line":1,"confidence":"high"}\n'
    entries = glossary_build.extract_entries(raw, reader=lambda p: "")
    assert entries == []


# --- merge_incremental: per-source accounting -----------------------------------
def test_merge_incremental_replaces_changed_keeps_unchanged():
    existing = [
        glossary.Entry("combat_power", "symbol", "combatPower", "src/Player.cpp", 42, "high"),
        glossary.Entry("combat_power", "symbol", "CombatPower.calc", "src/Combat.cpp", 10, "high"),
    ]
    # Combat.cpp changed; re-build over it yields a renamed symbol. Player.cpp untouched.
    rebuilt = [glossary.Entry("combat_power", "symbol", "CalcCombatPower", "src/Combat.cpp", 11, "high")]
    merged = glossary_build.merge_incremental(
        existing, changed={"src/Combat.cpp"}, deleted=set(), rebuilt=rebuilt)
    concepts = glossary.aggregate(merged)
    assert set(concepts["combat_power"].symbols) == {"combatPower", "CalcCombatPower"}


def test_merge_incremental_deleted_file_drops_its_entries():
    existing = [
        glossary.Entry("c", "symbol", "x", "keep.cpp", 1, "high"),
        glossary.Entry("c", "symbol", "y", "gone.cpp", 2, "high"),
    ]
    merged = glossary_build.merge_incremental(
        existing, changed=set(), deleted={"gone.cpp"}, rebuilt=[])
    assert [e.value for e in merged] == ["x"]


def test_merge_incremental_changed_also_cleared_before_readd():
    # A changed file's OLD entries must be cleared even if the rebuild re-adds some —
    # otherwise a removed symbol would linger. Player.cpp changed; rebuild drops oldSym.
    existing = [glossary.Entry("c", "symbol", "oldSym", "Player.cpp", 1, "high")]
    rebuilt = [glossary.Entry("c", "symbol", "newSym", "Player.cpp", 1, "high")]
    merged = glossary_build.merge_incremental(
        existing, changed={"Player.cpp"}, deleted=set(), rebuilt=rebuilt)
    assert [e.value for e in merged] == ["newSym"]  # oldSym gone, not duplicated


# --- build_prompt: token-frugal, file-scoped ----------------------------------
def test_build_prompt_lists_only_target_files():
    p = glossary_build.build_prompt(["src/A.cpp", "src/B.h"], project="mangos")
    assert "src/A.cpp" in p and "src/B.h" in p
    # frugality: must instruct JSONL-only (no prose/markdown) to minimize output tokens
    assert "JSONL" in p or "one JSON object per line" in p.lower() or "一行一个" in p


def test_build_prompt_forbids_translation_and_invention():
    # CRITICAL quality rule: cc must NOT translate/guess Chinese aliases. An alias may only be
    # Chinese text that literally appears in the file; an all-English file → symbols only.
    p = glossary_build.build_prompt(["a.cpp"], project="mangos")
    low = p.lower()
    assert "never translate" in low
    assert "invent" in low or "guess" in low
    # must state the all-English-file → no-alias behavior
    assert "no alias" in low or "zero alias" in low or "symbol lines only" in low


# --- run_cc lockdown (security): build-time engine must be sandboxed ----------
def test_run_cc_locks_down_write_exec_and_settings(monkeypatch):
    # The build-time cc runs on the privileged index host over an attacker-influenceable
    # repo. It MUST deny write/exec/network/subagent tools and refuse to load repo settings
    # (.claude/CLAUDE.md), or a poisoned repo file could drive host-side RCE/exfiltration.
    captured = {}

    class _P:
        stdout = ""
        returncode = 0

    def fake_run(argv, **kw):
        captured["argv"] = argv
        captured["kw"] = kw
        return _P()
    monkeypatch.setattr(glossary_build.subprocess, "run", fake_run)
    glossary_build.run_cc("prompt", cwd="/data/repo/x", model="m", region="r")
    argv = captured["argv"]
    # Settings isolation: must NOT load any on-disk settings (repo .claude/CLAUDE.md).
    assert "--setting-sources" in argv
    assert argv[argv.index("--setting-sources") + 1] == ""
    # Dangerous tools denied.
    assert "--disallowed-tools" in argv
    for t in ("Bash", "Write", "Edit", "WebFetch", "Task"):
        assert t in argv, f"{t} must be in the disallowed list"
    # Not bypassing permissions wholesale.
    assert "--dangerously-skip-permissions" not in argv
    assert "--allow-dangerously-skip-permissions" not in argv
    # Confined to the repo copy it was told to scan.
    assert captured["kw"].get("cwd") == "/data/repo/x"


# --- R2 gaps: build()'s REAL cwd-confined reader + grounding edges ---
def test_build_real_reader_grounds_and_confines(tmp_path, monkeypatch):
    # The shipped grounding path (build()'s reader, not an injected lambda): a grounded alias
    # survives, an invented one is dropped, and an escaping source path fails closed.
    repo = tmp_path / "repo"
    (repo / "src").mkdir(parents=True)
    (repo / "src" / "f.cs").write_text("// 火球术 fireball\nclass Fireball {}\n", encoding="utf-8")
    raw = (
        '{"concept_id":"skill","kind":"symbol","value":"Fireball","source":"src/f.cs","line":2,"confidence":"high"}\n'
        '{"concept_id":"skill","kind":"alias","value":"火球术","source":"src/f.cs","line":1,"confidence":"high"}\n'  # grounded
        '{"concept_id":"skill","kind":"alias","value":"冰冻术","source":"src/f.cs","line":1,"confidence":"high"}\n'  # invented
        '{"concept_id":"x","kind":"alias","value":"逃逸","source":"../../etc/passwd","line":1,"confidence":"high"}\n'  # escape
    )
    monkeypatch.setattr(glossary_build, "run_cc", lambda *a, **k: raw)
    ents = glossary_build.build(["src/f.cs"], project="p", cwd=str(repo), model="m", region="r")
    vals = {(e.kind, e.value) for e in ents}
    assert ("symbol", "Fireball") in vals
    assert ("alias", "火球术") in vals       # grounded → kept
    assert ("alias", "冰冻术") not in vals   # invented → dropped
    assert ("alias", "逃逸") not in vals     # escaping source → fail-closed drop


def test_build_real_reader_normalizes_abs_and_prefixed_paths(tmp_path, monkeypatch):
    # cc sometimes emits absolute / ./ / <repo>-prefixed source paths; a grounded alias must
    # still survive (not fail-closed on a benign path-format quirk).
    repo = tmp_path / "myrepo"
    (repo / "src").mkdir(parents=True)
    (repo / "src" / "f.cs").write_text("// 战力 combatPower\n", encoding="utf-8")
    abs_src = str((repo / "src" / "f.cs"))
    raw = (
        '{"concept_id":"cp","kind":"alias","value":"战力","source":"' + abs_src + '","line":1,"confidence":"high"}\n'
        '{"concept_id":"cp","kind":"alias","value":"力量值","source":"myrepo/src/f.cs","line":1,"confidence":"high"}\n'
    )
    monkeypatch.setattr(glossary_build, "run_cc", lambda *a, **k: raw)
    ents = glossary_build.build(["src/f.cs"], project="p", cwd=str(repo), model="m", region="r")
    vals = {e.value for e in ents if e.kind == "alias"}
    assert "战力" in vals          # absolute path normalized + grounded
    assert "力量值" not in vals     # not in file → dropped (力量值 absent), proves grounding still runs


def test_alias_grounded_partial_run_dropped():
    # An alias with two CJK runs where only one is in the file must be DROPPED (all() semantics).
    e = glossary.Entry("c", "alias", "火球术", "f", 1, "high")
    assert not glossary_build._alias_grounded(e, lambda p: "火球 only", {})  # 术 missing
    assert glossary_build._alias_grounded(e, lambda p: "火球术 here", {})


def test_alias_grounded_no_cjk_passes():
    # A no-CJK alias (romanized) isn't a translation-invention risk → passes unchecked.
    e = glossary.Entry("c", "alias", "BP", "f", 1, "high")
    assert glossary_build._alias_grounded(e, lambda p: "nothing", {})


# --- R3 gaps: Ext-A/B CJK grounding; reader cache ---
def test_alias_grounded_extension_chars():
    # The widened _CJK_RE must treat Ext-A (㐀) / Ext-B (𠀀) as CJK runs, so a fabricated
    # all-extension-char alias is grounding-checked (not unconditionally kept). Revert of the
    # regex to bare [一-鿿]+ would yield zero runs → kept; this test would then fail.
    ext_a = glossary.Entry("c", "alias", "㐀", "f", 1, "high")
    ext_b = glossary.Entry("c", "alias", "\U00020000", "f", 1, "high")
    assert not glossary_build._alias_grounded(ext_a, lambda p: "no cjk here", {})   # absent → dropped
    assert glossary_build._alias_grounded(ext_a, lambda p: "has 㐀 char", {})        # present → kept
    assert not glossary_build._alias_grounded(ext_b, lambda p: "nope", {})
    assert glossary_build._alias_grounded(ext_b, lambda p: "x \U00020000 y", {})


def test_alias_grounded_uses_per_source_cache():
    # The source text is read once per source and cached; a reader that fails on the 2nd call
    # must not affect a 2nd alias from the SAME source (served from cache).
    calls = {"n": 0}
    def reader(p):
        calls["n"] += 1
        if calls["n"] > 1:
            raise OSError("second read fails")
        return "火球术 here"
    cache: dict = {}
    e1 = glossary.Entry("c", "alias", "火球术", "same.cs", 1, "high")
    e2 = glossary.Entry("c", "alias", "火球术", "same.cs", 2, "high")
    assert glossary_build._alias_grounded(e1, reader, cache)
    assert glossary_build._alias_grounded(e2, reader, cache)   # cache hit, reader not called again
    assert calls["n"] == 1


# --- R5 resilience: non-zero cc exit must raise (→ caller SKIP, preserve old slice) ---
def test_run_cc_raises_on_nonzero_exit(monkeypatch):
    import subprocess as _sp
    class _P:
        returncode = 137  # OOM-SIGKILL style
        stdout = ""        # empty/partial output
        stderr = "killed"
    monkeypatch.setattr(glossary_build.subprocess, "run", lambda *a, **k: _P())
    import pytest
    with pytest.raises(_sp.CalledProcessError):
        glossary_build.run_cc("p", cwd="/tmp", model="m", region="r")


# --- R6: grounding covers kana/hangul, not just Han ---
def test_alias_grounded_kana_hangul():
    ja = glossary.Entry("c", "alias", "ひらがな", "f", 1, "high")
    ko = glossary.Entry("c", "alias", "한국어", "f", 1, "high")
    # absent → dropped (not unconditionally kept)
    assert not glossary_build._alias_grounded(ja, lambda p: "no jp here", {})
    assert not glossary_build._alias_grounded(ko, lambda p: "no kr here", {})
    # present → kept
    assert glossary_build._alias_grounded(ja, lambda p: "コメント ひらがな ok", {})
    assert glossary_build._alias_grounded(ko, lambda p: "주석 한국어 ok", {})


# --- code-as-truth: doc-sourced entries demoted so code outranks them ---
def test_doc_sourced_entry_confidence_demoted():
    # A term harvested from a DOC (.md) is secondary → confidence demoted one notch; a code-sourced
    # one keeps its level. So for the same concept, code outranks doc (aggregate takes the max).
    raw = (
        '{"concept_id":"cp","kind":"symbol","value":"combatPower","source":"src/a.cpp","line":1,"confidence":"high"}\n'
        '{"concept_id":"cp","kind":"alias","value":"战力","source":"docs/design.md","line":3,"confidence":"high"}\n'
    )
    files = {"docs/design.md": "战力 = combatPower\n", "src/a.cpp": "int combatPower;\n"}
    entries = glossary_build.extract_entries(raw, reader=lambda p: files.get(p, ""))
    by_src = {e.source: e for e in entries}
    assert by_src["src/a.cpp"].confidence == "high"      # code: unchanged
    assert by_src["docs/design.md"].confidence == "med"  # doc: high→med (demoted)


def test_code_source_classification():
    assert glossary.is_code_source("src/Player.cpp")
    assert glossary.is_code_source("sql/world.SQL")
    assert not glossary.is_code_source("docs/README.md")
    assert not glossary.is_code_source("design.txt")
    assert not glossary.is_code_source("NOTES")


# --- batching: large file sets are chunked into multiple cc calls (arg-limit fix) ---
def test_build_batches_large_file_set(monkeypatch):
    # 750 files with CC_BATCH_FILES=300 → 3 cc calls; outputs concatenated, all entries returned.
    monkeypatch.setattr(glossary_build, "CC_BATCH_FILES", 300)
    calls = {"n": 0, "sizes": []}
    def fake_run(prompt, *, cwd, model, region, timeout):
        calls["n"] += 1
        # each batch's prompt lists only its files; emit one entry per call so we can count
        return f'{{"concept_id":"c{calls["n"]}","kind":"symbol","value":"sym{calls["n"]}","source":"f.cpp","line":1,"confidence":"high"}}'
    monkeypatch.setattr(glossary_build, "run_cc", fake_run)
    files = [f"f{i}.cpp" for i in range(750)]
    entries = glossary_build.build(files, project="p", cwd="/tmp", model="m", region="r")
    assert calls["n"] == 3                       # 750 / 300 → 3 batches
    assert len(entries) == 3                      # one entry per batch, concatenated
    assert {e.value for e in entries} == {"sym1", "sym2", "sym3"}


def test_build_single_batch_when_small(monkeypatch):
    monkeypatch.setattr(glossary_build, "CC_BATCH_FILES", 300)
    calls = {"n": 0}
    monkeypatch.setattr(glossary_build, "run_cc",
                        lambda *a, **k: calls.__setitem__("n", calls["n"] + 1) or "")
    glossary_build.build(["a.cpp", "b.cpp"], project="p", cwd="/tmp", model="m", region="r")
    assert calls["n"] == 1                        # under batch size → one call


def test_build_emits_per_batch_progress(monkeypatch, caplog):
    # A full scan loops dozens of batches with no slice write until the end; a per-batch
    # heartbeat is the only way to tell "working" from "hung". Assert one log line per batch,
    # carrying batch/batches so progress is computable from the log alone.
    monkeypatch.setattr(glossary_build, "CC_BATCH_FILES", 300)
    monkeypatch.setattr(glossary_build, "run_cc", lambda *a, **k: "")
    files = [f"f{i}.cpp" for i in range(750)]      # → 3 batches
    with caplog.at_level("INFO", logger="glossary-build"):
        glossary_build.build(files, project="p", cwd="/tmp", model="m", region="r")
    events = [json.loads(r.message) for r in caplog.records
              if r.name == "glossary-build" and "glossary_build_batch" in r.message]
    # Batches run concurrently now, so the log ORDER isn't deterministic; assert the SET of
    # batch numbers (one heartbeat per batch, all three present) rather than their sequence.
    assert sorted(e["batch"] for e in events) == [1, 2, 3]
    assert all(e["batches"] == 3 and e["project"] == "p" for e in events)


# --- concurrency + backoff: throttle-aware retry around each cc batch ----------
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
