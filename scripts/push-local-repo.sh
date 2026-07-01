#!/usr/bin/env bash
# push-local-repo.sh — push a LOCAL repo from your machine to the source-truth index host, then
# trigger a single-writer-safe reindex. Ingestion path for repos declared {"source":"local"} in
# projects.json (no git remote). Re-run whenever the code changes — that IS the refresh.
#
#   scripts/push-local-repo.sh --host <ssh-host> [--identity <key>] <subdir> <local-path> [--dry-run]
#
# Code is staged to /data/repo/<subdir>.incoming/ (the serving copy is untouched during the network
# transfer), then the host's reindex_local_repo.sh applies it: a SUBSEQUENT push syncs the staged
# tree onto the serving copy in place and the resident watcher re-indexes incrementally (bridge
# stays up); only the FIRST push (no graph yet) stops the bridge for a one-time full build.
#
# SECURITY: we deliberately do NOT expose a free-form --ssh-opts (a `-oProxyCommand=...` there is
# local RCE). Only a vetted --identity keyfile is accepted. <subdir> is regex-validated; it is the
# ONLY thing interpolated into the remote command — keep the regex strict.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"; else say() { local l="$1"; shift; printf '%s\n' "$*"; }; fi

HOST="" IDENTITY="" DRY=false SUBDIR="" LOCAL_PATH=""
usage() { sed -n '2,12p' "$0"; exit "${1:-2}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage 0 ;;
    -*) say err "unknown flag: $1 (note: free-form --ssh-opts is intentionally not supported)"; usage ;;
    *) if [ -z "$SUBDIR" ]; then SUBDIR="$1"; elif [ -z "$LOCAL_PATH" ]; then LOCAL_PATH="$1"; else say err "too many args"; usage; fi; shift ;;
  esac
done

[ -n "$HOST" ] || { say err "--host <ssh-host> required"; usage; }
[ -n "$SUBDIR" ] && [ -n "$LOCAL_PATH" ] || { say err "need <subdir> and <local-path>"; usage; }
printf '%s' "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { say err "subdir must match ^[a-z0-9][a-z0-9-]*$"; exit 2; }
[ -d "$LOCAL_PATH" ] || { say err "local path not a directory: $LOCAL_PATH"; exit 2; }
# Refuse a root / near-root source (a trailing-slash mirror of / would be catastrophic).
REAL="$(cd "$LOCAL_PATH" && pwd -P)"
[ "$REAL" != "/" ] || { say err "refusing to push the filesystem root"; exit 2; }

# Build the ssh argv as an ARRAY (no string-splitting, no -e "...") and only from vetted inputs.
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [ -n "$IDENTITY" ]; then
  [ -f "$IDENTITY" ] || { say err "--identity keyfile not found: $IDENTITY"; exit 2; }
  # rsync 对 -e 字符串只做空白切分 + 双引号分组，不解释 printf %q 的反斜杠转义——
  # 含空格的路径会被切成两截（-e 下面用双引号包每个词，故这里禁掉引号字符本身）。
  case "$IDENTITY" in
    *\"*) say err "--identity path must not contain double quotes"; exit 2 ;;
  esac
  SSH+=(-i "$IDENTITY")
fi

SRC="${REAL%/}/"
STAGE="/data/repo/${SUBDIR}.incoming"
REINDEX="/opt/idx/app/reindex_local_repo.sh"
# --safe-links: drop any symlink that points OUTSIDE the tree; --no-links additionally refuses to
# recreate symlinks at all. Without these, a pushed `x -> /etc` would let the host's root-run build
# index files outside the repo (info leak). --exclude .git keeps VCS metadata out; protect filters
# are belt-and-suspenders (stage has no graph dirs, but if someone points --host at a live dir by
# mistake, --delete still won't strip them).
# -e：rsync 只按空白切词 + 认双引号分组（不解释 %q 的反斜杠转义），所以逐词双引号包裹。
# 词表全部来自本脚本的固定选项 + 已校验的 IDENTITY（上面禁了双引号字符），不会注入。
_SSH_E=""
for _w in "${SSH[@]}"; do _SSH_E+="\"${_w}\" "; done
RSYNC=(rsync -az --delete --safe-links --no-links
  --filter='P .codegraph/' --filter='P .home/' --exclude='.git'
  -e "${_SSH_E% }" "$SRC" "${HOST}:${STAGE}/")
# The host script (run via a SINGLE sudo-authorized entry) creates+owns the stage dir, then later
# does the swap+rebuild. push never runs raw `sudo mkdir/chown` — so sudoers authorizes ONE script.
# Invoke via `bash <script>` (not direct exec) so it works even if the +x bit isn't set yet.
REMOTE_PREPARE="sudo bash ${REINDEX} --prepare ${SUBDIR}"
REMOTE_REINDEX="sudo bash ${REINDEX} ${SUBDIR}"

if [ "$DRY" = true ]; then
  say info "[dry-run] prepare stage: ${SSH[*]} ${HOST} ${REMOTE_PREPARE}"
  say info "[dry-run] ${RSYNC[*]}"
  say info "[dry-run] reindex: ${SSH[*]} ${HOST} ${REMOTE_REINDEX}"
  exit 0
fi

say step "preparing stage ${STAGE} on ${HOST} (via host script)"
"${SSH[@]}" "$HOST" "$REMOTE_PREPARE"
say step "rsync ${SRC} → ${HOST}:${STAGE}"
"${RSYNC[@]}"
say step "triggering host reindex (in-place incremental; first push does a one-time full build)"
"${SSH[@]}" "$HOST" "$REMOTE_REINDEX"
say ok "pushed + reindexed local repo '${SUBDIR}'"
