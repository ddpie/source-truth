"""Fast file-content search over a LOCAL-disk copy of the repo.

Why this exists: the agent's builtin Grep runs against the EFS/NFS mount
(/mnt/repo), where a single whole-repo search costs ~20-47s (a network round-trip
per file open across ~18k files). The SAME search on a local-disk copy is ~0.2s
(measured 225x faster). So index-service keeps a local copy (bootstrap.sh extracts
the repo tarball to /data/repo — the same deploy-time snapshot as EFS, just fast)
and exposes this as an MCP tool; the agent's builtin Grep is disabled so all
content search goes through here.

`run_search` is pure-ish (shells out to ripgrep/grep over a given root) and
returns structured matches with paths rewritten into the agent's namespace
(repo-relative by default), so results are indistinguishable from the old Grep
except far faster.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
from time import perf_counter
from typing import Any

import path_align
from perf import perf_entry

logger = logging.getLogger("file-search")

# Hard cap so a pathological pattern can't return megabytes or run unbounded.
MAX_MATCHES = 500
SEARCH_TIMEOUT_S = 20
# Per-file hit ceiling (rg --max-count). Was 5, which silently dropped the 6th+ hit
# in a SINGLE file — e.g. a config/data TABLE where one file legitimately holds dozens
# of relevant rows (race-class tuples, loot rows). The agent saw exactly 5, assumed the
# rest didn't exist, and fell back to many narrow re-searches to recover them. 50 covers
# the dense-data-table case while the global MAX_MATCHES still bounds total output.
MAX_PER_FILE = 50
# Cap on FOLDED-DUPLICATE rows processed, independent of max_matches: heavy
# duplication makes almost every row a fold (which never counts toward
# max_matches), so without this the post-processing loop would iterate the entire
# rg/grep output. Gating on duplicates ALONE (not total rows) means a dup flood
# can't eat into the distinct-match budget — distinct hits keep being appended
# until max_matches. Generous so legitimate vendored copies (e.g. 10x trees)
# don't trip it on a normal search while still bounding the pathological case.
SCAN_DUP_CAP = MAX_MATCHES * 50


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
            "--max-count", str(MAX_PER_FILE),  # per-file hit ceiling (dense data tables need >5)
            "--max-filesize", "100M",      # allow searching large config/data tables
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
    """Rewrite a local-disk path into the agent's namespace (repo-relative by
    default), or None if it escapes the repo root (don't leak an out-of-repo path)."""
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
    repo: str = "",
) -> dict[str, Any]:
    """Search the LOCAL repo copy for `pattern`. Returns
    {"matches": [{"path", "line", "text"}], "truncated": bool} with paths in the
    agent's namespace (repo-relative by default). Never raises for a no-match
    (returns empty matches); raises only on a genuine execution failure so the
    bridge reports it honestly.
    ``repo`` (multi-repo): returned match paths are prefixed with ``<repo>/`` so the agent
    can tell which repo a hit came from. Applied ONLY to the final stored path — the
    duplicate-folding key below runs on the repo-RELATIVE path so its top-level-dir strip
    still folds vendored copies (prefixing first would make it strip the repo segment
    instead of the copy dir). ``repo=""`` is unchanged (single repo)."""
    if not pattern or not pattern.strip():
        raise ValueError("search pattern must be non-empty")
    t0 = perf_counter()
    cmd = build_command(pattern, local_root, glob=glob, max_matches=max_matches)
    try:
        proc = subprocess.run(  # noqa: S603 - argv list, no shell
            # errors="replace": rg/grep stdout can contain bytes from NON-UTF-8 source
            # files (GBK/GB2312 are very common in Chinese game configs). Without this,
            # Python's strict UTF-8 decode of stdout raises UnicodeDecodeError the moment
            # ONE matched file is GBK — crashing the WHOLE search (even an ASCII query)
            # into a generic "internal error", so the agent can't find code that exists
            # (breaks "code as the only source of truth" on Chinese repos). Replace lets
            # the search still return its matches; a few mojibake chars in one line beat
            # losing every result (cross-review P0).
            cmd, capture_output=True, text=True, errors="replace",
            timeout=SEARCH_TIMEOUT_S, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"search timed out after {SEARCH_TIMEOUT_S}s") from exc
    # rg/grep exit 1 == "no matches" (not an error); >1 == real failure.
    if proc.returncode > 1:
        # A bad REGEX (unbalanced group, etc.) is a RECOVERABLE user-input error, not
        # an internal failure — raise ValueError so the bridge surfaces an actionable
        # "bad search pattern" the agent can relay/retry, instead of a generic "internal
        # error". rg/grep both say "regex parse error" / "invalid"; stderr carries no
        # host path (cross-review). Other rc>1 (real failure) stays RuntimeError.
        stderr = proc.stderr or ""
        if re.search(r"regex parse error|invalid regex|unmatched|trailing backslash", stderr, re.IGNORECASE):
            raise ValueError(f"bad search pattern (regex error): {stderr[:200]}")
        raise RuntimeError(f"search failed (rc={proc.returncode}): {stderr[:200]}")

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
        if "/" in rel:
            suffix = rel.split("/", 1)[1]  # drop top-level (copy) dir for nested files
        else:
            # A repo-ROOT file has no top-level dir to drop. Don't degenerate to a
            # bare basename (which would collide with a nested file of the same
            # name, e.g. /Config.cs vs /legacy/Config.cs); mark it as root-anchored
            # so a root file and a nested file with the same name stay distinct.
            suffix = "\x00" + rel
        key = (suffix, line_no, text)
        if key in seen:
            duplicates += 1
        else:
            seen.add(key)
            # Prefix the repo AFTER dedup (which keyed on the repo-relative path): the
            # agent sees <repo>/<rel> so it can tell repos apart in fan-out results.
            stored_path = f"{repo.rstrip('/')}/{mount_path}" if repo else mount_path
            matches.append({"path": stored_path, "line": line_no, "text": text[:300]})
            if len(matches) >= max_matches:
                truncated = True
                break
        # Bound runaway DUPLICATE scanning only. Under heavy duplication nearly
        # every row folds (never appends, so the max_matches break above can't
        # fire), which would let the loop run over the ENTIRE rg/grep output. Gate
        # on the DUPLICATE count alone — NOT len(matches)+duplicates — so a flood
        # of folded copies emitted before the distinct files can't eat into the
        # distinct-match budget and silently drop genuine hits (distinct matches
        # are already capped by max_matches above). This bounds CPU/memory without
        # costing recall regardless of the order rg/grep emits rows.
        if duplicates >= SCAN_DUP_CAP:
            truncated = True
            break

    elapsed_ms = (perf_counter() - t0) * 1000
    logger.info(perf_entry("file_search", elapsed_ms, pattern=pattern[:60],
                           hits=len(matches), truncated=truncated, deduped=duplicates))
    # `deduped` is surfaced to the AGENT (not just the perf log) so a folded hit is
    # never invisible: if it sees deduped>0 and needs the individual copies, it can
    # re-search a specific subdir. Folding is recoverable, not a silent recall loss.
    return {"matches": matches, "truncated": truncated, "count": len(matches), "deduped": duplicates}


def search_to_json(pattern: str, *, local_root: str, mount_root: str, glob: str | None = None, repo: str = "") -> str:
    """run_search → JSON string (the MCP tool return shape)."""
    return json.dumps(run_search(pattern, local_root=local_root, mount_root=mount_root, glob=glob, repo=repo), ensure_ascii=False)
