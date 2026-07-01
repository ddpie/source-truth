#!/usr/bin/env bash
# env-utils.sh — shared helpers for managing .env / deploy-config files.
# Source from deploy scripts: source "$(dirname "$0")/lib/env-utils.sh"
# No side effects on source (functions only).

# update_env <env_file> <key> <value>
#   Upsert a single KEY=VALUE line. Preserves all other lines.
#   Safe with special chars in value (awk, no sed delimiter issues).
update_env() {
  local env_file="$1" key="$2" value="$3"
  if [[ -f "$env_file" ]] && grep -q "^${key}=" "$env_file"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} 1' "$env_file" > "${env_file}.tmp" \
      && command mv -f "${env_file}.tmp" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
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
