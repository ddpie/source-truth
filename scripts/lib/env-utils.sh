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
      && mv "${env_file}.tmp" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

# safe_source_env <env_file>
#   Load KEY=VALUE pairs into the shell (export). Skips comments, blank lines.
#   No shell expansion on values. Missing file is a no-op (rc 0).
safe_source_env() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key%%[[:space:]]}"
    value="${value#[[:space:]]}"
    export "$key=$value"
  done < "$env_file"
}
