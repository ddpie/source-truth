"""Tests for glossary_gen CLI orchestration (full / incremental / no-op / failure).

Uses a real git repo in tmp + a fake cc runner (monkeypatched glossary_build.run_cc),
so it exercises the diff + merge + atomic-write wiring without shelling out to claude.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import glossary  # noqa: E402
import glossary_build  # noqa: E402
import glossary_gen  # noqa: E402


def _git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   capture_output=True, text=True)


@pytest.fixture()
def repo(tmp_path):
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q")
    _git(r, "config", "user.email", "t@t")
    _git(r, "config", "user.name", "t")
    (r / "a.cpp").write_text("int combatPower;\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-qm", "c1")
    return r


def _sha(repo, ref="HEAD"):
    return subprocess.run(["git", "-C", str(repo), "rev-parse", ref],
                          capture_output=True, text=True, check=True).stdout.strip()


def _fake_cc(jsonl):
    """Return a runner that ignores the prompt and emits the given JSONL (+ prose noise)."""
    def runner(prompt, *, cwd, model, region, timeout):
        return "Here is the glossary:\n```\n" + jsonl + "\n```\n"
    return runner


def test_full_build_writes_index(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    monkeypatch.setattr(glossary_build, "run_cc", _fake_cc(
        '{"concept_id":"combat_power","kind":"symbol","value":"combatPower","source":"a.cpp","line":1,"confidence":"high"}'
    ))
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r", "--full"])
    assert rc == 0
    entries = glossary.read_entries(str(out))
    assert [e.value for e in entries] == ["combatPower"]


def test_empty_diff_is_noop_no_cc(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    sha = _sha(repo)
    called = {"n": 0}

    def runner(*a, **k):
        called["n"] += 1
        return ""
    monkeypatch.setattr(glossary_build, "run_cc", runner)
    # old == new => no changed files => must NOT call cc, must exit 0.
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--old", sha, "--new", sha])
    assert rc == 0
    assert called["n"] == 0
    assert not out.exists()  # nothing written on a no-op


def test_incremental_merges_changed_keeps_unchanged(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    out.parent.mkdir(parents=True)
    # Seed an existing index: combat_power contributed by a.cpp AND b.cpp.
    glossary.write_entries(str(out), [
        glossary.Entry("combat_power", "symbol", "combatPower", "a.cpp", 1, "high"),
        glossary.Entry("combat_power", "symbol", "oldFromB", "b.cpp", 1, "high"),
    ])
    old = _sha(repo)
    # Change b.cpp only.
    (repo / "b.cpp").write_text("int newFromB;\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "c2")
    new = _sha(repo)
    monkeypatch.setattr(glossary_build, "run_cc", _fake_cc(
        '{"concept_id":"combat_power","kind":"symbol","value":"newFromB","source":"b.cpp","line":1,"confidence":"high"}'
    ))
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--old", old, "--new", new])
    assert rc == 0
    concepts = glossary.aggregate(glossary.read_entries(str(out)))
    # a.cpp's symbol survived (unchanged file); b.cpp's old symbol replaced by the new one.
    assert set(concepts["combat_power"].symbols) == {"combatPower", "newFromB"}


def test_cc_failure_skips_keeps_existing(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    out.parent.mkdir(parents=True)
    glossary.write_entries(str(out), [
        glossary.Entry("c", "symbol", "keepMe", "a.cpp", 1, "high")])

    def boom(*a, **k):
        raise subprocess.TimeoutExpired(cmd="claude", timeout=1)
    monkeypatch.setattr(glossary_build, "run_cc", boom)
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r", "--full"])
    assert rc == 0  # non-strict: skip, don't fail
    # existing index untouched (not blanked)
    assert [e.value for e in glossary.read_entries(str(out))] == ["keepMe"]


def test_cc_failure_strict_is_fatal(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"

    def boom(*a, **k):
        raise OSError("claude not found")
    monkeypatch.setattr(glossary_build, "run_cc", boom)
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--full", "--strict"])
    assert rc == 2


def test_bad_repo_root_exits_2(tmp_path):
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(tmp_path / "nope"),
                            "--out", str(tmp_path / "o.jsonl"), "--model", "m", "--region", "r", "--full"])
    assert rc == 2


# --- R2 gaps: candidate_files / _is_term_file / docs-only no-op / incremental cap ---
def test_candidate_files_includes_docs_excludes_binary_and_vendored(tmp_path):
    r = tmp_path / "repo"
    (r / "src").mkdir(parents=True)
    (r / "node_modules").mkdir()
    (r / "docs").mkdir()
    (r / "src" / "a.cpp").write_text("x")
    (r / "src" / "World.SQL").write_text("x")     # uppercase code ext included
    (r / "docs" / "README.md").write_text("x")    # DOCS now INCLUDED (term source)
    (r / "docs" / "design.txt").write_text("x")   # plain text included
    (r / "Makefile").write_text("x")              # no ext → text → included
    (r / "logo.png").write_text("x")              # binary → excluded
    (r / "data.sqlite").write_text("x")           # binary db → excluded
    (r / "node_modules" / "dep.cpp").write_text("x")  # vendored → excluded
    cands = set(glossary_gen.candidate_files(str(r)))
    assert cands == {"src/a.cpp", "src/World.SQL", "docs/README.md", "docs/design.txt", "Makefile"}


def test_is_term_file_includes_docs_excludes_binary():
    # ALL text scanned (no extension allowlist); only known binary/asset extensions excluded.
    for f in ("a.cpp", "World.SQL", "conf.YAML", "README.md", "design.txt", "NOTES", "spec.rst"):
        assert glossary_gen._is_term_file(f), f
    for f in ("logo.png", "blob.bin", "data.sqlite", "icon.ico", "lib.so", "a.dbc"):
        assert not glossary_gen._is_term_file(f), f


def test_docs_only_commit_now_triggers_build(repo, tmp_path, monkeypatch):
    # Docs are now a term source, so a docs-only commit SHOULD run cc (over the changed .md).
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    old = _sha(repo)
    (repo / "README.md").write_text("# 战力 combatPower 说明\n")  # doc with a CN term
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "docs")
    new = _sha(repo)
    seen = {}
    monkeypatch.setattr(glossary_build, "build", lambda files, **k: seen.__setitem__("files", files) or [])
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--old", old, "--new", new])
    assert rc == 0
    assert "README.md" in seen.get("files", [])   # the doc was handed to cc


def test_binary_only_commit_is_noop_no_cc(repo, tmp_path, monkeypatch):
    # A commit touching only a binary asset (png) → no term file → no cc call.
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    old = _sha(repo)
    (repo / "logo.png").write_text("binary-ish")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "asset")
    new = _sha(repo)
    called = {"n": 0}
    monkeypatch.setattr(glossary_build, "run_cc", lambda *a, **k: called.__setitem__("n", called["n"] + 1) or "")
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--old", old, "--new", new])
    assert rc == 0
    assert called["n"] == 0
    assert not out.exists()


def test_full_build_uses_candidate_files_not_whole_repo(repo, tmp_path, monkeypatch):
    # A --full build must hand cc a BOUNDED candidate file list (not None/whole-repo).
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    (repo / "extra.cpp").write_text("int foo;\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "c")
    seen = {}
    def cap(files, **k):
        seen["files"] = files
        return []
    monkeypatch.setattr(glossary_build, "build", cap)
    glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                       "--out", str(out), "--model", "m", "--region", "r", "--full"])
    assert seen["files"] is not None                       # bounded list, not whole-repo None
    assert "a.cpp" in seen["files"] and "extra.cpp" in seen["files"]


def test_incremental_build_set_capped(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    monkeypatch.setattr(glossary_gen, "MAX_BUILD_FILES", 2)
    old = _sha(repo)
    for i in range(5):
        (repo / f"f{i}.cpp").write_text(f"int v{i};\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "many")
    new = _sha(repo)
    seen = {}
    monkeypatch.setattr(glossary_build, "build", lambda files, **k: seen.__setitem__("n", len(files)) or [])
    glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                       "--out", str(out), "--model", "m", "--region", "r",
                       "--old", old, "--new", new])
    assert seen["n"] == 2            # capped at MAX_BUILD_FILES


# --- R3 gaps: rename(R) diff handling; full-scan cap ---
def test_changed_files_rename_splits_old_and_new(repo):
    old = _sha(repo)
    _git(repo, "mv", "a.cpp", "renamed.cpp")
    _git(repo, "commit", "-qm", "rename")
    new = _sha(repo)
    changed, deleted = glossary_gen.changed_files(str(repo), old, new)
    assert "renamed.cpp" in changed   # new name (re)built
    assert "a.cpp" in deleted          # old name dropped


def test_full_scan_capped_at_max_build_files(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    monkeypatch.setattr(glossary_gen, "MAX_BUILD_FILES", 2)
    for i in range(5):
        (repo / f"g{i}.cpp").write_text(f"int v{i};\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "many")
    seen = {}
    monkeypatch.setattr(glossary_build, "build", lambda files, **k: seen.__setitem__("n", len(files)) or [])
    glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                       "--out", str(out), "--model", "m", "--region", "r", "--full"])
    assert seen["n"] == 2   # full-scan candidate set capped


# --- R5 resilience: empty rebuild on incremental → SKIP (preserve slice); write failure → SKIP ---
def test_incremental_empty_rebuild_preserves_slice(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    out.parent.mkdir(parents=True)
    glossary.write_entries(str(out), [glossary.Entry("c", "symbol", "keepMe", "a.cpp", 1, "high")])
    old = _sha(repo)
    (repo / "a.cpp").write_text("int changed;\n")   # a.cpp is a term file → in build set
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "c")
    new = _sha(repo)
    # cc returns nothing (throttle/garbage, exit 0) → rebuilt empty → must SKIP, not shrink.
    monkeypatch.setattr(glossary_build, "build", lambda files, **k: [])
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r",
                            "--old", old, "--new", new])
    assert rc == 0
    assert [e.value for e in glossary.read_entries(str(out))] == ["keepMe"]  # slice preserved


def test_write_failure_preserves_old_slice(repo, tmp_path, monkeypatch):
    out = tmp_path / "gloss" / "mangos" / "entries.jsonl"
    out.parent.mkdir(parents=True)
    glossary.write_entries(str(out), [glossary.Entry("c", "symbol", "keepMe", "a.cpp", 1, "high")])
    monkeypatch.setattr(glossary_build, "build",
                        lambda files, **k: [glossary.Entry("c", "symbol", "newSym", "a.cpp", 1, "high")])
    def boom(path, entries):
        raise OSError("disk full")
    monkeypatch.setattr(glossary_gen, "_write_atomic", boom)
    rc = glossary_gen.main(["--project", "mangos", "--repo-root", str(repo),
                            "--out", str(out), "--model", "m", "--region", "r", "--full"])
    assert rc == 0   # clean SKIP, not a traceback
    assert [e.value for e in glossary.read_entries(str(out))] == ["keepMe"]  # old slice intact
