#!/usr/bin/env bash
# env-utils.sh — shared helpers for managing .env / deploy-config files.
# Source from deploy scripts: source "$(dirname "$0")/lib/env-utils.sh"
# No side effects on source (functions only).

# Each deploy-config contains region-specific instance IDs, subnets and image URIs.
require_deploy_region() {
  local configured="${1:-}" requested="$2"
  if [[ -n "$configured" && "$configured" != "$requested" ]]; then
    printf 'deploy-config belongs to %s, not %s; use a separate checkout for another region.\n' \
      "$configured" "$requested" >&2
    return 2
  fi
}

# validate_projects_config <projects.json> <scripts/lib directory>
# Shared by full and direct project deployment, before either changes the host.
validate_projects_config() {
  python3 - "$1" "$2" <<'PY'
import json
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[2])
from render_manifest import build_multi_manifest

try:
    config = json.loads(Path(sys.argv[1]).read_text())
    projects = config.get("projects") if isinstance(config, dict) else None
    if not isinstance(projects, dict):
        raise ValueError('projects.json requires a "projects" object')
    ports, subdirs = {}, {}
    for pid, project in projects.items():
        manifest = json.loads(build_multi_manifest(
            pid, project["port"], project["repos"], config.get("refreshIntervalSec", 300)
        ))
        port = manifest["port"]
        if port in ports:
            raise ValueError(f"port {port} shared by {ports[port]} and {pid}")
        ports[port] = pid
        for repo in manifest["repos"]:
            subdir = repo["subdir"]
            if subdir in subdirs:
                raise ValueError(f"subdir {subdir} shared by {subdirs[subdir]} and {pid}")
            subdirs[subdir] = pid
except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
    sys.exit(f"invalid project configuration: {error}")
PY
}

# update_env <env_file> <key> <value>
#   Upsert a single KEY=VALUE line. Preserves all other lines.
#   Serialize read/modify/replace across deploy processes; values are literal.
update_env() {
  python3 - "$1" "$2" "$3" <<'PY'
import fcntl
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) or any(c in value for c in "\r\n"):
    sys.exit("update_env requires an identifier and a single-line value")
# Lock a separate inode: locking the file being replaced would let a waiter
# continue on the old inode while the next writer locks the replacement.
with open(str(path) + ".lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    lines = path.read_text().splitlines() if path.exists() else []
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    output, found = [], False
    for line in lines:
        if line.partition("=")[0].strip() == key:
            if not found:
                output.append(f"{key}={value}")
            found = True
        else:
            output.append(line)
    if not found:
        output.append(f"{key}={value}")
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write("\n".join(output) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
}

# safe_source_env <env_file>
#   Load KEY=VALUE pairs into the shell (export). Skips comments, blank lines,
#   whitespace-only lines, and any line whose key isn't a valid identifier —
#   so an operator's stray indentation / blank line / CRLF save never aborts the
#   deploy (callers run under `set -euo pipefail`). No shell expansion on values.
#   Strips surrounding whitespace AND a trailing CR (CRLF-saved configs would
#   otherwise inject \r into REGION/ARN/bucket values fed to the AWS CLI).
#   Missing file is a no-op (rc 0).
safe_source_env() {
  local env_file="$1" line key value
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # drop trailing CR (CRLF files)
    [[ "$line" != *"="* ]] && continue         # no '=' → not a KEY=VALUE line
    key="${line%%=*}"
    value="${line#*=}"
    # Trim leading/trailing whitespace (runs, both ends) from the key.
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    # Skip blanks, comments, and anything that isn't a valid shell identifier —
    # never feed `export` a bad name (it would return nonzero and, if it's the
    # last line, fail the function under set -e).
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Trim a single leading space after '=' (the value side keeps internal
    # spaces verbatim; machine-written configs have none).
    value="${value# }"
    export "$key=$value"
  done < "$env_file"
  return 0
}
