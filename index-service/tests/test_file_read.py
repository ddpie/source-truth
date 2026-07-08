"""Unit tests for file_read.read_file / glob_files (EFS-removal file tools).

These back the codegraph_read_file / codegraph_glob_files MCP tools that replace
the agent's builtin Read/Glob so the agent microVM needs no filesystem mount. The
key behaviors: confine an agent-supplied path to the LOCAL repo copy, return
repo-relative paths, page large files, and reject escapes (incl. symlink).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import file_read  # noqa: E402


@pytest.fixture()
def repo(tmp_path):
    """A tiny on-disk repo copy: <root>/Config/bag.json + <root>/src/A.cs."""
    root = tmp_path / "repo"
    (root / "Config").mkdir(parents=True)
    (root / "src").mkdir(parents=True)
    (root / "Config" / "bag.json").write_text('{"default_capacity": 30}\n')
    (root / "src" / "A.cs").write_text("line1\nline2\nline3\n")
    return root


# --- repo-relative round-trip (the shipped behavior) -------------------------
def test_read_file_repo_relative_path_is_returned(repo):
    out = file_read.read_file("Config/bag.json", local_root=str(repo))
    assert out["path"] == "Config/bag.json"  # repo-relative, no absolute prefix
    assert not out["path"].startswith("/")


def test_glob_then_read_roundtrip_repo_relative(repo):
    # The real agent loop: glob/search returns a path, agent feeds it back to read.
    g = file_read.glob_files("**/*.cs", local_root=str(repo))
    assert g["paths"] == ["src/A.cs"]
    out = file_read.read_file(g["paths"][0], local_root=str(repo))
    assert out["content"].splitlines() == ["line1", "line2", "line3"]


def test_read_file_repo_relative_rejects_escape(repo):
    with pytest.raises(ValueError):
        file_read.read_file("../../etc/passwd", local_root=str(repo))


def test_read_file_works_when_local_root_has_symlink_component(tmp_path):
    # Regression: to_local_path realpath's the file; the returned-path alignment
    # must root on realpath(local_root) too, or a symlinked local_root makes EVERY
    # read fail with "escapes repo root". local_root here is a symlink to the repo.
    real = tmp_path / "real"
    (real / "src").mkdir(parents=True)
    (real / "src" / "A.cs").write_text("x\ny\n")
    link = tmp_path / "link"
    os.symlink(str(real), str(link))
    out = file_read.read_file("src/A.cs", local_root=str(link))
    assert out["content"].splitlines() == ["x", "y"]
    assert out["path"] == "src/A.cs"


# --- read_file -------------------------------------------------------------
def test_read_file_returns_content_and_path(repo):
    out = file_read.read_file("Config/bag.json", local_root=str(repo))
    assert "default_capacity" in out["content"]
    assert out["path"] == "Config/bag.json"
    assert out["truncated"] is False


def test_read_file_paging_offset_limit(repo):
    out = file_read.read_file("src/A.cs", local_root=str(repo), offset=1, limit=1)
    assert out["content"] == "line2"
    assert out["start_line"] == 1
    assert out["truncated"] is True  # more lines remain after the window


def test_read_file_nonpositive_limit_reads_all_not_zero(repo):
    # REGRESSION: limit<=0 used to collapse end→start → empty content AND
    # truncated=True, so the agent thought the file was cut off and needlessly paged.
    # A non-positive limit means "no caller cap" (like None), reading the whole file.
    for bad in (0, -1):
        out = file_read.read_file("src/A.cs", local_root=str(repo), limit=bad)
        assert out["content"].splitlines() == ["line1", "line2", "line3"]
        assert out["truncated"] is False


def test_glob_normalizes_backslashes_like_read_file(repo):
    # REGRESSION: a Windows-style backslash glob pattern (Unity/.NET repos) used to
    # stay a single backslash literal → 0 hits, while read_file normalized it. Both
    # now go through _normalize_seps so the same path works in glob and read.
    g = file_read.glob_files("src\\*.cs", local_root=str(repo))
    assert g["paths"] == ["src/A.cs"]


def test_read_file_missing_file_raises(repo):
    with pytest.raises(ValueError):
        file_read.read_file("src/Nope.cs", local_root=str(repo))


def test_read_file_symlink_escape_raises(repo, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("TOPSECRET")
    os.symlink(str(outside), str(repo / "leak"))
    with pytest.raises(ValueError):
        file_read.read_file("leak", local_root=str(repo))


def test_read_file_byte_cap(repo, monkeypatch):
    # A file over the byte ceiling is truncated, not OOM'd.
    monkeypatch.setattr(file_read, "MAX_READ_BYTES", 10)
    out = file_read.read_file("src/A.cs", local_root=str(repo))
    assert out["truncated"] is True
    assert len(out["content"]) <= 10


def test_read_to_json_is_valid_json(repo):
    s = file_read.read_to_json("src/A.cs", local_root=str(repo))
    assert json.loads(s)["lines"] == 3


def test_read_file_offset_past_256kib_is_reachable(tmp_path):
    # CORE REGRESSION: the old code read only the first MAX_READ_BYTES (256 KiB) from
    # byte 0 and THEN paged by offset, so any line whose byte position was beyond 256 KiB
    # was UNREACHABLE — read returned empty with no signal (the bug that made the agent
    # fall back to dozens of narrow searches over a data table at line ~7700 / byte ~296 KiB).
    root = tmp_path / "repo"
    (root / "sql").mkdir(parents=True)
    # ~10k lines, ~40 bytes each, so the marker line (7699) sits well past the 256 KiB mark.
    filler = ["(0,0,0,12,-8949,-132,84)" + "x" * 16] * 10000
    filler[7699] = "MARKER_RACE_CLASS_ROW"
    (root / "sql" / "big.sql").write_text("\n".join(filler) + "\n")
    # Sanity: that line really is past the OLD 256 KiB read window.
    assert len("\n".join(filler[:7699]).encode()) > 256 * 1024
    out = file_read.read_file("sql/big.sql", local_root=str(root), offset=7699, limit=1)
    assert out["content"] == "MARKER_RACE_CLASS_ROW"  # now reachable
    assert out["start_line"] == 7699


def test_read_file_truncation_gives_next_offset_and_total(repo):
    # A truncated read must hand back next_offset (where to resume) + total_lines, so a
    # cut is actionable ("call again with offset=next_offset") instead of a silent stop.
    out = file_read.read_file("src/A.cs", local_root=str(repo), offset=0, limit=2)
    assert out["truncated"] is True
    assert out["total_lines"] == 3
    assert out["next_offset"] == 2
    # Resuming at next_offset reads the remainder and is no longer truncated.
    rest = file_read.read_file("src/A.cs", local_root=str(repo), offset=out["next_offset"])
    assert rest["content"] == "line3"
    assert rest["truncated"] is False
    assert "next_offset" not in rest  # nothing left to page


def test_read_file_full_read_has_no_next_offset(repo):
    out = file_read.read_file("src/A.cs", local_root=str(repo))
    assert out["truncated"] is False
    assert out["total_lines"] == 3
    assert "next_offset" not in out


def test_read_file_offset_past_eof_returns_empty_not_error(repo):
    # An offset beyond EOF is clamped to a clean empty window anchored at EOF — never a
    # crash or negative slice, and not truncated (nothing follows).
    out = file_read.read_file("src/A.cs", local_root=str(repo), offset=999)
    assert out["content"] == ""
    assert out["lines"] == 0
    assert out["total_lines"] == 3
    assert out["truncated"] is False
    assert "next_offset" not in out


def test_read_file_output_bytecap_drops_whole_trailing_lines(tmp_path, monkeypatch):
    # The OUTPUT byte cap must drop WHOLE trailing lines (never a half-line) and report
    # next_offset so the agent can continue — distinct from the disk-read ceiling.
    monkeypatch.setattr(file_read, "MAX_READ_BYTES", 12)
    root = tmp_path / "repo"
    (root / "s").mkdir(parents=True)
    (root / "s" / "x.txt").write_text("aaaa\nbbbb\ncccc\ndddd\n")  # 4 lines, 5 bytes each w/ \n
    out = file_read.read_file("s/x.txt", local_root=str(root))
    assert out["truncated"] is True
    assert out["content"] in ("aaaa", "aaaa\nbbbb")   # whole lines only, within 12 bytes
    assert "\n".join(out["content"].splitlines())  # no dangling partial line
    assert out["next_offset"] == out["lines"]         # resume cursor = lines returned


# --- glob_files ------------------------------------------------------------
def test_glob_files_recursive(repo):
    out = file_read.glob_files("**/*.cs", local_root=str(repo))
    assert out["paths"] == ["src/A.cs"]


def test_glob_files_by_dir(repo):
    out = file_read.glob_files("Config/*.json", local_root=str(repo))
    assert out["paths"] == ["Config/bag.json"]


def test_glob_files_excludes_vcs_and_vendored(repo):
    (repo / ".git").mkdir()
    (repo / ".git" / "config.cs").write_text("x")
    (repo / "node_modules").mkdir()
    (repo / "node_modules" / "dep.cs").write_text("x")
    out = file_read.glob_files("**/*.cs", local_root=str(repo))
    assert out["paths"] == ["src/A.cs"]  # .git / node_modules filtered out


def test_glob_files_empty_pattern_raises(repo):
    with pytest.raises(ValueError):
        file_read.glob_files("  ", local_root=str(repo))


def test_glob_files_escape_raises(repo):
    with pytest.raises(ValueError):
        file_read.glob_files("../../*", local_root=str(repo))


def test_glob_files_rejects_absolute_pattern(repo):
    # An absolute pattern would absolute-reset os.path.join (Python discards the
    # root on an absolute second arg) — must be rejected by the lexical guard,
    # not just caught by the per-hit realpath backstop.
    with pytest.raises(ValueError):
        file_read.glob_files("/etc/passwd", local_root=str(repo))


def test_glob_files_drops_symlink_escape(repo, tmp_path):
    # A symlinked match whose target is outside the repo is dropped, not leaked.
    outside = tmp_path / "evil.cs"
    outside.write_text("x")
    os.symlink(str(outside), str(repo / "src" / "evil.cs"))
    out = file_read.glob_files("**/*.cs", local_root=str(repo))
    assert out["paths"] == ["src/A.cs"]  # evil.cs (symlink-out) excluded


def test_read_file_decodes_gbk_chinese_faithfully(tmp_path):
    # CROSS-REVIEW HIGH regression: a GBK/GB2312 Chinese source must be read as real
    # Chinese, NOT mojibake (the prior hardcoded utf-8+replace corrupted it). decode_bytes
    # detects GB18030. Also surfaces the non-utf-8 encoding so the agent knows.
    root = tmp_path / "repo"
    (root / "src").mkdir(parents=True)
    (root / "src" / "Skill.cs").write_bytes("// 火球术 伤害=500 冷却=3秒\nclass Fireball {}".encode("gbk"))
    out = file_read.read_file("src/Skill.cs", local_root=str(root))
    assert "火球术" in out["content"]
    assert "伤害=500" in out["content"]
    assert "�" not in out["content"]      # no replacement chars
    assert out.get("encoding") == "gb18030"


def test_read_file_strips_utf8_bom(tmp_path):
    root = tmp_path / "repo"
    (root / "c").mkdir(parents=True)
    (root / "c" / "x.json").write_bytes("﻿{\"k\":1}".encode("utf-8"))
    out = file_read.read_file("c/x.json", local_root=str(root))
    assert out["content"].startswith("{")     # phantom BOM char gone from line 1


def test_read_file_line_numbers_match_newline_only_split(tmp_path):
    # read_file must count lines by \n (like ripgrep/file_search), not splitlines()'s
    # full Unicode boundary set — else offset/limit paging diverges from cited line nums.
    root = tmp_path / "repo"
    (root / "s").mkdir(parents=True)
    # A form-feed (\f) is a splitlines() boundary but NOT a \n. One logical line here.
    (root / "s" / "f.txt").write_text("alpha\fbeta\ngamma\n")
    out = file_read.read_file("s/f.txt", local_root=str(root))
    # 2 lines by \n-count ("alpha\fbeta", "gamma"), not 3 by splitlines().
    assert out["lines"] == 2
    assert "alpha\fbeta" in out["content"]


def test_read_file_bytecap_midchar_cut_stays_utf8(tmp_path):
    # CROSS-REVIEW P1: a >256KiB valid-UTF-8 file whose byte cap slices mid-multibyte-char
    # must STILL decode as utf-8 (the partial tail trimmed), NOT flip the whole file to a
    # gb18030 mis-decode. Build content so the 256KiB boundary lands inside a 3-byte char.
    root = tmp_path / "repo"
    (root / "s").mkdir(parents=True)
    # Fill with ASCII up to 1 byte before the cap, then a 3-byte char straddling it.
    filler = "a" * (256 * 1024 - 1)
    (root / "s" / "big.cs").write_text(filler + "技" + "rest", encoding="utf-8")
    out = file_read.read_file("s/big.cs", local_root=str(root))
    assert out["truncated"] is True
    # Must be clean utf-8 (no encoding key, or utf-8), NOT gb18030 — the partial char was trimmed.
    assert out.get("encoding") in (None, "utf-8"), f"flipped to {out.get('encoding')}"
    assert "�" not in out["content"]


def test_read_file_strips_crlf_trailing_cr(tmp_path):
    # CROSS-REVIEW P2: CRLF (Windows/Unity) files must not carry a stray \r on each line.
    root = tmp_path / "repo"
    (root / "s").mkdir(parents=True)
    (root / "s" / "w.cs").write_bytes(b"line1\r\nline2\r\nline3\r\n")
    out = file_read.read_file("s/w.cs", local_root=str(root))
    assert "\r" not in out["content"]
    assert out["content"] == "line1\nline2\nline3"
    assert out["lines"] == 3


# --- multi-repo repo= round-trip (REGRESSION: scope-gate prefixes graph paths) ---
# The graph/search tools return paths as "<repo>/<rel>" (path honesty). The agent passes
# that path back verbatim, so the file tools MUST strip the leading "<repo>/" before
# resolving against this repo's local copy, and re-prefix the returned path. Without the
# repo= plumbing, read_file("code-5x/Config/bag.json", ...) resolved to
# <root>/code-5x/Config/bag.json → ENOENT (the regression this guards).
def test_read_file_strips_and_reprefixes_repo(repo):
    out = file_read.read_file("code-5x/Config/bag.json", local_root=str(repo), repo="code-5x")
    assert out["path"] == "code-5x/Config/bag.json", out["path"]  # round-trips with the agent's view
    assert '"default_capacity": 30' in out["content"]


def test_read_file_repo_unset_is_unchanged(repo):
    # repo="" (single repo / no prefix) keeps the pre-multi-repo behavior byte-for-byte.
    out = file_read.read_file("Config/bag.json", local_root=str(repo), repo="")
    assert out["path"] == "Config/bag.json"


def test_glob_strips_and_reprefixes_repo(repo):
    out = file_read.glob_files("code-5x/**/*.cs", local_root=str(repo), repo="code-5x")
    assert out["paths"] == ["code-5x/src/A.cs"], out["paths"]


def test_glob_bare_pattern_with_repo_prefixes_results(repo):
    # A pattern WITHOUT the prefix still works; results are still <repo>/-prefixed.
    out = file_read.glob_files("**/*.json", local_root=str(repo), repo="code-5x")
    assert out["paths"] == ["code-5x/Config/bag.json"], out["paths"]


def test_repo_prefixed_path_cannot_escape_via_traversal(repo):
    # The repo strip must not become an escape lever: "<repo>/../../etc/passwd" still blocked.
    with pytest.raises(ValueError):
        file_read.read_file("code-5x/../../etc/passwd", local_root=str(repo), repo="code-5x")
