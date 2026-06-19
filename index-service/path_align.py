"""Path alignment between CodeGraph index space and the agent's repo namespace.

CodeGraph indexes a repo worktree that lives at ``index_root`` on the
index-service host (its LOCAL disk copy, e.g. ``/data/repo/<subdir>``). The agent
microVM mounts NO filesystem — it reads code over the index-service HTTP bridge —
so the paths it sees should be plain REPO-RELATIVE (e.g.
``index-service/path_align.py``), not tied to any host path. ``to_container_path``
strips the index_root prefix and returns the repo-relative remainder
(``mount_root`` defaults to ``""`` = repo-relative). A legacy non-empty
``mount_root`` (e.g. ``/mnt/repo``) is still supported for back-compat: the
remainder is re-rooted under it.

Real path formats from codegraph-server 0.18.5 (empirically verified — the
``file`` field mirrors the ``--workspace`` arg the server was started with):
  - workspace "."             -> "./index-service/path_align.py"   (./-prefixed)
  - workspace "/data/repo/x"  -> "/data/repo/x/index-service/path_align.py"
Both forms (plus bare relative) are normalized to a repo-relative path.
``format_location`` consumes the full ``symbol.location`` dict
(``{file, line, column, end_line, end_column}``) into a ``path:line`` reference.

Security: any path that LEXICALLY resolves outside the repo root is rejected
(``..`` escapes, sibling-prefix paths), so a stray CodeGraph path can never point
the agent at files outside the repo. NOTE this is a LEXICAL guard only — it does
not follow symlinks. ``to_local_path`` (the inverse, used by the file-read tools
on UNTRUSTED agent input) adds an ``os.path.realpath`` re-validation to close the
symlink-escape hole; ``to_container_path`` operates on codegraph's own emitted
paths and stays lexical.
"""

from __future__ import annotations

import os
import posixpath
from typing import Any

# "" = repo-relative paths (the agent has no mount). A legacy absolute root like
# "/mnt/repo" is still accepted by the functions for back-compat.
DEFAULT_MOUNT_ROOT = ""


def to_container_path(
    raw: str,
    *,
    index_root: str,
    mount_root: str = DEFAULT_MOUNT_ROOT,
) -> str:
    """Rewrite a CodeGraph-returned path into the container mount path.

    With the default ``mount_root=""`` the result is REPO-RELATIVE (the agent has
    no mount). A non-empty ``mount_root`` (legacy ``/mnt/repo``) re-roots under it.

    - Absolute paths under ``index_root`` have that prefix stripped.
    - Absolute paths already under a non-empty ``mount_root`` are idempotent.
    - Relative paths are interpreted relative to the repo root.
    - Redundant ``.`` / ``..`` / double-slash segments are normalized.

    Raises ValueError if ``raw`` is empty or resolves outside the repo root
    (absolute path not under index_root/mount_root, or relative path escaping up).
    """
    if not raw or not raw.strip():
        raise ValueError("path must be a non-empty string")

    index_root = posixpath.normpath(index_root)
    # Empty mount_root means "repo-relative" — DON'T normpath("") → "." it.
    mount_root = posixpath.normpath(mount_root) if mount_root else ""

    if posixpath.isabs(raw):
        norm = posixpath.normpath(raw)
        roots = (index_root, mount_root) if mount_root else (index_root,)
        for root in roots:
            rel = _relative_to(norm, root)
            if rel is not None:
                return _join_mount(mount_root, rel)
        raise ValueError(f"absolute path escapes repo root: {raw!r}")

    # Relative path: must not climb above the repo root.
    rel = posixpath.normpath(raw)
    if rel == ".." or rel.startswith("../"):
        raise ValueError(f"relative path escapes repo root: {raw!r}")
    return _join_mount(mount_root, rel)


def to_local_path(
    requested: str,
    *,
    local_root: str,
    mount_root: str = DEFAULT_MOUNT_ROOT,
) -> str:
    """Resolve an AGENT-supplied path back onto the LOCAL repo copy on disk.

    The inverse of :func:`to_container_path`: tools like ``read_file`` /
    ``glob_files`` receive a path the agent saw (mount-space ``/mnt/repo/...`` or
    a repo-relative path) and must turn it into a real on-disk path under
    ``local_root`` (the index-service-side copy, e.g. ``/data/repo/<subdir>``) to
    open it. This is an UNTRUSTED INPUT surface (the agent is steered by repo
    content that could embed a malicious path), so confinement is enforced in
    TWO layers:

    1. LEXICAL: strip a leading ``mount_root`` (or accept a relative / already-
       local path), reject any ``..`` climb, and join onto ``local_root`` —
       mirrors the lexical guard in :func:`to_container_path`.
    2. REALPATH: ``os.path.realpath`` the joined path and re-verify it still sits
       under ``os.path.realpath(local_root)``. This closes the symlink-escape hole
       the lexical guard alone can't see (a symlink INSIDE the repo whose target is
       outside it) — the gap called out as acceptable-for-MVP in the module
       docstring, now closed because this entry point takes attacker-influenceable
       input, unlike codegraph's own emitted paths.

    Raises ValueError if the path is empty, climbs above the repo, or resolves
    (after following symlinks) outside ``local_root``.
    """
    if not requested or not requested.strip():
        raise ValueError("path must be a non-empty string")

    local_root = posixpath.normpath(local_root)
    mount_root = posixpath.normpath(mount_root) if mount_root else ""

    if posixpath.isabs(requested):
        norm = posixpath.normpath(requested)
        # Accept an absolute path under a non-empty (legacy) mount_root, or one
        # already under local_root (idempotent) — anything else escapes.
        rel = _relative_to(norm, mount_root) if mount_root else None
        if rel is None:
            rel = _relative_to(norm, local_root)
        if rel is None:
            raise ValueError(f"absolute path escapes repo root: {requested!r}")
    else:
        rel = posixpath.normpath(requested)
        if rel == ".." or rel.startswith("../"):
            raise ValueError(f"relative path escapes repo root: {requested!r}")
        if rel == ".":
            rel = ""

    candidate = local_root if not rel else posixpath.normpath(f"{local_root}/{rel}")

    # REALPATH confinement: follow symlinks and re-check containment. A symlink
    # inside the repo pointing at /etc/passwd passes the lexical check above but
    # is caught here. realpath() doesn't require the path to exist (it resolves
    # what it can), so a not-yet-existing path is left for the caller's open().
    real_root = os.path.realpath(local_root)
    real_candidate = os.path.realpath(candidate)
    if real_candidate != real_root and not real_candidate.startswith(real_root.rstrip("/") + "/"):
        raise ValueError(f"path resolves outside repo root (symlink escape?): {requested!r}")
    return real_candidate


def format_location(
    location: dict[str, Any],
    *,
    index_root: str,
    mount_root: str = DEFAULT_MOUNT_ROOT,
) -> str:
    """Turn a CodeGraph ``symbol.location`` dict into an agent-readable reference.

    Real shape (codegraph-server 0.18.5): ``{file, line, column, end_line,
    end_column}``. Returns ``<path>:<line>`` (repo-relative by default, e.g.
    ``agent-container/agent.py:21``), or just the path when no line.

    Raises ValueError if ``file`` is absent (or via to_container_path on escape).
    """
    raw_file = location.get("file")
    if not raw_file:
        raise ValueError("location is missing required 'file' field")
    path = to_container_path(raw_file, index_root=index_root, mount_root=mount_root)
    line = location.get("line")
    return f"{path}:{line}" if line is not None else path


def _relative_to(norm_path: str, root: str) -> str | None:
    """Return path relative to root if norm_path is under root, else None."""
    if norm_path == root:
        return ""
    prefix = root.rstrip("/") + "/"
    if norm_path.startswith(prefix):
        return norm_path[len(prefix) :]
    return None


def _join_mount(mount_root: str, rel: str) -> str:
    # Empty mount_root → repo-relative: return the remainder verbatim (".", the
    # repo root, becomes "." rather than an absolute path).
    if not mount_root:
        return rel if rel else "."
    return mount_root if not rel else posixpath.normpath(f"{mount_root}/{rel}")
