"""Read a single file / list files over the LOCAL-disk repo copy.

Why this exists: the agent microVM used to read source via builtin Read/Glob on
the EFS mount (/mnt/repo). To remove EFS entirely, the agent now reads code over
HTTP through index-service, which already keeps a LOCAL copy of the repo
(/data/repo/<subdir>, the same copy file_search.py greps). These two functions
back the ``read_file`` and ``glob_files`` MCP tools — they take an agent-supplied
path (repo-relative, or a legacy /mnt/repo prefix), confine it to the local copy
via ``path_align.to_local_path`` (lexical + realpath symlink-escape guard), and
return content / matches with paths in the agent's namespace (repo-relative by
default) so results are indistinguishable from the old builtin tools.

Pure-ish: all disk access is confined under ``local_root``; nothing writes.
"""

from __future__ import annotations

import glob as _glob
import json
import logging
import os
from time import perf_counter
from typing import Any

import path_align
from perf import perf_entry

logger = logging.getLogger("file-read")

# Caps so one read can't return megabytes (would blow the agent's context / the
# card) or run unbounded. A source file far over this is almost certainly a
# generated/minified blob the agent shouldn't be slurping whole anyway.
MAX_READ_BYTES = 256 * 1024          # 256 KiB hard ceiling on a single read
MAX_READ_LINES = 4000                # …and a line ceiling (whichever hits first)
MAX_GLOB_RESULTS = 1000              # cap glob fan-out


def read_file(
    requested: str,
    *,
    local_root: str,
    mount_root: str,
    offset: int = 0,
    limit: int | None = None,
) -> dict[str, Any]:
    """Read a single file from the LOCAL repo copy.

    ``requested`` is an agent-space path (repo-relative, or a legacy ``/mnt/repo/...``
    prefix); it is confined to ``local_root`` before opening. Returns
    {"path", "content", "lines", "truncated"} with ``path`` in the agent's namespace
    (repo-relative by default).
    ``offset`` (0-based line) + ``limit`` page large files. Raises ValueError on
    a bad/escaping path or a path that isn't a regular file (so the bridge can
    report a clean error rather than leak a stack trace)."""
    t0 = perf_counter()
    local_path = path_align.to_local_path(requested, local_root=local_root, mount_root=mount_root)
    if not os.path.isfile(local_path):
        raise ValueError(f"not a readable file: {requested!r}")

    # Read defensively: cap bytes first (so a giant minified file can't OOM the
    # service), then split into lines and page. errors="replace" keeps a stray
    # non-UTF8 byte from crashing the read of an otherwise-text source file.
    raw = b""
    with open(local_path, "rb") as fh:
        raw = fh.read(MAX_READ_BYTES + 1)
    byte_truncated = len(raw) > MAX_READ_BYTES
    if byte_truncated:
        raw = raw[:MAX_READ_BYTES]
    text = raw.decode("utf-8", errors="replace")

    all_lines = text.splitlines()
    start = max(0, offset)
    end = len(all_lines) if limit is None else min(len(all_lines), start + max(0, limit))
    # Independent line ceiling on top of any caller limit.
    end = min(end, start + MAX_READ_LINES)
    sliced = all_lines[start:end]
    line_truncated = end < len(all_lines)

    # Align the RETURNED path against the realpath'd root: to_local_path already
    # realpath'd local_path (symlinks followed), so re-rooting it against a raw
    # local_root that itself contains a symlink component would fail the lexical
    # prefix match and raise "escapes repo root" on every read. Mirror glob_files,
    # which roots on os.path.realpath(local_root).
    mount_path = path_align.to_container_path(
        local_path, index_root=os.path.realpath(local_root), mount_root=mount_root)
    elapsed_ms = (perf_counter() - t0) * 1000
    logger.info(perf_entry("file_read", elapsed_ms, path=mount_path[:120],
                           lines=len(sliced), truncated=byte_truncated or line_truncated))
    return {
        "path": mount_path,
        "content": "\n".join(sliced),
        "lines": len(sliced),
        "start_line": start,
        "truncated": byte_truncated or line_truncated,
    }


def glob_files(
    pattern: str,
    *,
    local_root: str,
    mount_root: str,
) -> dict[str, Any]:
    """List files in the LOCAL repo copy matching a glob ``pattern``.

    ``pattern`` is interpreted relative to the repo root (e.g. ``**/*.cs``,
    ``Config/*.json``); a legacy /mnt/repo-prefixed pattern is also accepted and
    rebased. Returns {"paths": [...], "truncated": bool} with paths in the agent's
    namespace (repo-relative by default), sorted, deduped. Hidden/.git/node_modules
    entries are excluded to match file_search's view. Raises ValueError on an empty pattern
    or one that escapes the repo root."""
    if not pattern or not pattern.strip():
        raise ValueError("glob pattern must be non-empty")
    t0 = perf_counter()

    # Rebase a (legacy) mount-prefixed pattern to repo-relative, then confine the
    # NON-glob prefix to the repo (a pattern like ../../etc/* must be rejected).
    norm_mount = mount_root.rstrip("/")
    rel_pattern = pattern
    if norm_mount and pattern.startswith(norm_mount + "/"):
        rel_pattern = pattern[len(norm_mount) + 1:]
    elif os.path.isabs(pattern):
        raise ValueError(f"absolute glob pattern outside repo: {pattern!r}")
    # Re-check is-absolute on the POST-strip pattern, not just the raw one: with a
    # legacy non-empty mount_root, "/mnt/repo//etc/passwd" strips to "/etc/passwd"
    # (still absolute), which would survive the ../ checks below and then hit
    # os.path.join(real_root, "/etc/passwd") — Python DISCARDS real_root on an
    # absolute second arg (the classic absolute-reset), making disk_pattern
    # "/etc/passwd". The per-hit realpath confinement still drops the out-of-repo
    # match, but reject it here so the lexical guard (the advertised first layer)
    # actually holds and never reaches outside the repo.
    if os.path.isabs(rel_pattern):
        raise ValueError(f"glob pattern escapes repo root (absolute after rebase): {pattern!r}")
    if rel_pattern.startswith("../") or "/../" in rel_pattern or rel_pattern == "..":
        raise ValueError(f"glob pattern escapes repo root: {pattern!r}")

    real_root = os.path.realpath(local_root)
    disk_pattern = os.path.join(real_root, rel_pattern)
    paths: list[str] = []
    truncated = False
    for hit in sorted(_glob.glob(disk_pattern, recursive=True)):
        # Confinement: realpath each hit and keep only those still under the repo
        # root (a symlinked match pointing outside is dropped, not leaked).
        real_hit = os.path.realpath(hit)
        if real_hit != real_root and not real_hit.startswith(real_root.rstrip("/") + "/"):
            continue
        rel = os.path.relpath(real_hit, real_root)
        # Skip VCS/vendored/hidden trees so glob agrees with file_search's view.
        segs = rel.split(os.sep)
        if any(s in (".git", "node_modules", ".venv") for s in segs):
            continue
        if not os.path.isfile(real_hit):
            continue
        try:
            mount_path = path_align.to_container_path(real_hit, index_root=real_root, mount_root=mount_root)
        except ValueError:
            continue
        paths.append(mount_path)
        if len(paths) >= MAX_GLOB_RESULTS:
            truncated = True
            break

    elapsed_ms = (perf_counter() - t0) * 1000
    logger.info(perf_entry("glob_files", elapsed_ms, pattern=pattern[:80],
                           hits=len(paths), truncated=truncated))
    return {"paths": paths, "truncated": truncated, "count": len(paths)}


def read_to_json(requested: str, *, local_root: str, mount_root: str,
                 offset: int = 0, limit: int | None = None) -> str:
    """read_file → JSON string (the MCP tool return shape)."""
    return json.dumps(
        read_file(requested, local_root=local_root, mount_root=mount_root, offset=offset, limit=limit),
        ensure_ascii=False,
    )


def glob_to_json(pattern: str, *, local_root: str, mount_root: str) -> str:
    """glob_files → JSON string (the MCP tool return shape)."""
    return json.dumps(glob_files(pattern, local_root=local_root, mount_root=mount_root), ensure_ascii=False)
