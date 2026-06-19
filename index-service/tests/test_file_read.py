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


def test_glob_files_drops_symlink_escape(repo, tmp_path):
    # A symlinked match whose target is outside the repo is dropped, not leaked.
    outside = tmp_path / "evil.cs"
    outside.write_text("x")
    os.symlink(str(outside), str(repo / "src" / "evil.cs"))
    out = file_read.glob_files("**/*.cs", local_root=str(repo), mount_root=MOUNT)
    assert out["paths"] == [f"{MOUNT}/src/A.cs"]  # evil.cs (symlink-out) excluded
