#!/usr/bin/env bash
# activate_gateway.sh <region> <instance_id> <runtime_arn> <feishu_secret_id> [locale] [log_hash_salt] [feishu_api_base]
#
# Writes /etc/bot-gateway.env on the index-service host (which also runs the
# gateway, see index-service/bootstrap.sh) and (re)starts bot-gateway.service —
# all via SSM send-command, because the host is in a private subnet. Idempotent:
# safe to re-run; it overwrites the env file with current values and restarts.
#
# Runs AFTER the AgentCore runtime exists (RUNTIME_ARN must be real). The Feishu
# app credentials are NOT written here — only the SECRET ID goes in the env file;
# run.sh fetches the actual app_id/secret from Secrets Manager at service start.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REGION="$1"; IID="$2"; RUNTIME_ARN="$3"; SECRET_ID="$4"
LOCALE="${5:-zh}"; LOG_HASH_SALT="${6:-}"; FEISHU_API_BASE="${7:-}"; IDLE_TIMEOUT="${8:-}"

[[ -n "$IID" && "$IID" != "None" ]] || { say err "activate_gateway: missing index instance id"; exit 2; }
[[ -n "$RUNTIME_ARN" ]] || { say err "activate_gateway: missing RUNTIME_ARN"; exit 2; }
[[ -n "$SECRET_ID" ]] || { say err "activate_gateway: missing FEISHU_SECRET_ID"; exit 2; }

# Build the env-file contents the host should write. Single-quote every value: the
# secret ARN, salt, etc. are arbitrary strings, and run.sh `source`s this file, so an
# unquoted value with a shell metachar would break sourcing (the same .env quoting
# trap already burned this project — see the deploy-env quoting lesson). LOG_HASH_SALT
# and FEISHU_API_BASE are optional (gateway has safe defaults), so emit them only when set.
ENV_BODY="RUNTIME_ARN='${RUNTIME_ARN}'
AWS_REGION='${REGION}'
FEISHU_SECRET_ID='${SECRET_ID}'
LOCALE='${LOCALE}'"
[[ -n "$LOG_HASH_SALT" ]] && ENV_BODY="${ENV_BODY}
LOG_HASH_SALT='${LOG_HASH_SALT}'"
[[ -n "$FEISHU_API_BASE" ]] && ENV_BODY="${ENV_BODY}
FEISHU_API_BASE='${FEISHU_API_BASE}'"
# The runtime's idle timeout (seconds) — the gateway derives its session-reuse TTL
# from this so "reusable on the gateway" never outlives "still warm on AgentCore".
[[ -n "$IDLE_TIMEOUT" ]] && ENV_BODY="${ENV_BODY}
RUNTIME_IDLE_TIMEOUT_SECS='${IDLE_TIMEOUT}'"

# PROJECT ROUTING (multi-repo plan 阶段1): the gateway's project config is DEPLOYMENT-SPECIFIC
# and lives at .local/projects.json on the DEPLOY machine (gitignored, not in the gateway
# tarball). The gateway on the host resolves its config from PROJECTS_CONFIG_PATH (NOT a
# relative ../../.local walk — the host layout is /opt/bot-gateway, where that would land at
# /opt/.local). So: if .local/projects.json exists here, ship it to a fixed host path and point
# the gateway at it. PROJECT_ID (which project this gateway serves) comes from deploy-config or
# the env; omitted = the gateway's sole-project default. All OPTIONAL — a deploy with no
# projects.json simply runs without a projectId dimension (the loader's soft path).
HOST_PROJECTS_PATH="/etc/source-truth-projects.json"
LOCAL_PROJECTS="$SCRIPT_DIR/../../.local/projects.json"
PROJECTS_B64=""
if [[ -f "$LOCAL_PROJECTS" ]]; then
  PROJECTS_B64="$(base64 < "$LOCAL_PROJECTS" | tr -d '\n')"
  ENV_BODY="${ENV_BODY}
PROJECTS_CONFIG_PATH='${HOST_PROJECTS_PATH}'"
fi
# PROJECT_ID: explicit env wins; else read from deploy-config if present (best-effort).
PROJECT_ID="${PROJECT_ID:-}"
if [[ -z "$PROJECT_ID" && -f "$SCRIPT_DIR/../../.local/deploy-config" ]]; then
  PROJECT_ID="$(grep -E '^PROJECT_ID=' "$SCRIPT_DIR/../../.local/deploy-config" 2>/dev/null | head -1 | cut -d= -f2- || echo "")"
  # Strip surrounding single/double quotes if a human hand-wrote PROJECT_ID='x' (deploy
  # writes unquoted, but be robust): the value is re-quoted on the env line below.
  PROJECT_ID="${PROJECT_ID#[\"\']}"; PROJECT_ID="${PROJECT_ID%[\"\']}"
fi
[[ -n "$PROJECT_ID" ]] && ENV_BODY="${ENV_BODY}
PROJECT_ID='${PROJECT_ID}'"

# Base64 the body so arbitrary content survives the JSON/shell trip through
# send-command intact (no escaping games with quotes/newlines in the parameters).
ENV_B64="$(printf '%s\n' "$ENV_BODY" | base64 | tr -d '\n')"

# The remote script: write the env file (0600 — it names the secret id), optionally write the
# project-routing config, then restart the unit. `systemctl restart` re-evaluates
# ConditionPathExists (now true) and (re)starts cleanly whether first activation or a config update.
REMOTE_CMD="set -e
echo '${ENV_B64}' | base64 -d > /etc/bot-gateway.env
chmod 600 /etc/bot-gateway.env"
if [[ -n "$PROJECTS_B64" ]]; then
  REMOTE_CMD="${REMOTE_CMD}
echo '${PROJECTS_B64}' | base64 -d > '${HOST_PROJECTS_PATH}'
chmod 644 '${HOST_PROJECTS_PATH}'"
fi
REMOTE_CMD="${REMOTE_CMD}
systemctl restart bot-gateway.service
sleep 2
systemctl is-active bot-gateway.service"

say info "activating bot-gateway on $IID (writing /etc/bot-gateway.env + restarting service)"
# Build --parameters as a JSON FILE: commands is an array where EACH element is ONE
# command LINE (SSM joins them with newlines and runs the result as a script). Two bugs
# this avoids: (1) json.dumps([whole_block]) → commands=[["..."]] list-of-list, rejected
# by AWS; (2) json.dumps(whole_block_with_\n) → a single element whose literal "\n" is NOT
# a shell newline, so lines ran glued ("...envnecho", "set: Illegal option -c"). Splitting
# on real newlines into separate array elements is the shape SSM actually expects.
PARAM_FILE="$(mktemp /tmp/gw-ssm-params.XXXX.json)"
printf '%s' "$REMOTE_CMD" | python3 -c 'import sys,json; print(json.dumps({"commands": sys.stdin.read().split("\n")}))' > "$PARAM_FILE"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters "file://$PARAM_FILE" \
  --query Command.CommandId --output text 2>/dev/null || echo "")"
rm -f "$PARAM_FILE"
if [[ -z "$CID" ]]; then
  say err "activate_gateway: send-command failed (SSM unreachable? check instance + NAT egress)"; exit 1
fi

# Poll the invocation to completion (bounded). Surface the unit's is-active status.
DEADLINE=$(( SECONDS + ${GATEWAY_ACTIVATE_TIMEOUT_SECS:-120} ))
while (( SECONDS < DEADLINE )); do
  sleep 5
  STATUS="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
    --instance-id "$IID" --query Status --output text 2>/dev/null || echo "")"
  case "$STATUS" in
    Success)
      OUT="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
        --instance-id "$IID" --query StandardOutputContent --output text 2>/dev/null | tr -d '[:space:]' || echo "")"
      if [[ "$OUT" == "active" ]]; then
        say ok "bot-gateway is active on $IID"; exit 0
      fi
      say err "bot-gateway started but is not active (status: ${OUT:-unknown}). Inspect: aws ssm start-session --target $IID ; journalctl -u bot-gateway -n 50"
      exit 1
      ;;
    Failed|Cancelled|TimedOut)
      ERR="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
        --instance-id "$IID" --query StandardErrorContent --output text 2>/dev/null || echo "")"
      say err "activate_gateway: remote command $STATUS — ${ERR:0:300}"
      exit 1
      ;;
  esac
done
say err "activate_gateway: timed out waiting for SSM command to finish (${GATEWAY_ACTIVATE_TIMEOUT_SECS:-120}s)"
exit 1
