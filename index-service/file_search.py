"""Fast file-content search over a LOCAL-disk copy of the repo.

Why this exists: the agent's builtin Grep runs against the EFS/NFS mount
(/mnt/repo), where a single whole-repo search costs ~20-47s (a network round-trip
per file open across ~18k files). The SAME search on a local-disk copy is ~0.2s
(measured 225x faster). So index-service keeps a local copy (bootstrap.sh extracts
the repo tarball to /data/repo — the same deploy-time snapshot as EFS, just fast)
and exposes this as an MCP tool; the agent's builtin Grep is disabled so all
content search goes through here.

`run_search` is pure-ish (shells out to ripgrep/grep over a given root) and
returns structured matches with paths rewritten into the agent's /mnt/repo space,
so results are indistinguishable from the old Grep except far faster.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from time import perf_counter
from typing import Any

import path_align
from perf import perf_entry

logger = logging.getLogger("file-search")

# Hard cap so a pathological pattern can't return megabytes or run unbounded.
MAX_MATCHES = 200
SEARCH_TIMEOUT_S = 20


def _rg_available() -> bool:
    return shutil.which("rg") is not None


def build_command(pattern: str, root: str, *, glob: str | None, max_matches: int) -> list[str]:
    """Build the search argv. Prefers ripgrep (fast, skips binaries); falls back
    to grep -r. Pure so it's unit-testable.

    CRITICAL: rg must see the FULL on-disk tree to honor "code is the only truth".
    By default rg respects .gitignore AND skips dotfiles — so a file that is
    gitignored (generated config tables, *.generated.cs) or hidden would be
    INVISIBLE to rg yet present on disk, making the agent answer "not found" off
    an incomplete view. So we force --no-ignore --hidden (mirror grep's view) and
    only ever skip the .git metadata dir (never source). The grep fallback already
    sees everything except its explicit excludes; the two backends now agree.
    """
    if _rg_available():
        cmd = [
            "rg", "--line-number", "--no-heading", "--color", "never",
            "--no-ignore",                 # do NOT skip .gitignore'd files (they exist on disk)
            "--hidden",                    # include dotfiles/dirs (config, .env-like tables)
            "--glob", "!.git/",            # …but never the VCS metadata dir
            "--glob", "!node_modules/",    # nor vendored deps (huge, not the project's code)
            "--max-count", "5",            # at most 5 hits per file (enough to locate)
            "--max-filesize", "2M",        # skip huge generated blobs
            "-e", pattern,
        ]
        if glob:
            cmd += ["--glob", glob]
        cmd.append(root)
        return cmd
    # grep fallback: -r recursive, -n line numbers, -I skip binary, exclude VCS/deps
    # (matches the rg view above so results don't depend on which binary is present).
    cmd = ["grep", "-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.venv"]
    if glob:
        cmd += [f"--include={glob}"]
    cmd += ["-e", pattern, root]
    return cmd


def _to_mount(path: str, *, local_root: str, mount_root: str) -> str | None:
    """Rewrite a local-disk path into the agent's /mnt/repo space, or None if it
    escapes the repo root (don't leak an out-of-repo path)."""
    try:
        return path_align.to_container_path(path, index_root=local_root, mount_root=mount_root)
    except ValueError:
        return None


def run_search(
    pattern: str,
    *,
    local_root: str,
    mount_root: str,
    glob: str | None = None,
    max_matches: int = MAX_MATCHES,
) -> dict[str, Any]:
    """Search the LOCAL repo copy for `pattern`. Returns
    {"matches": [{"path", "line", "text"}], "truncated": bool} with paths in
    /mnt/repo space. Never raises for a no-match (returns empty matches); raises
    only on a genuine execution failure so the bridge reports it honestly."""
    if not pattern or not pattern.strip():
        raise ValueError("search pattern must be non-empty")
    t0 = perf_counter()
    cmd = build_command(pattern, local_root, glob=glob, max_matches=max_matches)
    try:
        proc = subprocess.run(  # noqa: S603 - argv list, no shell
            cmd, capture_output=True, text=True, timeout=SEARCH_TIMEOUT_S, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"search timed out after {SEARCH_TIMEOUT_S}s") from exc
    # rg/grep exit 1 == "no matches" (not an error); >1 == real failure.
    if proc.returncode > 1:
        raise RuntimeError(f"search failed (rc={proc.returncode}): {proc.stderr[:200]}")

    matches: list[dict[str, Any]] = []
    truncated = False
    duplicates = 0
    # Collapse matches that are the SAME file-within-a-copy duplicated under a
    # different top-level dir. Many game repos vendor/duplicate trees (the test
    # repo has 10 identical dfu_scripts_N copies → every hit returned 10x, which
    # 10x'd the agent's per-turn context and made answers minutes-slow). Keying on
    # (path-without-its-first-segment, line, text) folds dfu_scripts_1/X:10:foo and
    # dfu_scripts_2/X:10:foo into ONE result (first wins), while genuinely distinct
    # files (different relative paths) are untouched. Generic: helps any repo with
    # duplicated/vendored code, no project-specific assumptions.
    seen: set[tuple[str, int, str]] = set()
    for raw_line in proc.stdout.splitlines():
        # Format (rg/grep -n): <path>:<line>:<text>
        parts = raw_line.split(":", 2)
        if len(parts) < 3:
            continue
        path, line_s, text = parts
        mount_path = _to_mount(path, local_root=local_root, mount_root=mount_root)
        if mount_path is None:
            continue
        try:
            line_no = int(line_s)
        except ValueError:
            continue
        # Dedup key: (path-without-its-top-level dir, line, matched text). The test
        # repo duplicates whole trees that differ ONLY in their top-level dir
        # (dfu_scripts_1..10/Game/Enemy.cs), so dropping that one segment folds the
        # copies while keeping the rest of the path as a discriminator. This is
        # LESS aggressive than a bare basename (which would also collapse two
        # genuinely-different modules that happen to share a filename). Folding is
        # NOT silent: `duplicates` is returned to the agent as `deduped` so it knows
        # hits were collapsed and can re-search a specific subdir if it needs the
        # individual copies — no invisible recall loss.
        rel = mount_path[len(mount_root):].lstrip("/") if mount_path.startswith(mount_root) else mount_path.lstrip("/")
        suffix = rel.split("/", 1)[1] if "/" in rel else rel  # drop top-level (copy) dir
        key = (suffix, line_no, text)
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        matches.append({"path": mount_path, "line": line_no, "text": text[:300]})
        if len(matches) >= max_matches:
            truncated = True
            break

    elapsed_ms = (perf_counter() - t0) * 1000
    logger.info(perf_entry("file_search", elapsed_ms, pattern=pattern[:60],
                           hits=len(matches), truncated=truncated, deduped=duplicates))
    # `deduped` is surfaced to the AGENT (not just the perf log) so a folded hit is
    # never invisible: if it sees deduped>0 and needs the individual copies, it can
    # re-search a specific subdir. Folding is recoverable, not a silent recall loss.
    return {"matches": matches, "truncated": truncated, "count": len(matches), "deduped": duplicates}


def search_to_json(pattern: str, *, local_root: str, mount_root: str, glob: str | None = None) -> str:
    """run_search → JSON string (the MCP tool return shape)."""
    return json.dumps(run_search(pattern, local_root=local_root, mount_root=mount_root, glob=glob), ensure_ascii=False)
