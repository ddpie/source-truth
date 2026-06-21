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


def parse_repos_spec(specs):
    """Parse multi-repo `--repos` CLI specs into (subdir, source, ref) rows for deploy staging.

    Each spec is ``<subdir>=<source>[@<ref>]`` (ref optional, git branch/tag/commit):
      code-5x=/path/to/code-5x
      client=https://github.com/org/client.git@main
      cfg=s3://bucket/cfg.tar.gz
    The subdir (LHS) is the on-host name → charset-validated against SUBDIR_RE (it becomes a
    user/path/unit name). The source (RHS) is passed verbatim to fetch_repo_source (which
    classifies local/git/s3). ``@<ref>`` is split off the RIGHT (an S3/HTTPS URL has no '@',
    but a git scp URL like git@host:org/repo CAN — so only treat a trailing '@token' as a ref
    when the token looks like a ref, i.e. it contains no ':' or '/'; otherwise it's part of the
    source). Raises ValueError (fail-loud) on a malformed/empty spec, a bad subdir, or a dup.

    Returns a list of (subdir, source, ref) tuples in CLI order.
    """
    seen = set()
    rows = []
    for spec in specs:
        if not isinstance(spec, str) or "=" not in spec:
            raise ValueError(f"--repos entry must be <subdir>=<source>[@<ref>]: {spec!r}")
        subdir, rhs = spec.split("=", 1)
        subdir = subdir.strip()
        rhs = rhs.strip()
        if not REPO_NAME_OK(subdir):
            raise ValueError(
                f"--repos subdir {subdir!r} must match {SUBDIR_RE.pattern} "
                f"(it becomes a user/path/unit name — no slashes, spaces, dots, or metachars)")
        if subdir in seen:
            raise ValueError(f"--repos duplicate subdir {subdir!r} (would share graph.db/HOME → corruption)")
        if not rhs:
            raise ValueError(f"--repos entry {spec!r} has an empty source")
        # Split a trailing @ref only when it's ref-shaped (no ':' or '/'), so a git scp
        # source (git@host:org/repo) keeps its '@' but `...repo.git@v1.2` yields ref=v1.2.
        ref = ""
        source = rhs
        at = rhs.rfind("@")
        if at > 0:
            tail = rhs[at + 1:]
            if tail and ":" not in tail and "/" not in tail:
                source = rhs[:at]
                ref = tail
        if not source:
            raise ValueError(f"--repos entry {spec!r} has an empty source (after stripping @ref)")
        seen.add(subdir)
        rows.append((subdir, source, ref))
    if not rows:
        raise ValueError("--repos given but no valid entries parsed")
    return rows


def REPO_NAME_OK(name) -> bool:  # noqa: N802 - shouty to read like a guard at call sites
    return isinstance(name, str) and bool(SUBDIR_RE.match(name))


def build_manifest(rows) -> str:
    """Build a REPO_MANIFEST_JSON string from (subdir, source, sig) rows — the ONE authority
    for manifest construction (deploy/provision call this instead of hand-rolling json.dumps,
    so a bad subdir/source fails LOUD at deploy via the SAME parse_manifest the instance uses,
    not silently later at bootstrap). `rows` is an iterable of (subdir, source, sig) tuples.

    Round-trips through parse_manifest: build the dict, dump it, RE-PARSE to validate, and
    return the canonical dump. Raises ValueError (fail-loud) on any invalid row.
    """
    repos = []
    for subdir, source, sig in rows:
        entry = {"subdir": subdir, "source": source}
        if sig:
            entry["sig"] = sig
        repos.append(entry)
    raw = json.dumps({"repos": repos})
    parse_manifest(raw)  # VALIDATE (raises ValueError on bad subdir/dup/empty source/...)
    return raw


def main(argv):
    # Read the manifest from argv[1] (a path) or stdin; --field <name> prints just that column
    # one-per-line (for a shell `for subdir in $(... --field subdir)` loop); --serve-args
    # <local_root> prints the bridge serve unit's --workspace/--local-workspace argv;
    # --build reads TAB-separated `subdir<TAB>source<TAB>sig` rows from stdin and emits a
    # validated REPO_MANIFEST_JSON (the single manifest-construction authority).
    field = None
    serve_root = None
    build = False
    parse_spec = []  # --repos <subdir=source[@ref]> ... → emit TAB rows for the deploy loop
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == "--field" and i + 1 < len(argv):
            field = argv[i + 1]
            i += 2
        elif argv[i] == "--serve-args" and i + 1 < len(argv):
            serve_root = argv[i + 1]
            i += 2
        elif argv[i] == "--build":
            build = True
            i += 1
        elif argv[i] == "--parse-spec":
            # all following args are repo specs (consumed to end)
            parse_spec = argv[i + 1:]
            i = len(argv)
        else:
            args.append(argv[i])
            i += 1

    if parse_spec:
        try:
            rows = parse_repos_spec(parse_spec)
        except ValueError as e:
            sys.stderr.write(f"render_manifest --parse-spec: {e}\n")
            return 1
        for subdir, source, ref in rows:
            sys.stdout.write(f"{subdir}\t{source}\t{ref}\n")
        return 0

    if build:
        rows = []
        for line in sys.stdin:
            line = line.rstrip("\n")
            if not line:
                continue
            cols = line.split("\t")
            if len(cols) < 2:
                sys.stderr.write(f"render_manifest --build: row needs subdir<TAB>source[<TAB>sig]: {line!r}\n")
                return 2
            subdir, source = cols[0], cols[1]
            sig = cols[2] if len(cols) > 2 else ""
            rows.append((subdir, source, sig))
        try:
            sys.stdout.write(build_manifest(rows) + "\n")
        except ValueError as e:
            sys.stderr.write(f"render_manifest --build: INVALID manifest: {e}\n")
            return 1
        return 0

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
