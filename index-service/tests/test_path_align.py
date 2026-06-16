"""Unit tests for path_align.to_container_path (POC#1 path normalization).

CodeGraph (codegraph-server 0.18.5) returns symbol.location.file paths whose
format mirrors the --workspace argument it was started with:
  - workspace "."         -> "./agent-container/tests/test_agent_lib.py"  (./-prefixed)
  - workspace "/abs/root" -> "/abs/root/agent-container/tests/test_agent_lib.py"
(verified empirically — see test_real_codegraph_paths below.)

In production index-service starts the server with a fixed absolute workspace =
the EFS worktree path (index_root). path_align rewrites that prefix into the
session container's read-only mount (/mnt/repo), handling both the ./-relative
and absolute forms, and refusing paths that escape the repo root.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import path_align  # noqa: E402

INDEX_ROOT = "/mnt/efs/repo"  # EFS worktree path (index-service writable mount)
MOUNT = "/mnt/repo"


# --- Real codegraph-server output formats (empirically verified) ------------
def test_dot_slash_relative_path_rewritten_to_mount():
    # codegraph-server started with --workspace "." returns this exact form.
    got = path_align.to_container_path(
        "./agent-container/tests/test_agent_lib.py",
        index_root=INDEX_ROOT,
        mount_root=MOUNT,
    )
    assert got == f"{MOUNT}/agent-container/tests/test_agent_lib.py"


def test_bare_dot_returns_mount_root():
    assert path_align.to_container_path(".", index_root=INDEX_ROOT, mount_root=MOUNT) == MOUNT


def test_absolute_under_workspace_rewritten_to_mount():
    # codegraph-server started with --workspace "/mnt/efs/repo" returns this form.
    got = path_align.to_container_path(
        f"{INDEX_ROOT}/index-service/path_align.py",
        index_root=INDEX_ROOT,
        mount_root=MOUNT,
    )
    assert got == f"{MOUNT}/index-service/path_align.py"


def test_relative_path_prepended_with_mount():
    got = path_align.to_container_path(
        "Assets/Scripts/Foo.cs", index_root=INDEX_ROOT, mount_root=MOUNT
    )
    assert got == f"{MOUNT}/Assets/Scripts/Foo.cs"


def test_already_under_mount_is_idempotent():
    p = f"{MOUNT}/Assets/Bar.cs"
    assert path_align.to_container_path(p, index_root=INDEX_ROOT, mount_root=MOUNT) == p


def test_default_mount_root_is_mnt_repo():
    got = path_align.to_container_path("a/b.cs", index_root=INDEX_ROOT)
    assert got == "/mnt/repo/a/b.cs"


def test_normalizes_redundant_segments():
    got = path_align.to_container_path(
        f"{INDEX_ROOT}/./Assets//x/../y.cs", index_root=INDEX_ROOT, mount_root=MOUNT
    )
    assert got == f"{MOUNT}/Assets/y.cs"


def test_absolute_outside_index_root_rejected():
    with pytest.raises(ValueError):
        path_align.to_container_path(
            "/etc/passwd", index_root=INDEX_ROOT, mount_root=MOUNT
        )


def test_relative_escaping_root_rejected():
    with pytest.raises(ValueError):
        path_align.to_container_path(
            "../../etc/passwd", index_root=INDEX_ROOT, mount_root=MOUNT
        )


def test_empty_path_rejected():
    with pytest.raises(ValueError):
        path_align.to_container_path("", index_root=INDEX_ROOT, mount_root=MOUNT)


# --- format_location: real CodeGraph location dict -> agent-readable reference
def test_format_location_real_codegraph_shape():
    # Exact shape returned by codegraph-server 0.18.5 (empirically verified).
    location = {
        "column": 0,
        "end_column": 10000,
        "end_line": 40,
        "file": "./index-service/tests/test_path_align.py",
        "line": 33,
    }
    ref = path_align.format_location(location, index_root=INDEX_ROOT, mount_root=MOUNT)
    assert ref == f"{MOUNT}/index-service/tests/test_path_align.py:33"


def test_format_location_absolute_workspace_form():
    location = {"file": f"{INDEX_ROOT}/agent-container/agent.py", "line": 21}
    ref = path_align.format_location(location, index_root=INDEX_ROOT, mount_root=MOUNT)
    assert ref == f"{MOUNT}/agent-container/agent.py:21"


def test_format_location_missing_line_omits_suffix():
    location = {"file": "./a/b.py"}
    ref = path_align.format_location(location, index_root=INDEX_ROOT, mount_root=MOUNT)
    assert ref == f"{MOUNT}/a/b.py"


def test_format_location_rejects_missing_file():
    with pytest.raises((KeyError, ValueError)):
        path_align.format_location({"line": 5}, index_root=INDEX_ROOT, mount_root=MOUNT)
