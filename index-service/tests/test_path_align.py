"""Unit tests for path_align (POC#1 path normalization).

CodeGraph (codegraph-server 0.18.5) returns symbol.location.file paths whose
format mirrors the --workspace argument it was started with:
  - workspace "."         -> "./agent-container/tests/test_agent_lib.py"  (./-prefixed)
  - workspace "/abs/root" -> "/abs/root/agent-container/tests/test_agent_lib.py"
(verified empirically.)

In production index-service starts the server with a fixed absolute workspace =
the local repo copy (index_root). path_align strips that prefix into plain
REPO-RELATIVE paths (the agent mounts no filesystem), handling both the
./-relative and absolute forms, and refusing paths that escape the repo root.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import path_align  # noqa: E402

INDEX_ROOT = "/data/repo/code-5x"  # index-service-side local repo copy


# --- Repo-relative output (the agent has no mount) ---------------------------
def test_default_is_repo_relative():
    got = path_align.to_container_path("a/b.cs", index_root=INDEX_ROOT)
    assert got == "a/b.cs"


def test_repo_relative_strips_absolute_index_root():
    got = path_align.to_container_path(f"{INDEX_ROOT}/index-service/path_align.py", index_root=INDEX_ROOT)
    assert got == "index-service/path_align.py"


def test_backslash_path_normalized_to_forward_slash():
    # A Windows-style path (some Unity/.NET tooling) must not pass through as a single
    # backslash-laden filename → wrong citation + unreadable. Normalized to '/'.
    assert path_align.to_container_path(r"Assets\Scripts\Foo.cs", index_root=INDEX_ROOT) == "Assets/Scripts/Foo.cs"
    assert path_align.to_container_path(f"{INDEX_ROOT}\\Assets\\Foo.cs", index_root=INDEX_ROOT) == "Assets/Foo.cs"
    # And a backslash '..' climb is still rejected (normalized first, then guarded).
    with pytest.raises(ValueError):
        path_align.to_container_path(r"..\..\etc\passwd", index_root=INDEX_ROOT)


def test_leading_double_slash_absolute_is_handled():
    # POSIX preserves a leading '//'; collapse it so an absolute '//data/...' still
    # matches the single-slash index_root prefix instead of erroring as an escape.
    got = path_align.to_container_path(f"/{INDEX_ROOT}/Assets/Foo.cs", index_root=INDEX_ROOT)
    assert got == "Assets/Foo.cs"


def test_repo_relative_dot_slash_form():
    got = path_align.to_container_path("./Assets/Foo.cs", index_root=INDEX_ROOT)
    assert got == "Assets/Foo.cs"


def test_repo_relative_bare_dot_returns_dot():
    assert path_align.to_container_path(".", index_root=INDEX_ROOT) == "."


def test_normalizes_redundant_segments():
    got = path_align.to_container_path(f"{INDEX_ROOT}/./Assets//x/../y.cs", index_root=INDEX_ROOT)
    assert got == "Assets/y.cs"


def test_repo_relative_rejects_escape():
    with pytest.raises(ValueError):
        path_align.to_container_path("/etc/passwd", index_root=INDEX_ROOT)
    with pytest.raises(ValueError):
        path_align.to_container_path("../../etc/passwd", index_root=INDEX_ROOT)


def test_empty_path_rejected():
    with pytest.raises(ValueError):
        path_align.to_container_path("", index_root=INDEX_ROOT)


# --- to_local_path: inverse mapping (agent-space path -> local on-disk path) -
# Backs read_file/glob_files. Untrusted input surface, so it must confine to
# local_root via BOTH a lexical guard AND a realpath symlink check.
def test_to_local_accepts_relative(tmp_path):
    root = tmp_path / "repo"
    (root / "a").mkdir(parents=True)
    (root / "a" / "b.json").write_text("{}")
    got = path_align.to_local_path("a/b.json", local_root=str(root))
    assert got == os.path.realpath(str(root / "a" / "b.json"))


def test_to_local_bare_dot_returns_root(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    got = path_align.to_local_path(".", local_root=str(root))
    assert got == os.path.realpath(str(root))


def test_to_local_already_local_is_idempotent(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    (root / "x.cs").write_bytes(b"y")
    p = os.path.realpath(str(root / "x.cs"))
    assert path_align.to_local_path(p, local_root=str(root)) == p


def test_to_local_rejects_relative_escape(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    with pytest.raises(ValueError):
        path_align.to_local_path("../../etc/passwd", local_root=str(root))


def test_to_local_rejects_absolute_outside(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    with pytest.raises(ValueError):
        path_align.to_local_path("/etc/passwd", local_root=str(root))


def test_to_local_empty_rejected(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    with pytest.raises(ValueError):
        path_align.to_local_path("", local_root=str(root))


def test_to_local_rejects_sibling_prefix_dir(tmp_path):
    # SECURITY: the boundary check must be anchored with a trailing slash, so a
    # SIBLING dir sharing the root's name prefix (/x/repo vs /x/repo-evil) can NOT be
    # reached. A bare startswith(real_root) would wrongly allow it. The escape would
    # need a path that realpath-resolves into repo-evil; the simplest proof is that
    # the root prefix itself is slash-anchored — verified via a relative climb into
    # the sibling, which must raise.
    root = tmp_path / "repo"
    root.mkdir()
    (tmp_path / "repo-evil").mkdir()
    (tmp_path / "repo-evil" / "secret.txt").write_text("x")
    with pytest.raises(ValueError):
        path_align.to_local_path("../repo-evil/secret.txt", local_root=str(root))


def test_to_local_rejects_symlink_escape(tmp_path):
    # A symlink INSIDE the repo whose target is OUTSIDE it passes the lexical
    # guard but MUST be caught by the realpath re-check (R3 in the design memory).
    root = tmp_path / "repo"
    root.mkdir()
    outside = tmp_path / "secret.txt"
    outside.write_text("TOPSECRET")
    link = root / "escape"
    os.symlink(str(outside), str(link))
    with pytest.raises(ValueError):
        path_align.to_local_path("escape", local_root=str(root))


def test_to_local_allows_symlink_within_repo(tmp_path):
    # A symlink that stays INSIDE the repo is fine — only escapes are rejected.
    root = tmp_path / "repo"
    (root / "real").mkdir(parents=True)
    target = root / "real" / "data.json"
    target.write_text("{}")
    link = root / "alias.json"
    os.symlink(str(target), str(link))
    got = path_align.to_local_path("alias.json", local_root=str(root))
    assert got == os.path.realpath(str(target))


# --- multi-repo `repo` prefix (design §4.4 path honesty): <repo>/<rel> ----------
def test_repo_prefix_forward_on_repo_relative():
    # to_container_path with repo= prefixes the agent-visible path with <repo>/.
    got = path_align.to_container_path("Assets/Foo.cs", index_root=INDEX_ROOT, repo="client")
    assert got == "client/Assets/Foo.cs"
    # absolute index path → stripped then prefixed
    got2 = path_align.to_container_path(f"{INDEX_ROOT}/a/b.cs", index_root=INDEX_ROOT, repo="backend-svc")
    assert got2 == "backend-svc/a/b.cs"


def test_repo_prefix_default_empty_is_unchanged():
    # repo="" (single-repo default) must be byte-identical to no repo arg → no regression.
    assert path_align.to_container_path("a/b.cs", index_root=INDEX_ROOT, repo="") == \
        path_align.to_container_path("a/b.cs", index_root=INDEX_ROOT)


def test_repo_prefix_repo_root_is_bare_repo():
    # the repo root "." becomes just "<repo>", not "<repo>/."
    assert path_align.to_container_path(".", index_root=INDEX_ROOT, repo="client") == "client"


def test_to_local_strips_repo_prefix(tmp_path):
    # inverse: the agent sends "<repo>/<rel>" (what it saw); to_local_path strips the
    # leading "<repo>/" before resolving onto the local on-disk copy.
    root = tmp_path / "repo"
    (root / "a").mkdir(parents=True)
    (root / "a" / "b.json").write_text("{}")
    got = path_align.to_local_path("client/a/b.json", local_root=str(root), repo="client")
    assert got == os.path.realpath(str(root / "a" / "b.json"))


def test_to_local_repo_round_trip():
    # to_container_path(repo) then to_local_path(repo) is a faithful round-trip (the rel part).
    agent_path = path_align.to_container_path("Assets/Foo.cs", index_root=INDEX_ROOT, repo="client")
    assert agent_path == "client/Assets/Foo.cs"
    # stripping the same repo recovers the repo-relative path (resolved against a local root)
    # use a non-existent root: realpath still resolves lexically, confinement holds.
    got = path_align.to_local_path(agent_path, local_root="/data/repo/client", repo="client")
    assert got == "/data/repo/client/Assets/Foo.cs"


def test_to_local_repo_prefix_default_empty_unchanged(tmp_path):
    root = tmp_path / "repo"
    (root / "a").mkdir(parents=True)
    (root / "a" / "b.json").write_text("{}")
    assert path_align.to_local_path("a/b.json", local_root=str(root), repo="") == \
        path_align.to_local_path("a/b.json", local_root=str(root))


def test_to_local_repo_prefix_does_not_enable_escape(tmp_path):
    # stripping "<repo>/" must NOT let a ../ escape through — the existing guards still apply
    # after the strip.
    root = tmp_path / "repo"
    root.mkdir()
    with pytest.raises(ValueError):
        path_align.to_local_path("client/../../etc/passwd", local_root=str(root), repo="client")
