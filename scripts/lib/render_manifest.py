#!/usr/bin/env python3
"""render_manifest.py — validate REPO_MANIFEST_JSON and emit per-repo records.

Pure + side-effect free. A project's repo set is described in ONE JSON value, deliberately NOT a
set of shell variables — a git URL / ref can contain characters (`@`, `:`) that a naked sourced
env file would mangle, and the project hit `|`-in-env crashes twice before adopting one JSON var.
So bootstrap reads ONE `REPO_MANIFEST_JSON` and calls this to validate + iterate.

Manifest shape (single-host multi-project; per-repo source is git or local):
    { "projectId": "<id>", "port": <int>,
      "repos": [ { "subdir": "<name>", "source": "git"|"local"(opt, default git),
                   "git": "<git url>"(git only), "ref": "<branch/tag?>"(git only),
                   "refreshIntervalSec": <int?> }, ... ] }

Validation (fail-loud — a bad manifest must crash the deploy up front, never half-provision):
  - `projectId` matches ^[a-z0-9][a-z0-9-]*$ (it becomes a systemd instance / path / metric dim);
  - `port` present and an integer (the bridge's listen port; one per project, host-unique);
  - non-empty `repos` array;
  - each `subdir` matches ^[a-z0-9-]+$ (it becomes a useradd name / path / systemd unit /
    pgrep pattern — an unchecked name is a privileged-config injection);
  - `subdir` unique (two repos sharing a subdir would share graph.db/HOME → corruption);
  - `source` optional, one of git|local (default git); a `local` repo is pushed via
    scripts/push-local-repo.sh (no git remote), so its `git` is forced to "";
  - `git` present and non-empty for a git-source repo; absent/"" for a local one;
  - `ref` optional (defaults to "" → clone default branch);
  - `refreshIntervalSec` optional, integer if present (per-repo and top-level).

Emits one NDJSON record per repo on stdout: {"subdir","git","ref","sig","refreshIntervalSec"}.
`--field <name>` prints a top-level scalar (projectId/port) or a per-repo column for a shell loop;
`--repo-field <name> <subdir>` prints one repo's field; `--serve-args <root>` prints the bridge
serve unit's --workspace/--local-workspace argv.
"""
import json
import re
import sys

# \A…\Z anchors the WHOLE string — NOT ^…$, whose $ also matches just before a trailing
# newline, so "code-5x\n" would slip through and carry a newline into useradd/path/unit/pgrep
# (cross-review CRITICAL). Must start with an alphanumeric (no leading '-'), or a name like
# "-rf" becomes a CLI option flag instead of a value (option injection, cross-review MEDIUM).
SUBDIR_RE = re.compile(r"\A[a-z0-9][a-z0-9-]*\Z")
# projectId is also a systemd instance name (index-bridge@<id>) / path segment / metric dim.
PROJECT_ID_RE = SUBDIR_RE


def parse_manifest(raw: str):
    """Parse + validate a REPO_MANIFEST_JSON string. Returns the list of repo dicts
    (each {subdir, git, ref, sig, refreshIntervalSec}). Raises ValueError on any problem.

    The top-level projectId/port are validated here too (fail-loud), but parse_manifest returns
    only the repo list; callers that need the scalars read them via parse_top() / --field."""
    obj = _load_obj(raw)
    _validate_top(obj)

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
        source = r.get("source", "git")
        if source not in ("git", "local"):
            raise ValueError(f"{where}: 'source' must be 'git' or 'local' (got {source!r})")
        git = r.get("git")
        if source == "git":
            if not isinstance(git, str) or not git.strip():
                raise ValueError(f"{where}: 'git' must be a non-empty git URL for a git-source repo")
        else:  # local: pushed via rsync (push-local-repo.sh), no git remote
            if git is not None and not isinstance(git, str):
                raise ValueError(f"{where}: 'git' must be a string if present")
            git = ""
        ref = r.get("ref")
        if ref is not None and not isinstance(ref, str):
            raise ValueError(f"{where}: 'ref' must be a string if present")
        sig = r.get("sig")
        if sig is not None and not isinstance(sig, str):
            raise ValueError(f"{where}: 'sig' must be a string if present")
        interval = r.get("refreshIntervalSec")
        if interval is not None and not isinstance(interval, int):
            raise ValueError(f"{where}: 'refreshIntervalSec' must be an integer seconds if present")
        out.append({"subdir": subdir, "source": source, "git": git, "ref": ref or "",
                    "sig": sig or "", "refreshIntervalSec": interval})
    return out


def parse_top(raw: str):
    """Return the validated top-level scalars {projectId, port, refreshIntervalSec}.
    Validates the whole manifest (incl. repos) so a --field projectId never reports a bad
    manifest as fine."""
    obj = _load_obj(raw)
    _validate_top(obj)
    parse_manifest(raw)  # full repo validation too (fail-loud regardless of which field is asked)
    return {"projectId": obj["projectId"], "port": obj["port"],
            "refreshIntervalSec": obj.get("refreshIntervalSec")}


def _load_obj(raw: str):
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError) as e:
        raise ValueError(f"REPO_MANIFEST_JSON is not valid JSON: {e}")
    if not isinstance(obj, dict):
        raise ValueError("manifest must be a JSON object")
    return obj


def _validate_top(obj):
    pid = obj.get("projectId")
    if not isinstance(pid, str) or not PROJECT_ID_RE.match(pid):
        raise ValueError(
            f"manifest.projectId {pid!r} must match {PROJECT_ID_RE.pattern} "
            f"(it becomes a systemd instance / path / metric dimension)")
    port = obj.get("port")
    if not isinstance(port, int) or isinstance(port, bool):
        raise ValueError("manifest.port must be an integer (the bridge listen port, host-unique)")
    top_interval = obj.get("refreshIntervalSec")
    if top_interval is not None and not isinstance(top_interval, int):
        raise ValueError("manifest.refreshIntervalSec must be an integer seconds if present")


def serve_args(repos, local_root: str) -> str:
    """Build the bridge serve unit's --workspace/--local-workspace argv.

    The serve side is ONE bridge process loading every repo of THIS project (the design's
    per-project process topology), so its ExecStart needs a `--workspace <dir> --local-workspace
    <dir>` pair PER repo. Each repo lives at ``<local_root>/<subdir>`` on the index host. Emitting
    this here (not assembled in shell) keeps the corruption-critical bootstrap thin and makes the
    arg construction unit-testable.

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


def build_multi_manifest(project_id: str, port: int, repos, default_interval=None) -> str:
    """Build a per-project REPO_MANIFEST_JSON — the ONE authority for manifest construction
    (deploy/provision call this instead of hand-rolling json.dumps, so a bad subdir/git/port
    fails LOUD at deploy via the SAME parse_manifest the instance uses, not silently later at
    bootstrap). `repos` is an iterable of dicts each with subdir + git (+ optional ref/
    refreshIntervalSec). A per-repo interval falls back to default_interval.

    Round-trips through parse_manifest to validate, and returns the canonical dump. Raises
    ValueError (fail-loud) on any invalid input.
    """
    if not isinstance(port, int) or isinstance(port, bool):
        raise ValueError(f"port must be an integer, got {port!r}")
    out_repos = []
    for r in repos:
        src = r.get("source", "git")
        entry = {"subdir": r["subdir"], "source": src}
        if src == "git":
            entry["git"] = r["git"]
            entry["ref"] = r.get("ref") or ""
        iv = r.get("refreshIntervalSec")
        entry["refreshIntervalSec"] = iv if isinstance(iv, int) else default_interval
        out_repos.append(entry)
    body = {"projectId": project_id, "port": port, "repos": out_repos}
    if default_interval is not None:
        body["refreshIntervalSec"] = default_interval
    raw = json.dumps(body)
    parse_manifest(raw)  # VALIDATE (raises ValueError on bad subdir/dup/empty git/bad port/...)
    return raw


def main(argv):
    # Read the manifest from a path arg or stdin.
    #   --field <name>           : print a top-level scalar (projectId/port) OR a per-repo column
    #                              (subdir/git/ref/sig/refreshIntervalSec) one-per-line.
    #   --repo-field <name> <sub>: print one repo's field (by subdir).
    #   --serve-args <root>      : print the bridge serve unit's --workspace/--local-workspace argv.
    field = None
    repo_field = None      # (name, subdir)
    serve_root = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == "--field" and i + 1 < len(argv):
            field = argv[i + 1]
            i += 2
        elif argv[i] == "--repo-field" and i + 2 < len(argv):
            repo_field = (argv[i + 1], argv[i + 2])
            i += 3
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

    TOP_FIELDS = ("projectId", "port")
    REPO_FIELDS = ("subdir", "source", "git", "ref", "sig", "refreshIntervalSec")

    try:
        repos = parse_manifest(raw)
    except ValueError as e:
        sys.stderr.write(f"render_manifest: INVALID manifest: {e}\n")
        return 1

    if serve_root is not None:
        sys.stdout.write(serve_args(repos, serve_root) + "\n")
        return 0

    if repo_field is not None:
        name, subdir = repo_field
        if name not in REPO_FIELDS:
            sys.stderr.write(f"render_manifest: unknown --repo-field '{name}'\n")
            return 2
        match = next((r for r in repos if r["subdir"] == subdir), None)
        if match is None:
            sys.stderr.write(f"render_manifest: no repo with subdir '{subdir}'\n")
            return 2
        val = match[name]
        sys.stdout.write(("" if val is None else str(val)) + "\n")
        return 0

    if field is not None:
        if field in TOP_FIELDS:
            top = parse_top(raw)
            sys.stdout.write(str(top[field]) + "\n")
            return 0
        if field in REPO_FIELDS:
            for r in repos:
                val = r[field]
                sys.stdout.write(("" if val is None else str(val)) + "\n")
            return 0
        sys.stderr.write(f"render_manifest: unknown --field '{field}'\n")
        return 2

    for r in repos:
        sys.stdout.write(json.dumps(r, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
