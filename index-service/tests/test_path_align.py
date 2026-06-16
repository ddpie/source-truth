"""Unit tests for path_align.to_container_path (POC#1 path normalization).

CodeGraph runs on the index-service host where the repo worktree lives at some
index_root (writable mount). Session containers read the same code at a read-only
mount (/mnt/repo). Tool-returned paths must be rewritten from index_root-space
into container mount-space, and paths escaping the repo root must be refused.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import path_align  # noqa: E402

INDEX_ROOT = "/srv/worktrees/main"
MOUNT = "/mnt/repo"


def test_absolute_under_index_root_rewritten_to_mount():
    got = path_align.to_container_path(
        f"{INDEX_ROOT}/Assets/Scripts/Match3/MatchResolver.cs",
        index_root=INDEX_ROOT,
        mount_root=MOUNT,
    )
    assert got == f"{MOUNT}/Assets/Scripts/Match3/MatchResolver.cs"


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
