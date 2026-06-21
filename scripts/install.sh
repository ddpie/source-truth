#!/usr/bin/env bash
# install.sh — interactive one-click installer for source-truth (customer AWS account).
#
# A friendly front-end over deploy-all.sh: it checks dependencies, collects the few
# things only a human knows (region, code-repo source, Feishu app credentials),
# stores the Feishu credentials in AWS Secrets Manager, confirms the plan, then runs
# the (idempotent) deploy. Re-runs PRE-FILL every answer from the last run
# (.local/deploy-config), so an upgrade/redeploy is just "Enter through the prompts".
#
# Flow (mirrors the reference installer ddpie/lark-mcp-on-agentcore):
#   check deps → AWS identity → region / repo / model → Feishu credentials
#   → write secret → confirm → deploy-all.sh
#
# Non-interactive: pass --yes to accept all pre-filled/default answers (CI/headless).
# Anything not pre-fillable without a human (first-run Feishu secret) still hard-stops.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env-utils.sh"

CONFIG_FILE="$ROOT/.local/deploy-config"
ASSUME_YES=false
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/install.sh [--yes]

Interactive installer. Prompts (arrow-key ↑/↓ menus for region / model / index-host
machine spec / disk size; free text for repo source + Feishu credentials), stores
credentials in Secrets Manager, then runs deploy-all.sh. Re-runs pre-fill from
.local/deploy-config (the persisted value is pre-selected in each menu).

  --yes   Accept all pre-filled/default answers without prompting (headless).
EOF
      exit 0 ;;
  esac
done

# ---- tiny prompt helpers -------------------------------------------------------
# ask <var> <prompt> <default> : read a value, showing the default in [brackets];
# empty input keeps the default. In --yes mode, takes the default with no prompt.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ "$ASSUME_YES" == true ]]; then
    printf -v "$__var" '%s' "$__default"; return
  fi
  if [[ -n "$__default" ]]; then
    read -rp "$(printf '%s [%s]: ' "$__prompt" "$__default")" __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    read -rp "$(printf '%s: ' "$__prompt")" __reply || true
    printf -v "$__var" '%s' "$__reply"
  fi
}

# ask_secret <var> <prompt> : read WITHOUT echo (credentials never on screen).
ask_secret() {
  local __var="$1" __prompt="$2" __reply
  read -rsp "$(printf '%s: ' "$__prompt")" __reply || true
  echo >&2
  printf -v "$__var" '%s' "$__reply"
}

# confirm <prompt> : y/N. --yes mode auto-confirms.
confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local __reply
  read -rp "$(printf '%s [y/N]: ' "$1")" __reply || true
  [[ "$__reply" =~ ^[Yy] ]]
}

# Sentinel for the last menu entry: fall through to a free-text prompt for a value
# not in the list (region/model can be anything; the menu just covers common ones).
MANUAL_SENTINEL="↳ 手动输入其他 / enter manually"

# pick <var> <default_index> <item...> : arrow-key menu (mirrors the reference
# installer's picker). ↑/↓ move, Enter selects; sets <var> to the chosen LABEL line.
# Falls back to the default item with no UI when headless (--yes) or no controlling
# TTY, so CI never blocks on a key read.
pick() {
  local __var="$1" __def="${2:-0}"; shift 2
  local -a __it=("$@")
  local __n=${#__it[@]} __sel="$__def" __key __rest i
  if [[ "$ASSUME_YES" == true || ! -e /dev/tty || ! -t 1 ]]; then
    printf -v "$__var" '%s' "${__it[$__def]}"; return
  fi
  # Clamp via `if` (NOT `(( … )) && …`): under `set -e` a false (( )) as the last
  # command of a branch aborts the whole script — the exact trap documented in
  # deploy-all.sh's preflight_quota.
  if (( __sel < 0 || __sel >= __n )); then __sel=0; fi
  _pick_draw() {
    for ((i = 0; i < __n; i++)); do
      if (( i == __sel )); then
        printf '\033[36m  ❯ %s\033[0m\n' "${__it[$i]}" >/dev/tty
      else
        printf '    %s\n'               "${__it[$i]}" >/dev/tty
      fi
    done
  }
  printf '\033[?25l' >/dev/tty            # hide cursor
  # Restore the cursor on Ctrl-C and bail with the conventional 130, so an aborted
  # install never leaves the terminal with a hidden cursor.
  trap 'printf "\033[?25h" >/dev/tty; exit 130' INT
  _pick_draw
  while IFS= read -rsn1 __key </dev/tty; do
    if [[ "$__key" == $'\x1b' ]]; then
      read -rsn2 __rest </dev/tty || true
      case "$__rest" in
        '[A') __sel=$(( (__sel - 1 + __n) % __n )) ;;   # assignment form always
        '[B') __sel=$(( (__sel + 1) % __n )) ;;          # returns 0 — set -e safe
        *) continue ;;
      esac
    elif [[ -z "$__key" || "$__key" == $'\n' ]]; then
      break
    else
      continue
    fi
    printf '\033[%dA' "$__n" >/dev/tty    # cursor back up to redraw in place
    _pick_draw
  done
  printf '\033[?25h' >/dev/tty            # show cursor
  trap - INT
  printf -v "$__var" '%s' "${__it[$__sel]}"
}

# index_of_token <token> <item...> : 0-based index of the first item whose leading
# whitespace-delimited token == <token>, else -1. Used to pre-select the persisted
# value when re-running (so an upgrade keeps the prior choice highlighted).
index_of_token() {
  local want="$1"; shift
  local i=0 it
  for it in "$@"; do
    if [[ "${it%%[[:space:]]*}" == "$want" ]]; then echo "$i"; return; fi
    i=$((i + 1))
  done
  echo -1
}

# pick_field <outvar> <header> <persisted> <manual-prompt> <item...>
# Show <header>, then an arrow-key menu whose LAST item is MANUAL_SENTINEL. Sets
# <outvar> to the chosen line's leading token (e.g. region code / instance type),
# or to free text if the manual entry is chosen. Honors the --yes "keep persisted"
# contract: headless with a persisted value takes it verbatim (even if off-menu).
pick_field() {
  local __out="$1" __header="$2" __persist="$3" __manual="$4"; shift 4
  local -a __items=("$@")
  if [[ "$ASSUME_YES" == true && -n "$__persist" ]]; then
    printf -v "$__out" '%s' "$__persist"; return
  fi
  echo "  $__header"
  local __def
  __def="$(index_of_token "$__persist" "${__items[@]}")"
  if (( __def < 0 )); then __def=0; fi
  local __chosen
  pick __chosen "$__def" "${__items[@]}"
  if [[ "$__chosen" == "$MANUAL_SENTINEL" ]]; then
    ask "$__out" "$__manual" "$__persist"
  else
    printf -v "$__out" '%s' "${__chosen%%[[:space:]]*}"
  fi
}

# --- menu option lists (label = leading token IS the value; trailing text is help) ---
REGION_OPTIONS=(
  "ap-northeast-1   Tokyo 东京"
  "ap-southeast-1   Singapore 新加坡"
  "us-east-1        Virginia 弗吉尼亚"
  "us-west-2        Oregon 俄勒冈"
  "$MANUAL_SENTINEL"
)
MODEL_OPTIONS=(
  "global.anthropic.claude-opus-4-8   Opus 4.8 (global profile，默认)"
  "apac.anthropic.claude-opus-4-8     Opus 4.8 (APAC profile)"
  "us.anthropic.claude-opus-4-8       Opus 4.8 (US profile)"
  "$MANUAL_SENTINEL"
)
# index-service host (ARM Graviton). codegraph indexing is memory-bound and scales
# with repo size; t4g = burstable/cheap, m7g = sustained memory-optimized for big repos.
INSTANCE_OPTIONS=(
  "t4g.large     2 vCPU /  8 GiB   小中仓·默认"
  "t4g.xlarge    4 vCPU / 16 GiB   中大仓"
  "m7g.large     2 vCPU /  8 GiB   稳定性能"
  "m7g.xlarge    4 vCPU / 16 GiB   大仓·稳定"
  "m7g.2xlarge   8 vCPU / 32 GiB   超大仓/多仓"
)
# Root gp3 volume: holds the repo copy + graph.db + staged tarball.
DISK_OPTIONS=(
  "30   GiB   小中仓·默认"
  "50   GiB"
  "100  GiB   大仓"
  "200  GiB   超大仓/多仓"
  "$MANUAL_SENTINEL"
)

echo
say step "source-truth installer"
echo "  把项目最新主分支的真实代码，变成飞书里能问的 AI 助手。"
echo "  This installer deploys the full backend + Feishu gateway into your AWS account."
echo

# ---- 1. dependency check -------------------------------------------------------
say step "1/5 检查依赖 / Checking dependencies"
DEPS_OK=true
for c in aws python3 docker git; do
  if have_cmd "$c"; then
    say ok "$c"
  else
    say err "$c 缺失 / missing"
    DEPS_OK=false
  fi
done
if [[ "$DEPS_OK" != true ]]; then
  say err "请先安装缺失的依赖再重试 / install the missing tools and re-run."
  say info "  aws CLI v2, python3, docker (ARM64-capable buildx), git"
  exit 1
fi
# AWS identity (also proves credentials work before we collect anything).
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  say err "AWS 凭证无效 / AWS credentials not working — run 'aws configure' or set AWS_PROFILE."
  exit 1
fi
say ok "AWS account: $ACCOUNT"

# Pre-fill defaults from the last run, if any.
safe_source_env "$CONFIG_FILE"

# ---- 2. core config ------------------------------------------------------------
echo
say step "2/5 部署配置 / Deployment config"
# Region: arrow-key menu of common regions (+ manual entry). Pre-selects the
# persisted region on a re-run; defaults to Tokyo on first run.
pick_field REGION "AWS 区域 / region (↑/↓ 选择，回车确认)" \
  "${DEPLOY_REGION:-ap-northeast-1}" "AWS 区域代码 / region code" "${REGION_OPTIONS[@]}"

# Repo source / git ref / Feishu creds can't be enumerated — keep them as free text.
ask REPO_SRC     "代码仓库 (本地路径 / git URL / s3://) / repo source" "${INSTALL_REPO_SRC:-}"
while [[ -z "$REPO_SRC" ]]; do
  # In --yes (non-interactive) mode `ask` never blocks, so an empty repo with no
  # pre-fill would loop forever — hard-fail instead of spinning.
  if [[ "$ASSUME_YES" == true ]]; then
    say err "代码仓库未提供且无可预填值 / repo source required but none provided (headless mode)."
    exit 1
  fi
  say warn "代码仓库不能为空 / repo source is required."
  ask REPO_SRC   "代码仓库 (本地路径 / git URL / s3://) / repo source" ""
done
# Offer --repo-ref only for git sources.
REPO_REF=""
case "$REPO_SRC" in
  *.git|git@*|ssh://*|git://*|https://github.com/*|https://gitlab.com/*|https://bitbucket.org/*)
    ask REPO_REF "git 分支/标签/提交（留空=默认分支）/ git ref (blank=default)" "${INSTALL_REPO_REF:-}" ;;
esac

# Model: arrow-key menu of common Bedrock Opus profiles (+ manual entry).
pick_field MODEL "Bedrock 模型 / model (↑/↓ 选择，回车确认)" \
  "${DEPLOY_MODEL:-global.anthropic.claude-opus-4-8}" "Bedrock 模型 id / model id" "${MODEL_OPTIONS[@]}"

# Index host machine spec (CPU/memory) — arrow-key menu. The leading token is the
# EC2 instance type passed straight to deploy-all.sh's --instance-type.
pick_field INSTANCE_TYPE "索引主机机型 (ARM·决定 CPU/内存) / index host type (↑/↓，回车)" \
  "${DEPLOY_INSTANCE_TYPE:-t4g.large}" "EC2 机型 (ARM) / instance type" "${INSTANCE_OPTIONS[@]}"

# Root disk (gp3) size in GiB — arrow-key menu (+ manual entry for any size).
pick_field ROOT_VOLUME_GB "索引主机磁盘 / index host disk GiB (↑/↓，回车)" \
  "${DEPLOY_ROOT_VOLUME_GB:-30}" "磁盘大小 GiB / disk size in GiB" "${DISK_OPTIONS[@]}"
# Validate a manually-entered disk size: deploy-all passes this straight to
# run-instances; a non-integer would surface as an opaque EC2 error minutes later.
while ! [[ "$ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] || (( ROOT_VOLUME_GB < 8 )); do
  if [[ "$ASSUME_YES" == true ]]; then
    say err "磁盘大小无效 / invalid disk size: '$ROOT_VOLUME_GB' (需要 ≥8 的整数 GiB)."
    exit 1
  fi
  say warn "磁盘大小需为 ≥8 的整数 GiB / disk size must be an integer GiB ≥ 8."
  ask ROOT_VOLUME_GB "磁盘大小 GiB / disk size in GiB" "30"
done

# ---- 3. Feishu credentials → Secrets Manager -----------------------------------
echo
say step "3/5 飞书应用凭证 / Feishu app credentials"
SECRET_NAME="${FEISHU_SECRET_ID:-source-truth/feishu-app}"
HAS_SECRET=false
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  HAS_SECRET=true
  say info "已存在密钥 / secret exists: $SECRET_NAME"
fi
UPDATE_SECRET=true
if [[ "$HAS_SECRET" == true ]]; then
  if [[ "$ASSUME_YES" == true ]]; then
    UPDATE_SECRET=false   # keep existing creds on headless re-run
  else
    confirm "更新飞书凭证？(否=沿用现有) / update Feishu credentials? (no=keep existing)" || UPDATE_SECRET=false
  fi
fi
if [[ "$UPDATE_SECRET" == true ]]; then
  ask        FEISHU_APP_ID      "飞书 App ID"        "${FEISHU_APP_ID:-}"
  ask_secret FEISHU_APP_SECRET  "飞书 App Secret（输入不回显）/ (hidden)"
  ask        FEISHU_BOT_OPEN_ID "机器人 open_id（可留空）/ bot open_id (optional)" "${FEISHU_BOT_OPEN_ID:-}"
  if [[ -z "$FEISHU_APP_ID" || -z "$FEISHU_APP_SECRET" ]]; then
    say err "App ID 和 App Secret 必填 / App ID and App Secret are required."
    exit 1
  fi
fi

# ---- 4. confirm ----------------------------------------------------------------
echo
say step "4/5 确认 / Confirm"
echo "  AWS account : $ACCOUNT"
echo "  region      : $REGION"
echo "  repo        : $REPO_SRC${REPO_REF:+  (ref: $REPO_REF)}"
echo "  model       : $MODEL"
echo "  index host  : $INSTANCE_TYPE  (disk ${ROOT_VOLUME_GB} GiB gp3)"
echo "  Feishu secret: $SECRET_NAME ($([[ "$UPDATE_SECRET" == true ]] && echo '将写入/update' || echo '沿用/keep'))"
echo
if ! confirm "开始部署？/ Start deployment now?"; then
  say info "已取消。配置已记住，下次运行会预填。/ Cancelled — answers remembered for next run."
  # Persist the non-secret choices so a later run pre-fills even after a cancel.
  # (deploy-all.sh persists these when it actually runs; on a cancel it never does,
  # so mirror the menu choices here too — region/model/spec/disk all pre-select.)
  update_env "$CONFIG_FILE" DEPLOY_REGION "$REGION"
  update_env "$CONFIG_FILE" DEPLOY_MODEL "$MODEL"
  update_env "$CONFIG_FILE" DEPLOY_INSTANCE_TYPE "$INSTANCE_TYPE"
  update_env "$CONFIG_FILE" DEPLOY_ROOT_VOLUME_GB "$ROOT_VOLUME_GB"
  update_env "$CONFIG_FILE" INSTALL_REPO_SRC "$REPO_SRC"
  [[ -n "$REPO_REF" ]] && update_env "$CONFIG_FILE" INSTALL_REPO_REF "$REPO_REF"
  exit 0
fi

# Write/return the secret (JSON the gateway's run.sh expects). Pass the values via
# ENVIRONMENT, not argv: process arguments are world-readable on Linux
# (/proc/<pid>/cmdline, `ps auxww`), so an App Secret in argv leaks to any local
# user for the lifetime of the python process (cross-review HIGH). Env vars of a
# process are not exposed in cmdline and python is install.sh's direct child.
if [[ "$UPDATE_SECRET" == true ]]; then
  SECRET_JSON="$(_AID="$FEISHU_APP_ID" _ASEC="$FEISHU_APP_SECRET" _BOID="${FEISHU_BOT_OPEN_ID:-}" python3 -c '
import os, json
print(json.dumps({"app_id": os.environ["_AID"], "app_secret": os.environ["_ASEC"], "bot_open_id": os.environ.get("_BOID", "")}))
')"
  if [[ "$HAS_SECRET" == true ]]; then
    aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
      --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
  else
    aws secretsmanager create-secret --name "$SECRET_NAME" \
      --description "source-truth Feishu app credentials (app_id/app_secret/bot_open_id)" \
      --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
  fi
  unset FEISHU_APP_SECRET SECRET_JSON   # don't keep the plaintext around
  say ok "Feishu 凭证已写入 Secrets Manager / stored in Secrets Manager: $SECRET_NAME"
fi

# Persist what deploy-all + the gateway phase need to read back.
update_env "$CONFIG_FILE" FEISHU_SECRET_ID "$SECRET_NAME"
update_env "$CONFIG_FILE" INSTALL_REPO_SRC "$REPO_SRC"
[[ -n "$REPO_REF" ]] && update_env "$CONFIG_FILE" INSTALL_REPO_REF "$REPO_REF"

# ---- 5. deploy -----------------------------------------------------------------
echo
say step "5/5 部署 / Deploying (this can take several minutes)"
DEPLOY_ARGS=(--region "$REGION" --repo "$REPO_SRC" --model "$MODEL" \
  --instance-type "$INSTANCE_TYPE" --root-volume-gb "$ROOT_VOLUME_GB")
[[ -n "$REPO_REF" ]] && DEPLOY_ARGS+=(--repo-ref "$REPO_REF")
say info "exec: ./scripts/deploy-all.sh ${DEPLOY_ARGS[*]}"
exec "$SCRIPT_DIR/deploy-all.sh" "${DEPLOY_ARGS[@]}"
