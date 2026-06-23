"""CLI entry: (re)build a project's glossary on the index host.

Wires the pieces in glossary_build + glossary into a single command the
activate_project / index-refresh units invoke. Two modes:

  full         scan the whole repo with cc (first activation / fallback)
  incremental  scan only files a git-diff changed (the default on refresh)

Usage:
  python3 -m glossary_gen --project <id> --repo-root <dir> --out <entries.jsonl> \
      --model <bedrock-model-id> --region <r> [--old <sha> --new <sha>] [--full]

TOKEN FRUGALITY: incremental hands cc only the changed files; an EMPTY diff exits 0
WITHOUT calling cc (nothing to do). On first build (no --old, or --full) it does a
full scan. The git diff is computed here from --old/--new (which git_fetch records
around its reset) so this script stays self-contained.

EXIT CODES: 0 ok (incl. no-op empty diff); 2 bad args / unusable repo. A cc failure
during refresh is logged and treated as a SKIP (keep the existing glossary) — never
blank a working index on a transient build error; --strict makes it fatal instead.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys

import glossary
import glossary_build

logger = logging.getLogger("glossary-gen")

# Files whose changes can't yield code symbols / domain terms — skip to save cc tokens.
_SKIP_PREFIXES = (".git/", "node_modules/", ".venv/")

# Scan ALL text files — code/config AND docs (README/design notes/wiki/plain text), since the
# Chinese terms that bridge to code often live in docs. We do NOT allowlist extensions (that would
# "limit file types"); instead we EXCLUDE known binary/asset extensions (can't extract terms from a
# PNG, and feeding binary to cc wastes tokens). Doc-sourced terms are demoted in confidence at
# extract time (glossary.is_code_source / demote_confidence) so code stays authoritative.
_BINARY_EXTS = (
    # images / media
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".svg", ".webp", ".tga", ".dds",
    ".psd", ".mp3", ".wav", ".ogg", ".mp4", ".mov", ".avi", ".webm", ".ttf", ".otf", ".woff", ".woff2",
    # archives / binaries
    ".zip", ".gz", ".tar", ".7z", ".rar", ".bin", ".exe", ".dll", ".so", ".dylib", ".a", ".o",
    ".class", ".jar", ".pyc", ".wasm", ".pdf", ".db", ".sqlite", ".lock",
    # game/binary asset blobs
    ".dbc", ".m2", ".blp", ".mdx", ".unity3d", ".asset", ".fbx", ".prefab",
)
# Hard cap on files handed to cc in ONE build, so even a huge repo (or a giant commit) can't
# launch an unbounded scan. Beyond this we log a dropped-count (never silently truncate).
# Default 400 (a full build of a large repo at ~$0.005/file ≈ $2 and ~12 min — measured on the test repo).
# Overridable per project: env GLOSSARY_MAX_FILES, or --max-files (flag wins). Raise it to trade
# Bedrock cost for coverage on a big repo; 0/negative means "no cap" (whole candidate set).
MAX_BUILD_FILES = int(os.environ.get("GLOSSARY_MAX_FILES", "400") or "400")


def _is_term_file(path: str) -> bool:
    # A term-bearing (text) file = NOT a known binary/asset. Case-insensitive. Note: .db/.sqlite
    # are excluded here (binary) — structured config tables go through read_table, not cc text scan.
    return not path.lower().endswith(_BINARY_EXTS)


def candidate_files(repo_root: str) -> list[str]:
    """Repo-relative text files for a FULL scan — bounds 'full' to text files (excludes binary/
    asset blobs) instead of letting cc roam the whole tree. Skips VCS/vendored dirs. Sorted +
    capped at MAX_BUILD_FILES (the drop is logged by the caller, never silent)."""
    import os
    root = os.path.realpath(repo_root)
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", ".venv")]
        for fn in filenames:
            if not _is_term_file(fn):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)
            if not rel.startswith(_SKIP_PREFIXES):
                out.append(rel)
    return sorted(out)


def changed_files(repo_root: str, old: str, new: str) -> tuple[set[str], set[str]]:
    """Return (changed, deleted) repo-relative paths between two shas via name-status.
    `changed` = added/modified/renamed-to; `deleted` = removed/renamed-from. Raises
    subprocess.CalledProcessError if git can't diff (caller falls back to full)."""
    out = subprocess.run(  # noqa: S603 - fixed argv
        ["git", "-C", repo_root, "diff", "--name-status", "-M", f"{old}..{new}"],
        capture_output=True, text=True, check=True,
    ).stdout
    changed: set[str] = set()
    deleted: set[str] = set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0]
        if status.startswith("D"):
            deleted.add(parts[1])
        elif status.startswith("R") and len(parts) >= 3:
            deleted.add(parts[1])   # old name gone
            changed.add(parts[2])   # new name added
        else:  # A, M, C, T
            changed.add(parts[-1])
    def _filt(s: set[str]) -> set[str]:
        return {p for p in s if not p.startswith(_SKIP_PREFIXES)}
    return _filt(changed), _filt(deleted)


def _write_atomic(path: str, entries: list[glossary.Entry]) -> None:
    """Write entries to a temp file then rename — a reader never sees a half-written index
    (the refresh unit and a live read can race), and the live slice is only swapped by the
    atomic os.replace (which never runs if the temp write failed, so the OLD slice survives a
    disk-full/read-only error). On failure, clean up the temp and re-raise OSError so the caller
    treats it as a build failure (SKIP) rather than a success."""
    tmp = path + ".new"
    try:
        glossary.write_entries(tmp, entries)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)  # don't leave a stale .new behind (it's never read, but don't litter)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="(re)build a project's glossary")
    p.add_argument("--project", required=True)
    p.add_argument("--repo-root", required=True, help="local repo copy to scan (cc cwd)")
    p.add_argument("--out", required=True, help="entries.jsonl path under /data/glossary/<project>/")
    p.add_argument("--model", required=True)
    p.add_argument("--region", required=True)
    p.add_argument("--old", default="", help="git sha BEFORE refresh (omit => full scan)")
    p.add_argument("--new", default="HEAD", help="git sha AFTER refresh")
    p.add_argument("--full", action="store_true", help="force a full scan")
    p.add_argument("--strict", action="store_true", help="treat a cc build failure as fatal")
    p.add_argument("--timeout", type=int, default=glossary_build.DEFAULT_TIMEOUT_S)
    p.add_argument("--max-files", type=int, default=None,
                   help="per-build file cap (wins over GLOSSARY_MAX_FILES env / default 400); "
                        "0 or negative = no cap (scan the whole candidate set)")
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if not glossary.is_valid_concept_id(args.project) and not args.project.replace("-", "").isalnum():
        # project id is also a path segment downstream; keep it slug-ish.
        logger.error(json.dumps({"event": "glossary_gen_bad_project", "project": args.project}))
        return 2
    if not os.path.isdir(args.repo_root):
        logger.error(json.dumps({"event": "glossary_gen_no_repo", "repo_root": args.repo_root}))
        return 2

    # Resolve the per-build file cap: --max-files flag wins, else the module default
    # (GLOSSARY_MAX_FILES env or 400). <=0 means "no cap" (whole candidate set).
    cap = args.max_files if args.max_files is not None else MAX_BUILD_FILES
    uncapped = cap <= 0

    incremental = bool(args.old) and not args.full
    files: list[str] | None = None
    deleted: set[str] = set()
    existing: list[glossary.Entry] = []

    if incremental:
        try:
            chg, deleted = changed_files(args.repo_root, args.old, args.new)
        except subprocess.CalledProcessError as exc:
            logger.warning(json.dumps({"event": "glossary_gen_diff_failed_fallback_full",
                                       "detail": str(exc)[:200]}))
            incremental = False
        else:
            if not chg and not deleted:
                logger.info(json.dumps({"event": "glossary_gen_noop_empty_diff",
                                        "project": args.project, "old": args.old, "new": args.new}))
                return 0  # HEAD unchanged → no cc call, keep the index as-is
            # Drop docs/asset/CI-only changes: a commit that touched no term-bearing file
            # shouldn't spend a cc call. Deletions still apply to ALL changed paths (a deleted
            # term file's entries must go regardless of the term filter on the build set).
            files = [p for p in sorted(chg) if _is_term_file(p)]
            if not files and not deleted:
                logger.info(json.dumps({"event": "glossary_gen_noop_no_term_files",
                                        "project": args.project, "changed": len(chg)}))
                return 0  # only docs/assets changed → nothing to (re)build, index unchanged
            if os.path.isfile(args.out):
                existing = glossary.read_entries(args.out)
    if not incremental:
        # FULL scan: bound it to candidate term-bearing files instead of letting cc roam the
        # whole repo (the previously-uncapped cost). Cap at MAX_BUILD_FILES; log any drop.
        cands = candidate_files(args.repo_root)
        if not uncapped and len(cands) > cap:
            logger.warning(json.dumps({"event": "glossary_gen_full_capped",
                                       "project": args.project, "candidates": len(cands),
                                       "cap": cap, "dropped": len(cands) - cap}))
            cands = cands[:cap]
        files = cands

    # Cap the incremental build set too (a giant single commit shouldn't launch an unbounded scan).
    if incremental and files and not uncapped and len(files) > cap:
        logger.warning(json.dumps({"event": "glossary_gen_incremental_capped",
                                   "project": args.project, "changed_term_files": len(files),
                                   "cap": cap, "dropped": len(files) - cap}))
        files = files[:cap]

    # Build the slice with cc. `files` is now ALWAYS a concrete list (full=candidates,
    # incremental=changed term files) — never None — so cc always gets a bounded file scope.
    rebuilt: list[glossary.Entry] = []
    if files:
        try:
            rebuilt = glossary_build.build(
                files, project=args.project, cwd=args.repo_root,
                model=args.model, region=args.region, timeout=args.timeout)
        except (subprocess.SubprocessError, OSError) as exc:
            logger.error(json.dumps({"event": "glossary_gen_cc_failed",
                                     "project": args.project, "detail": str(exc)[:200]}))
            if args.strict:
                return 2
            return 0  # SKIP: keep the existing glossary rather than blank it on a transient error

    if incremental:
        # Conservative guard: cc exited 0 but produced NOTHING for changed (non-deleted) files.
        # That's far more likely a silent cc failure (throttle/garbage) than every changed file
        # genuinely losing all its terms. Rather than drop those files' existing entries (shrinking
        # the slice), SKIP and keep the slice as-is — UNLESS this diff is purely deletions (then an
        # empty rebuilt is correct and we must apply the deletions).
        if files and not rebuilt and not deleted:
            logger.warning(json.dumps({"event": "glossary_gen_empty_rebuild_skip",
                                       "project": args.project, "changed_files": len(files)}))
            return 0
        merged = glossary_build.merge_incremental(
            existing, changed=set(files or []), deleted=deleted, rebuilt=rebuilt)
    else:
        merged = rebuilt

    try:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        _write_atomic(args.out, merged)
    except OSError as exc:
        # disk full / read-only / temp unwritable — the live slice was NOT swapped (os.replace
        # never ran), so old data is intact. Log + SKIP cleanly instead of a raw traceback.
        logger.error(json.dumps({"event": "glossary_gen_write_failed",
                                 "project": args.project, "detail": str(exc)[:200]}))
        return 0 if not args.strict else 2
    concepts = glossary.aggregate(merged)
    logger.info(json.dumps({"event": "glossary_gen_done", "project": args.project,
                            "mode": "incremental" if incremental else "full",
                            "entries": len(merged), "concepts": len(concepts),
                            "changed_files": len(files) if files else None}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
