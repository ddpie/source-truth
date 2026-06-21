#!/usr/bin/env python3
"""render_manifest.py — validate REPO_MANIFEST_JSON and emit per-repo records.

Pure + side-effect free. The multi-repo manifest (multi-repo-isolation plan 阶段2) describes a
project's repo set in ONE JSON value, deliberately NOT a set of shell variables — a per-repo
S3 ETag can contain `|` (multipart upload, e.g. `da58…-3`), and naked `|` in a sourced env
file is parsed as a shell pipe and crashes bootstrap under `set -e` (the project hit this twice
single-repo). So bootstrap reads ONE `REPO_MANIFEST_JSON` and calls this to validate + iterate.

Manifest shape:
    { "repos": [ { "subdir": "<name>", "source": "<git url | s3:// | local path>",
                   "sig": "<artifact signature / ETag>" }, ... ] }

Validation (fail-loud — a bad manifest must crash the deploy up front, never half-provision):
  - non-empty `repos` array;
  - each `subdir` matches ^[a-z0-9-]+$  (it becomes a useradd name / path / systemd unit /
    pgrep pattern — an unchecked name is a privileged-config injection; plan 不变量3 + 阶段2);
  - `subdir` unique (two repos sharing a subdir would share graph.db/HOME → corruption);
  - `source` present and non-empty (empty → rm -rf root-wipe risk; plan 不变量3);
  - `sig` optional (defaults to "" → bootstrap treats as "always re-extract").

Emits one NDJSON record per repo on stdout: {"subdir","source","sig"} — the bootstrap loop
reads these (or `--field subdir` prints just the subdir column for a shell `for` loop).
"""
import json
import re
import sys

# \A…\Z anchors the WHOLE string — NOT ^…$, whose $ also matches just before a trailing
# newline, so "code-5x\n" would slip through and carry a newline into useradd/path/unit/pgrep
# (cross-review CRITICAL). Must start with an alphanumeric (no leading '-'), or a name like
# "-rf" becomes a CLI option flag instead of a value (option injection, cross-review MEDIUM).
SUBDIR_RE = re.compile(r"\A[a-z0-9][a-z0-9-]*\Z")


def parse_manifest(raw: str):
    """Parse + validate a REPO_MANIFEST_JSON string. Returns the list of repo dicts
    (each {subdir, source, sig}). Raises ValueError (fail-loud) on any problem."""
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError) as e:
        raise ValueError(f"REPO_MANIFEST_JSON is not valid JSON: {e}")
    if not isinstance(obj, dict):
        raise ValueError("manifest must be a JSON object")
    repos = obj.get("repos")
    if not isinstance(repos, list) or not repos:
        raise ValueError("manifest.repos must be a non-empty array")

    seen = set()
    out = []
    for i, r in enumerate(repos):
        where = f"repos[{i}]" + (f" (subdir={r.get('subdir')!r})" if isinstance(r, dict) else "")
        if not isinstance(r, dict):
            raise ValueError(f"{where}: must be an object")
        subdir = r.get("subdir")
        if not isinstance(subdir, str) or not subdir:
            raise ValueError(f"{where}: 'subdir' must be a non-empty string")
        if not SUBDIR_RE.match(subdir):
            raise ValueError(
                f"{where}: subdir '{subdir}' must match {SUBDIR_RE.pattern} "
                f"(it becomes a user/path/unit name — no slashes, spaces, dots, or metachars)"
            )
        if subdir in seen:
            raise ValueError(f"{where}: duplicate subdir '{subdir}' (would share graph.db/HOME → corruption)")
        seen.add(subdir)
        source = r.get("source")
        if not isinstance(source, str) or not source.strip():
            raise ValueError(f"{where}: 'source' must be a non-empty string (empty risks an rm -rf root-wipe)")
        sig = r.get("sig")
        if sig is not None and not isinstance(sig, str):
            raise ValueError(f"{where}: 'sig' must be a string if present")
        out.append({"subdir": subdir, "source": source, "sig": sig or "", "ref": r.get("ref") or ""})
    return out


def serve_args(repos, local_root: str) -> str:
    """Build the bridge serve unit's --workspace/--local-workspace argv (multi-repo 阶段2).

    The serve side is ONE bridge process loading every repo (the design's per-project process
    topology), so its ExecStart needs a `--workspace <dir> --local-workspace <dir>` pair PER
    repo. Each repo lives at ``<local_root>/<subdir>`` on the index host (where bootstrap
    extracts it). Emitting this here (not assembled in shell) keeps the corruption-critical
    bootstrap thin and makes the arg construction unit-testable.

    subdir is already charset-validated by parse_manifest (^[a-z0-9][a-z0-9-]*$ — no spaces,
    quotes, or shell metacharacters), so the paths are safe to place on a command line.
    Returns a single space-joined string in manifest (repo-declaration) order.
    """
    root = local_root.rstrip("/")
    parts = []
    for r in repos:
        d = f"{root}/{r['subdir']}"
        parts.append(f"--workspace {d} --local-workspace {d}")
    return " ".join(parts)


def main(argv):
    # Read the manifest from argv[1] (a path) or stdin; --field <name> prints just that column
    # one-per-line (for a shell `for subdir in $(... --field subdir)` loop); --serve-args
    # <local_root> prints the bridge serve unit's --workspace/--local-workspace argv.
    field = None
    serve_root = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == "--field" and i + 1 < len(argv):
            field = argv[i + 1]
            i += 2
        elif argv[i] == "--serve-args" and i + 1 < len(argv):
            serve_root = argv[i + 1]
            i += 2
        else:
            args.append(argv[i])
            i += 1

    if args:
        try:
            raw = open(args[0], encoding="utf-8").read()
        except OSError as e:
            sys.stderr.write(f"render_manifest: cannot read {args[0]}: {e}\n")
            return 1
    else:
        raw = sys.stdin.read()

    try:
        repos = parse_manifest(raw)
    except ValueError as e:
        sys.stderr.write(f"render_manifest: INVALID manifest: {e}\n")
        return 1

    if serve_root is not None:
        sys.stdout.write(serve_args(repos, serve_root) + "\n")
    elif field:
        if field not in ("subdir", "source", "sig", "ref"):
            sys.stderr.write(f"render_manifest: unknown --field '{field}'\n")
            return 2
        for r in repos:
            sys.stdout.write(r[field] + "\n")
    else:
        for r in repos:
            sys.stdout.write(json.dumps(r, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
