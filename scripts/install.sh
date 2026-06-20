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

Interactive installer. Prompts for AWS region, code-repo source, model, and Feishu
app credentials; stores credentials in Secrets Manager; then runs deploy-all.sh.
Re-runs pre-fill from .local/deploy-config.

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
ask REGION       "AWS 区域 / region"                    "${DEPLOY_REGION:-ap-northeast-1}"
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
ask MODEL        "Bedrock 模型 / model"                 "${DEPLOY_MODEL:-global.anthropic.claude-opus-4-8}"
ask INSTANCE_TYPE "索引主机机型 (ARM) / index host type" "${DEPLOY_INSTANCE_TYPE:-t4g.large}"

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
echo "  index host  : $INSTANCE_TYPE"
echo "  Feishu secret: $SECRET_NAME ($([[ "$UPDATE_SECRET" == true ]] && echo '将写入/update' || echo '沿用/keep'))"
echo
if ! confirm "开始部署？/ Start deployment now?"; then
  say info "已取消。配置已记住，下次运行会预填。/ Cancelled — answers remembered for next run."
  # Persist the non-secret choices so a later run pre-fills even after a cancel.
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
DEPLOY_ARGS=(--region "$REGION" --repo "$REPO_SRC" --model "$MODEL" --instance-type "$INSTANCE_TYPE")
[[ -n "$REPO_REF" ]] && DEPLOY_ARGS+=(--repo-ref "$REPO_REF")
say info "exec: ./scripts/deploy-all.sh ${DEPLOY_ARGS[*]}"
exec "$SCRIPT_DIR/deploy-all.sh" "${DEPLOY_ARGS[@]}"
