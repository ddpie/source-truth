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
from text_decode import decode_bytes

logger = logging.getLogger("file-read")

# Two SEPARATE budgets — the distinction matters (see the bug they fix below):
#
#   MAX_FILE_BYTES  bounds how much we READ from disk (an OOM guard against a
#                   pathological multi-GB blob). It does NOT gate reachability:
#                   `offset` can land anywhere within this window.
#   MAX_READ_BYTES  bounds the size of the RETURNED slice (context guard).
#   MAX_READ_LINES  bounds the number of lines in the returned slice.
#
# REGRESSION THIS FIXES: the old code did `fh.read(MAX_READ_BYTES+1)` from byte 0
# and THEN paged by line offset. So a file larger than 256 KiB could only ever be
# read up to its first 256 KiB — an `offset` pointing past that (e.g. a data table
# at line 7699 / byte 296 023 of a 508 KiB sql dump) silently returned EMPTY, with
# no signal. The agent couldn't tell "no such lines" from "cut off before here",
# so it fell back to dozens of narrow searches. Now we read up to MAX_FILE_BYTES
# (so any line within a normal file is reachable) and apply the size/line caps to
# the OUTPUT window only — and we surface total_lines + next_offset so a genuinely
# truncated read tells the agent exactly how to continue.
MAX_FILE_BYTES = 16 * 1024 * 1024    # 16 MiB read ceiling (OOM guard; reachability, not output)
MAX_READ_BYTES = 256 * 1024          # 256 KiB ceiling on the RETURNED slice (context guard)
MAX_READ_LINES = 4000                # …and a line ceiling on the returned slice (whichever hits first)
MAX_GLOB_RESULTS = 1000              # cap glob fan-out


def _trim_partial_utf8_tail(raw: bytes) -> bytes:
    """Drop a trailing INCOMPLETE UTF-8 multibyte sequence (≤3 bytes) left by a byte-cap
    cut, so the clean prefix still decodes as strict UTF-8 instead of falling through to
    a GB18030 mis-decode. If the tail is already complete/ASCII, returns raw unchanged.
    Only trims a genuine continuation pattern (a lead byte 0b11xxxxxx followed by fewer
    continuation bytes 0b10xxxxxx than its length implies)."""
    # Scan back over continuation bytes (10xxxxxx); the byte before them is the lead byte.
    n = len(raw)
    i = n - 1
    # At most 3 continuation bytes precede a 4-byte lead.
    while i >= 0 and i >= n - 3 and (raw[i] & 0xC0) == 0x80:
        i -= 1
    if i < 0 or i >= n:
        return raw
    lead = raw[i]
    if lead < 0x80:
        return raw  # ASCII tail — nothing partial
    # Expected sequence length from the lead byte's high bits.
    if (lead & 0xE0) == 0xC0:
        need = 2
    elif (lead & 0xF0) == 0xE0:
        need = 3
    elif (lead & 0xF8) == 0xF0:
        need = 4
    else:
        return raw  # not a valid lead (stray continuation) — leave it for decode_bytes
    have = n - i
    return raw[:i] if have < need else raw  # incomplete → drop from the lead byte


def read_file(
    requested: str,
    *,
    local_root: str,
    mount_root: str,
    offset: int = 0,
    limit: int | None = None,
    repo: str = "",
) -> dict[str, Any]:
    """Read a single file from the LOCAL repo copy.

    ``requested`` is an agent-space path (repo-relative, or a legacy ``/mnt/repo/...``
    prefix); it is confined to ``local_root`` before opening. Returns
    {"path", "content", "lines", "truncated"} with ``path`` in the agent's namespace
    (repo-relative by default).
    ``repo`` (multi-repo): the graph/search tools emit paths as ``<repo>/<rel>`` so the
    agent can tell repos apart, and passes that path back here verbatim. With ``repo`` set,
    ``to_local_path`` STRIPS the leading ``<repo>/`` before confining to ``local_root`` (the
    repo's own copy), and the returned path is re-prefixed so it round-trips. ``repo=""``
    (single repo / no prefix) is unchanged.
    ``offset`` (0-based line) + ``limit`` page large files. Raises ValueError on
    a bad/escaping path or a path that isn't a regular file (so the bridge can
    report a clean error rather than leak a stack trace)."""
    t0 = perf_counter()
    local_path = path_align.to_local_path(requested, local_root=local_root, mount_root=mount_root, repo=repo)
    if not os.path.isfile(local_path):
        raise ValueError(f"not a readable file: {requested!r}")

    # Read up to the OOM-guard ceiling (NOT the output cap) so any line within a normal
    # file is reachable by offset — the read window must not silently truncate the file
    # before the requested offset (the regression documented at MAX_FILE_BYTES). decode_bytes
    # detects BOM / UTF-8 / GB18030 (the common Chinese-game-repo legacy encoding) before any
    # lossy fallback, so a GBK source is read FAITHFULLY rather than as mojibake (cross-review
    # HIGH — the prior hardcoded utf-8+replace silently corrupted Chinese names/comments/config).
    raw = b""
    with open(local_path, "rb") as fh:
        raw = fh.read(MAX_FILE_BYTES + 1)
    file_byte_truncated = len(raw) > MAX_FILE_BYTES
    if file_byte_truncated:
        raw = raw[:MAX_FILE_BYTES]
        # A byte cap can slice mid-multibyte-char. If we hand that dangling partial char
        # to decode_bytes, strict-UTF-8 would FAIL on the trailing 1-2 bytes and the whole
        # (otherwise-valid-UTF-8) buffer would fall through to GB18030 and be mis-decoded
        # as Chinese (cross-review P1). Drop up to 3 trailing bytes that look like an
        # incomplete UTF-8 continuation so the cut lands on a char boundary — then strict
        # UTF-8 succeeds on the clean prefix. (≤3 dropped bytes is invisible next to a
        # 16 MiB truncation the flag already signals.)
        raw = _trim_partial_utf8_tail(raw)
    text, encoding = decode_bytes(raw)

    # splitlines() splits on the full Unicode line-boundary set (\v \f \x85   …),
    # but file_search/ripgrep count lines by \n ONLY. Using splitlines() here made
    # read_file's line numbers (and offset/limit paging) diverge from the line numbers
    # search cites — the agent would read at the cited offset and land on different
    # content (cross-review MEDIUM). Split on \n to match the search backend; a trailing
    # \n yields an empty last element, which we drop so it isn't counted as a line.
    all_lines = text.split("\n")
    if all_lines and all_lines[-1] == "":
        all_lines.pop()
    # Strip a trailing \r so CRLF (Windows/Unity) files don't carry a spurious \r on every
    # line (split("\n") leaves it; splitlines() used to eat it). ripgrep/grep also drop the
    # \r in their match text, so this keeps read_file's content consistent with search's
    # (cross-review P2). Only the line-ending \r is removed — an intra-line \r is untouched.
    all_lines = [ln[:-1] if ln.endswith("\r") else ln for ln in all_lines]
    total_lines = len(all_lines)
    # Clamp start INTO the file: an offset past EOF returns an empty (but honest) window
    # anchored at EOF, never a negative slice. (offset beyond total_lines → start=total_lines.)
    start = min(max(0, offset), total_lines)
    # A non-positive limit means "no caller line cap" (treat like None) — NOT "read
    # zero lines". The old min(..., start + max(0, limit)) made limit<=0 collapse
    # end→start: it returned an empty slice AND truncated=True on any non-empty file,
    # so the agent thought the file was cut off and needlessly paged (cross-review).
    end = total_lines if (limit is None or limit <= 0) else min(total_lines, start + limit)
    # Independent line ceiling on top of any caller limit.
    end = min(end, start + MAX_READ_LINES)
    sliced = all_lines[start:end]

    # Enforce the OUTPUT byte cap on the returned slice (context guard) by dropping whole
    # trailing lines until the joined content fits — never return a half-line, and keep the
    # reported line count honest. Independent of the disk-read ceiling above.
    char_byte_truncated = False
    while sliced and len("\n".join(sliced).encode("utf-8")) > MAX_READ_BYTES:
        sliced.pop()
        end -= 1
        char_byte_truncated = True

    # `truncated` = the returned window does NOT reach EOF (more lines follow), for ANY
    # reason: caller limit, line ceiling, output-byte cap, or the disk-read ceiling. When
    # true, next_offset tells the agent exactly where to resume — turning a silent cut into
    # an actionable "call again with this offset" (the signal whose absence drove the agent
    # to fall back to dozens of narrow searches).
    line_truncated = end < total_lines
    truncated = line_truncated or file_byte_truncated or char_byte_truncated

    # Align the RETURNED path against the realpath'd root: to_local_path already
    # realpath'd local_path (symlinks followed), so re-rooting it against a raw
    # local_root that itself contains a symlink component would fail the lexical
    # prefix match and raise "escapes repo root" on every read. Mirror glob_files,
    # which roots on os.path.realpath(local_root).
    mount_path = path_align.to_container_path(
        local_path, index_root=os.path.realpath(local_root), mount_root=mount_root, repo=repo)
    elapsed_ms = (perf_counter() - t0) * 1000
    logger.info(perf_entry("file_read", elapsed_ms, path=mount_path[:120],
                           lines=len(sliced), start=start, total=total_lines,
                           truncated=truncated, file_capped=file_byte_truncated,
                           encoding=encoding))
    result: dict[str, Any] = {
        "path": mount_path,
        "content": "\n".join(sliced),
        "lines": len(sliced),
        "start_line": start,
        # total_lines reachable in this file (within the 16 MiB read ceiling) so the agent
        # can size its paging instead of guessing whether more remains.
        "total_lines": total_lines,
        "truncated": truncated,
    }
    # When truncated, hand the agent the EXACT next offset to resume from — a contiguous,
    # 0-based line cursor. Its absence is what turned "the table continues below" into a
    # guessing game last time. Only set when there's genuinely more AHEAD in this window's
    # direction (end < total_lines); a file-byte-capped read that still ends at EOF won't
    # set it (nothing reachable beyond the 16 MiB ceiling to point at).
    if end < total_lines:
        result["next_offset"] = end
    # Surface a NON-UTF-8 decode so the agent knows the source was legacy-encoded (a
    # GB18030 hit confirms a GBK/GB2312 Chinese file decoded faithfully; utf-8-replace
    # warns the content may be partly garbled and shouldn't be over-trusted).
    if encoding not in ("utf-8",):
        result["encoding"] = encoding
    return result


def glob_files(
    pattern: str,
    *,
    local_root: str,
    mount_root: str,
    repo: str = "",
) -> dict[str, Any]:
    """List files in the LOCAL repo copy matching a glob ``pattern``.

    ``pattern`` is interpreted relative to the repo root (e.g. ``**/*.cs``,
    ``Config/*.json``); a legacy /mnt/repo-prefixed pattern is also accepted and
    rebased. Returns {"paths": [...], "truncated": bool} with paths in the agent's
    namespace (repo-relative by default), sorted, deduped. Hidden/.git/node_modules
    entries are excluded to match file_search's view. Raises ValueError on an empty pattern
    or one that escapes the repo root.
    ``repo`` (multi-repo): with ``repo`` set, a leading ``<repo>/`` on the pattern is stripped
    before globbing this repo's copy, and returned paths are re-prefixed with ``<repo>/`` so
    they round-trip with what the agent saw. ``repo=""`` is unchanged (single repo)."""
    if not pattern or not pattern.strip():
        raise ValueError("glob pattern must be non-empty")
    t0 = perf_counter()

    # Normalize separators FIRST, exactly like read_file (which goes through
    # to_local_path → _normalize_seps). A game repo (Unity/.NET) can carry backslash
    # paths; without this a pattern like `Config\*.json` stayed a single backslash-laden
    # literal → glob found 0 files while read_file (normalized) could read the same path
    # — an inconsistency the agent can't diagnose (cross-review). Backslashes → '/',
    # leading '//' collapsed.
    pattern = path_align._normalize_seps(pattern)

    # MULTI-REPO: strip a leading "<repo>/" the agent carried over from a cited path (the
    # graph/search tools prefix every path with the repo it came from). Only a relative
    # pattern carries it; a legacy absolute mount pattern never does. repo="" → no-op.
    if repo and not os.path.isabs(pattern):
        _prefix = repo.rstrip("/") + "/"
        if pattern == repo:
            pattern = ""
        elif pattern.startswith(_prefix):
            pattern = pattern[len(_prefix):]
        if not pattern or not pattern.strip():
            raise ValueError("glob pattern is empty after stripping the repo prefix")

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
            mount_path = path_align.to_container_path(real_hit, index_root=real_root, mount_root=mount_root, repo=repo)
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
                 offset: int = 0, limit: int | None = None, repo: str = "") -> str:
    """read_file → JSON string (the MCP tool return shape)."""
    return json.dumps(
        read_file(requested, local_root=local_root, mount_root=mount_root, offset=offset, limit=limit, repo=repo),
        ensure_ascii=False,
    )


def glob_to_json(pattern: str, *, local_root: str, mount_root: str, repo: str = "") -> str:
    """glob_files → JSON string (the MCP tool return shape)."""
    return json.dumps(glob_files(pattern, local_root=local_root, mount_root=mount_root, repo=repo), ensure_ascii=False)
