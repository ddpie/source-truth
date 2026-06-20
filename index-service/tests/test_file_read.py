"""Unit tests for file_read.read_file / glob_files (EFS-removal file tools).

These back the codegraph_read_file / codegraph_glob_files MCP tools that replace
the agent's builtin Read/Glob so the agent microVM needs no filesystem mount. The
key behaviors: confine an agent-supplied path to the LOCAL repo copy, return
/mnt/repo-aligned paths, page large files, and reject escapes (incl. symlink).
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

MOUNT = "/mnt/repo"


@pytest.fixture()
def repo(tmp_path):
    """A tiny on-disk repo copy: <root>/Config/bag.json + <root>/src/A.cs."""
    root = tmp_path / "repo"
    (root / "Config").mkdir(parents=True)
    (root / "src").mkdir(parents=True)
    (root / "Config" / "bag.json").write_text('{"default_capacity": 30}\n')
    (root / "src" / "A.cs").write_text("line1\nline2\nline3\n")
    return root


# --- production mount_root="" (repo-relative) round-trip -------------------
# Production ships the bridge with --mount-root "" (bootstrap.sh), so the tools
# return and re-resolve PLAIN repo-relative paths. The bulk of the cases below
# use the legacy MOUNT="/mnt/repo" for back-compat coverage; these assert the
# actually-shipped repo-relative branch end to end.
def test_read_file_repo_relative_path_is_returned(repo):
    out = file_read.read_file("Config/bag.json", local_root=str(repo), mount_root="")
    assert out["path"] == "Config/bag.json"  # repo-relative, no /mnt/repo prefix
    assert not out["path"].startswith("/")


def test_glob_then_read_roundtrip_repo_relative(repo):
    # The real agent loop: glob/search returns a path, agent feeds it back to read.
    g = file_read.glob_files("**/*.cs", local_root=str(repo), mount_root="")
    assert g["paths"] == ["src/A.cs"]
    out = file_read.read_file(g["paths"][0], local_root=str(repo), mount_root="")
    assert out["content"].splitlines() == ["line1", "line2", "line3"]


def test_read_file_repo_relative_rejects_escape(repo):
    with pytest.raises(ValueError):
        file_read.read_file("../../etc/passwd", local_root=str(repo), mount_root="")


def test_read_file_works_when_local_root_has_symlink_component(tmp_path):
    # Regression: to_local_path realpath's the file; the returned-path alignment
    # must root on realpath(local_root) too, or a symlinked local_root makes EVERY
    # read fail with "escapes repo root". local_root here is a symlink to the repo.
    real = tmp_path / "real"
    (real / "src").mkdir(parents=True)
    (real / "src" / "A.cs").write_text("x\ny\n")
    link = tmp_path / "link"
    os.symlink(str(real), str(link))
    out = file_read.read_file("src/A.cs", local_root=str(link), mount_root="")
    assert out["content"].splitlines() == ["x", "y"]
    assert out["path"] == "src/A.cs"


# --- read_file -------------------------------------------------------------
def test_read_file_returns_content_and_mount_path(repo):
    out = file_read.read_file(f"{MOUNT}/Config/bag.json", local_root=str(repo), mount_root=MOUNT)
    assert "default_capacity" in out["content"]
    assert out["path"] == f"{MOUNT}/Config/bag.json"  # rewritten back to mount space
    assert out["truncated"] is False


def test_read_file_accepts_relative_path(repo):
    out = file_read.read_file("src/A.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["content"].splitlines() == ["line1", "line2", "line3"]


def test_read_file_paging_offset_limit(repo):
    out = file_read.read_file("src/A.cs", local_root=str(repo), mount_root=MOUNT, offset=1, limit=1)
    assert out["content"] == "line2"
    assert out["start_line"] == 1
    assert out["truncated"] is True  # more lines remain after the window


def test_read_file_nonpositive_limit_reads_all_not_zero(repo):
    # REGRESSION: limit<=0 used to collapse end→start → empty content AND
    # truncated=True, so the agent thought the file was cut off and needlessly paged.
    # A non-positive limit means "no caller cap" (like None), reading the whole file.
    for bad in (0, -1):
        out = file_read.read_file("src/A.cs", local_root=str(repo), mount_root=MOUNT, limit=bad)
        assert out["content"].splitlines() == ["line1", "line2", "line3"]
        assert out["truncated"] is False


def test_glob_normalizes_backslashes_like_read_file(repo):
    # REGRESSION: a Windows-style backslash glob pattern (Unity/.NET repos) used to
    # stay a single backslash literal → 0 hits, while read_file normalized it. Both
    # now go through _normalize_seps so the same path works in glob and read.
    g = file_read.glob_files("src\\*.cs", local_root=str(repo), mount_root="")
    assert g["paths"] == ["src/A.cs"]


def test_read_file_missing_file_raises(repo):
    with pytest.raises(ValueError):
        file_read.read_file("src/Nope.cs", local_root=str(repo), mount_root=MOUNT)


def test_read_file_escape_raises(repo):
    with pytest.raises(ValueError):
        file_read.read_file("../../etc/passwd", local_root=str(repo), mount_root=MOUNT)


def test_read_file_symlink_escape_raises(repo, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("TOPSECRET")
    os.symlink(str(outside), str(repo / "leak"))
    with pytest.raises(ValueError):
        file_read.read_file(f"{MOUNT}/leak", local_root=str(repo), mount_root=MOUNT)


def test_read_file_byte_cap(repo, monkeypatch):
    # A file over the byte ceiling is truncated, not OOM'd.
    monkeypatch.setattr(file_read, "MAX_READ_BYTES", 10)
    out = file_read.read_file("src/A.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["truncated"] is True
    assert len(out["content"]) <= 10


def test_read_to_json_is_valid_json(repo):
    s = file_read.read_to_json("src/A.cs", local_root=str(repo), mount_root=MOUNT)
    assert json.loads(s)["lines"] == 3


# --- glob_files ------------------------------------------------------------
def test_glob_files_recursive(repo):
    out = file_read.glob_files("**/*.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/src/A.cs"]


def test_glob_files_by_dir(repo):
    out = file_read.glob_files("Config/*.json", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/Config/bag.json"]


def test_glob_files_accepts_mount_prefix(repo):
    out = file_read.glob_files(f"{MOUNT}/**/*.json", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/Config/bag.json"]


def test_glob_files_excludes_vcs_and_vendored(repo):
    (repo / ".git").mkdir()
    (repo / ".git" / "config.cs").write_text("x")
    (repo / "node_modules").mkdir()
    (repo / "node_modules" / "dep.cs").write_text("x")
    out = file_read.glob_files("**/*.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/src/A.cs"]  # .git / node_modules filtered out


def test_glob_files_empty_pattern_raises(repo):
    with pytest.raises(ValueError):
        file_read.glob_files("  ", local_root=str(repo), mount_root=MOUNT)


def test_glob_files_escape_raises(repo):
    with pytest.raises(ValueError):
        file_read.glob_files("../../*", local_root=str(repo), mount_root=MOUNT)


def test_glob_files_rejects_absolute_after_mount_strip(repo):
    # Defense-in-depth: with a legacy non-empty mount_root, "/mnt/repo//etc/passwd"
    # strips to an ABSOLUTE "/etc/passwd" that would absolute-reset os.path.join.
    # The post-strip is-absolute guard must reject it (not rely solely on the
    # per-hit realpath backstop).
    with pytest.raises(ValueError):
        file_read.glob_files(f"{MOUNT}//etc/passwd", local_root=str(repo), mount_root=MOUNT)


def test_glob_files_drops_symlink_escape(repo, tmp_path):
    # A symlinked match whose target is outside the repo is dropped, not leaked.
    outside = tmp_path / "evil.cs"
    outside.write_text("x")
    os.symlink(str(outside), str(repo / "src" / "evil.cs"))
    out = file_read.glob_files("**/*.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/src/A.cs"]  # evil.cs (symlink-out) excluded


def test_read_file_decodes_gbk_chinese_faithfully(tmp_path):
    # CROSS-REVIEW HIGH regression: a GBK/GB2312 Chinese source must be read as real
    # Chinese, NOT mojibake (the prior hardcoded utf-8+replace corrupted it). decode_bytes
    # detects GB18030. Also surfaces the non-utf-8 encoding so the agent knows.
    root = tmp_path / "repo"
    (root / "src").mkdir(parents=True)
    (root / "src" / "Skill.cs").write_bytes("// 火球术 伤害=500 冷却=3秒\nclass Fireball {}".encode("gbk"))
    out = file_read.read_file("src/Skill.cs", local_root=str(root), mount_root="")
    assert "火球术" in out["content"]
    assert "伤害=500" in out["content"]
    assert "�" not in out["content"]      # no replacement chars
    assert out.get("encoding") == "gb18030"


def test_read_file_strips_utf8_bom(tmp_path):
    root = tmp_path / "repo"
    (root / "c").mkdir(parents=True)
    (root / "c" / "x.json").write_bytes("﻿{\"k\":1}".encode("utf-8"))
    out = file_read.read_file("c/x.json", local_root=str(root), mount_root="")
    assert out["content"].startswith("{")     # phantom BOM char gone from line 1


def test_read_file_line_numbers_match_newline_only_split(tmp_path):
    # read_file must count lines by \n (like ripgrep/file_search), not splitlines()'s
    # full Unicode boundary set — else offset/limit paging diverges from cited line nums.
    root = tmp_path / "repo"
    (root / "s").mkdir(parents=True)
    # A form-feed (\f) is a splitlines() boundary but NOT a \n. One logical line here.
    (root / "s" / "f.txt").write_text("alpha\fbeta\ngamma\n")
    out = file_read.read_file("s/f.txt", local_root=str(root), mount_root="")
    # 2 lines by \n-count ("alpha\fbeta", "gamma"), not 3 by splitlines().
    assert out["lines"] == 2
    assert "alpha\fbeta" in out["content"]
