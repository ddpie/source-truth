"""Path alignment between CodeGraph index space and the agent's repo namespace.

CodeGraph indexes a repo worktree that lives at ``index_root`` on the
index-service host (its LOCAL disk copy, e.g. ``/data/repo/<subdir>``). The agent
microVM mounts NO filesystem — it reads code over the index-service HTTP bridge —
so the paths it sees are plain REPO-RELATIVE (e.g.
``index-service/path_align.py``), not tied to any host path. ``to_container_path``
strips the index_root prefix and returns the repo-relative remainder.

Real path formats from codegraph-server 0.18.5 (empirically verified — the
``file`` field mirrors the ``--workspace`` arg the server was started with):
  - workspace "."             -> "./index-service/path_align.py"   (./-prefixed)
  - workspace "/data/repo/x"  -> "/data/repo/x/index-service/path_align.py"
Both forms (plus bare relative) are normalized to a repo-relative path.

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


def _normalize_seps(p: str) -> str:
    """Normalize path separators BEFORE posixpath handling. Two fixes:
      - Backslashes → '/': posixpath.normpath does NOT treat '\\' as a separator,
        so a Windows-style path (some Unity/.NET tooling in a game repo, or a
        codegraph frontend) would otherwise pass through as a single backslash-laden
        filename → wrong citation + a read that can't find the file. Game repos are
        exactly the domain here, so guard it.
      - Collapse a leading '//' to '/': posixpath preserves a leading double slash
        (POSIX implementation-defined), which would make an absolute '//data/repo/…'
        never match the single-slash index_root prefix → a valid hit turns into a
        hard 'escapes repo root' error.
    Interior double slashes are left for posixpath.normpath to collapse."""
    p = p.replace("\\", "/")
    while p.startswith("//"):
        p = p[1:]
    return p


def to_container_path(
    raw: str,
    *,
    index_root: str,
    repo: str = "",
) -> str:
    """Rewrite a CodeGraph-returned path into the agent's REPO-RELATIVE namespace.

    - Absolute paths under ``index_root`` have that prefix stripped.
    - Relative paths are interpreted relative to the repo root.
    - Redundant ``.`` / ``..`` / double-slash segments are normalized.

    ``repo`` (multi-repo): when set, the repo-relative result is PREFIXED with
    ``<repo>/`` so the agent sees ``<repo>/<repo-relative-path>`` and can tell which
    repo a citation came from (design §4.4 "path honesty"). Default ``""`` = single
    repo = no prefix.

    Raises ValueError if ``raw`` is empty or resolves outside the repo root
    (absolute path not under index_root, or relative path escaping up).
    """
    if not raw or not raw.strip():
        raise ValueError("path must be a non-empty string")
    raw = _normalize_seps(raw)

    index_root = posixpath.normpath(index_root)

    if posixpath.isabs(raw):
        norm = posixpath.normpath(raw)
        rel = _relative_to(norm, index_root)
        if rel is None:
            raise ValueError(f"absolute path escapes repo root: {raw!r}")
    else:
        # Relative path: must not climb above the repo root.
        rel = posixpath.normpath(raw)
        if rel == ".." or rel.startswith("../"):
            raise ValueError(f"relative path escapes repo root: {raw!r}")
    # "" / "." = the repo root itself.
    path = rel if rel and rel != "." else "."
    return _with_repo(repo, path)


def to_local_path(
    requested: str,
    *,
    local_root: str,
    repo: str = "",
) -> str:
    """Resolve an AGENT-supplied path back onto the LOCAL repo copy on disk.

    The inverse of :func:`to_container_path`: tools like ``read_file`` /
    ``glob_files`` receive a repo-relative path the agent saw and must turn it
    into a real on-disk path under ``local_root`` (the index-service-side copy,
    e.g. ``/data/repo/<subdir>``) to open it. This is an UNTRUSTED INPUT surface
    (the agent is steered by repo content that could embed a malicious path), so
    confinement is enforced in TWO layers:

    1. LEXICAL: accept a relative / already-local path, reject any ``..`` climb,
       and join onto ``local_root`` — mirrors the lexical guard in
       :func:`to_container_path`.
    2. REALPATH: ``os.path.realpath`` the joined path and re-verify it still sits
       under ``os.path.realpath(local_root)``. This closes the symlink-escape hole
       the lexical guard alone can't see (a symlink INSIDE the repo whose target is
       outside it) — necessary because this entry point takes attacker-influenceable
       input, unlike codegraph's own emitted paths.

    Raises ValueError if the path is empty, climbs above the repo, or resolves
    (after following symlinks) outside ``local_root``.
    """
    if not requested or not requested.strip():
        raise ValueError("path must be a non-empty string")
    requested = _normalize_seps(requested)

    # Multi-repo inverse of to_container_path's prefix: the agent saw a path the tool
    # emitted as "<repo>/<rel>", so strip a leading "<repo>/" (ONLY a relative path)
    # before resolving onto local_root. repo="" (single repo) → no-op. The repo name is
    # already charset-validated upstream (manifest ^[a-z0-9][a-z0-9-]*$), but we only
    # STRIP it here, never use it to build a path, so this can't widen the attack surface.
    if repo and not posixpath.isabs(requested):
        prefix = repo.rstrip("/") + "/"
        if requested == repo:
            requested = ""
        elif requested.startswith(prefix):
            requested = requested[len(prefix):]

    local_root = posixpath.normpath(local_root)

    if posixpath.isabs(requested):
        norm = posixpath.normpath(requested)
        # Accept an absolute path already under local_root (idempotent) — anything
        # else escapes.
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


def _relative_to(norm_path: str, root: str) -> str | None:
    """Return path relative to root if norm_path is under root, else None."""
    if norm_path == root:
        return ""
    prefix = root.rstrip("/") + "/"
    if norm_path.startswith(prefix):
        return norm_path[len(prefix) :]
    return None


def _with_repo(repo: str, path: str) -> str:
    """Prefix a repo-relative path with ``<repo>/`` (multi-repo path honesty, design §4.4).
    No-op when repo is empty (single-repo). The repo root "." becomes just "<repo>"
    (not "<repo>/.")."""
    if not repo:
        return path
    return repo if path == "." else f"{repo}/{path}"
