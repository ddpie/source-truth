#!/usr/bin/env bash
# deploy_project.sh <region> <project_id> — deploy ONE project (idempotent): attach it to the
# (already-provisioned) base index host, deploy its AgentCore runtime, and activate its gateway.
#
# Reads the project's port / repos / feishuSecretId from .local/projects.json (the single
# declaration authority). Assumes the shared base has been provisioned (INDEX_SERVICE_INSTANCE,
# network, IAM, ECR image all present in .local/deploy-config) — deploy-all runs the base phase
# first; install.sh's add-project flow ensures it too.
#
# Per-project products are written back to deploy-config under a namespaced key
# (RUNTIME_ARN_<pid>), so projects never clobber each other's state.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"

REGION="${1:?usage: deploy_project.sh <region> <project_id>}"
PID="${2:?usage: deploy_project.sh <region> <project_id>}"
CONFIG_FILE="$ROOT/.local/deploy-config"
PROJECTS_CFG="$ROOT/.local/projects.json"
[[ -f "$PROJECTS_CFG" ]] || { say err "no $PROJECTS_CFG — nothing to deploy"; exit 1; }
[[ "$PID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say err "invalid projectId '$PID'"; exit 1; }

safe_source_env "$CONFIG_FILE"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
GIT_SECRET_ID="${GIT_SECRET_ID:-source-truth/git-credentials}"

# --- read this project's declaration (port / repos / feishuSecretId / model) ---
# Emit shell-safe assignments; repos become REPO_SPECS_JSON (compact) for the manifest builder.
read_proj() { python3 - "$PROJECTS_CFG" "$PID" <<'PY'
import json, sys, shlex
cfg = json.load(open(sys.argv[1])); pid = sys.argv[2]
p = cfg["projects"].get(pid)
if p is None:
    sys.stderr.write(f"project '{pid}' not in projects.json\n"); sys.exit(1)
specs = [{"subdir": r["subdir"], "git": r["git"], "ref": r.get("ref", ""),
          "refreshIntervalSec": r.get("refreshIntervalSec")} for r in p["repos"]]
print("PORT=" + shlex.quote(str(p["port"])))
print("FEISHU_SECRET=" + shlex.quote(p.get("feishuSecretId", "")))
print("MODEL=" + shlex.quote(p.get("model", "")))
print("DEFAULT_IV=" + shlex.quote(str(cfg.get("refreshIntervalSec", 300))))
print("REPO_SPECS_JSON=" + shlex.quote(json.dumps(specs, separators=(",", ":"))))
PY
}
# Capture to a var THEN eval: `eval "$(read_proj)"` can't see read_proj's exit code (command
# substitution failure is masked, eval "" returns 0), so a missing/invalid project would slip
# through to a cryptic `PORT: unbound variable` under set -u. Check rc explicitly.
_PROJ_VARS="$(read_proj)" || { say err "could not read project '$PID' from projects.json"; exit 1; }
eval "$_PROJ_VARS"

# Build this project's REPO_MANIFEST_JSON via the single build authority (fail-loud on bad input).
REPO_MANIFEST_JSON="$(REPO_SPECS_JSON="$REPO_SPECS_JSON" PID="$PID" PORT="$PORT" DEFAULT_IV="$DEFAULT_IV" \
  python3 - "$SCRIPT_DIR/render_manifest.py" <<'PY'
import os, sys, json, importlib.util
spec = importlib.util.spec_from_file_location("rm", sys.argv[1])
rm = importlib.util.module_from_spec(spec); spec.loader.exec_module(rm)
print(rm.build_multi_manifest(os.environ["PID"], int(os.environ["PORT"]),
                              json.loads(os.environ["REPO_SPECS_JSON"]), int(os.environ["DEFAULT_IV"])))
PY
)" || { say err "failed to build manifest for $PID (bad subdir/git/port?)"; exit 1; }

IID="${INDEX_SERVICE_INSTANCE:?INDEX_SERVICE_INSTANCE not set — provision the base host first (deploy-all)}"
say step "deploy project $PID (port=$PORT) on index host $IID"

# ============================================================
# 1) Attach the project to the index host: ship its manifest + run activate_project.sh via SSM.
# ============================================================
# activate_project.sh is staged to S3 alongside the index-service code (deploy-all artifacts);
# the host pulls it. The manifest (which can carry git URLs with @/:) rides as base64 so no
# shell/JSON escaping games. The git credential is fetched HOST-SIDE by activate_project (only
# its secret id crosses SSM, never the token).
MANIFEST_B64="$(printf '%s' "$REPO_MANIFEST_JSON" | base64 | tr -d '\n')"
REMOTE_CMD="set -e
aws s3 cp s3://${ARTIFACT_BUCKET}/index-service.tar.gz /tmp/idx-refresh.tar.gz --region ${REGION}
tar xzf /tmp/idx-refresh.tar.gz -C /opt/idx/app && rm -f /tmp/idx-refresh.tar.gz
chmod +x /opt/idx/app/activate_project.sh /opt/idx/app/git_fetch.sh
mkdir -p /etc/index-projects
echo '${MANIFEST_B64}' | base64 -d > /tmp/manifest-${PID}.json
PROJECT_ID='${PID}' GIT_SECRET_ID='${GIT_SECRET_ID}' REPO_MANIFEST_JSON=\"\$(cat /tmp/manifest-${PID}.json)\" bash /opt/idx/app/activate_project.sh
rm -f /tmp/manifest-${PID}.json"

PARAM_FILE="$(mktemp /tmp/ap-ssm.XXXX.json)"
printf '%s' "$REMOTE_CMD" | python3 -c 'import sys,json; print(json.dumps({"commands": sys.stdin.read().split("\n")}))' > "$PARAM_FILE"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript --parameters "file://$PARAM_FILE" \
  --query Command.CommandId --output text 2>/dev/null || echo "")"
rm -f "$PARAM_FILE"
[[ -n "$CID" ]] || { say err "activate_project: SSM send-command failed (SSM/NAT?)"; exit 1; }
say info "running activate_project.sh on $IID (clone repos + build graphs + start bridge:$PORT) ..."
DEADLINE=$(( SECONDS + ${PROJECT_ACTIVATE_TIMEOUT_SECS:-900} ))   # graph builds can take minutes
while (( SECONDS < DEADLINE )); do
  sleep 8
  ST="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
    --query Status --output text 2>/dev/null || echo "")"
  case "$ST" in
    Success) say ok "project $PID attached to index host (bridge on :$PORT)"; break ;;
    Failed|Cancelled|TimedOut)
      ERR="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
        --query StandardErrorContent --output text 2>/dev/null || echo "")"
      OUT="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
        --query StandardOutputContent --output text 2>/dev/null || echo "")"
      say err "activate_project $PID $ST — ${ERR:0:300}"
      printf '%s\n' "$OUT" | tail -20
      exit 1 ;;
  esac
done
if (( SECONDS >= DEADLINE )); then say err "activate_project $PID timed out"; exit 1; fi

# ============================================================
# 2) Per-project AgentCore runtime — CODEGRAPH_MCP_URL points at THIS project's bridge port.
# ============================================================
ECR_URI="${ECR_IMAGE:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/source-truth/agent:latest}"
ROLE_ARN="${AGENT_RUNTIME_ROLE:-arn:aws:iam::${ACCOUNT}:role/SourceTruthAgentRuntimeRole}"
SUBNET="${PRIVATE_SUBNET:?PRIVATE_SUBNET not set — run the network phase first}"
RUNTIME_SG="${INDEX_SERVICE_SG:?INDEX_SERVICE_SG not set — run the index-svc phase first}"
IDX_ENDPOINT="${INDEX_DNS_NAME:-${INDEX_SERVICE_IP:?INDEX_SERVICE_IP not set}}"
CODEGRAPH_URL="http://${IDX_ENDPOINT}:${PORT}/mcp"
RT_MODEL="${MODEL:-${DEPLOY_MODEL:-global.anthropic.claude-opus-4-8}}"
# Per-project runtime name (AgentCore names must be [a-zA-Z0-9_]); pid uses '-' → '_'.
RT_NAME="source_truth_agent_${PID//-/_}"

RT_OUT="$(python3 "$SCRIPT_DIR/deploy_runtime.py" \
  --region "$REGION" --account "$ACCOUNT" --name "$RT_NAME" \
  --role-arn "$ROLE_ARN" --image "$ECR_URI" --model "$RT_MODEL" \
  --subnets "$SUBNET" --security-groups "$RUNTIME_SG" \
  --codegraph-mcp-url "$CODEGRAPH_URL" \
  --idle-timeout "${DEPLOY_IDLE_TIMEOUT:-900}" --max-lifetime "${DEPLOY_MAX_LIFETIME:-28800}")"
RT_ARN="$(printf '%s\n' "$RT_OUT" | sed -n 's/^AGENT_RUNTIME_ARN=//p')"
[[ -n "$RT_ARN" ]] || { say err "deploy_runtime produced no ARN for $PID"; printf '%s\n' "$RT_OUT"; exit 1; }
PID_KEY="${PID//-/_}"
update_env "$CONFIG_FILE" "RUNTIME_ARN_${PID_KEY}" "$RT_ARN"
say ok "runtime for $PID → $RT_ARN (CODEGRAPH_MCP_URL=$CODEGRAPH_URL)"

# ============================================================
# 3) Per-project gateway — its own Feishu app (PROJECT_ID-bound) + this runtime ARN.
# ============================================================
if [[ -z "$FEISHU_SECRET" ]]; then
  say warn "project $PID has no feishuSecretId — backend (bridge+runtime) is up, but NO gateway/bot."
  say warn "  → add \"feishuSecretId\" to projects.json (install.sh add-project creates it), then re-run."
  exit 0
fi
# LOG_HASH_SALT (host-shared, project-agnostic): ensure the secret EXISTS before the FIRST gateway
# starts. hashUserId de-identification is only sound if the salt is SECRET (log.ts falls back to a
# PUBLIC repo constant when unset → telemetry stamps saltWeak). This is also done in deploy-all's
# loop, but deploy_project is reached DIRECTLY by install.sh's add-project (which bypasses that
# loop), so create-if-absent here too. create only on NOT-FOUND — never rotate (would break
# DAU/retention correlation). Best-effort: run.sh reads it host-side; never blocks the gateway.
if ! aws secretsmanager describe-secret --region "$REGION" --secret-id source-truth/log-hash-salt >/dev/null 2>&1; then
  GW_SALT="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  aws secretsmanager create-secret --region "$REGION" --name source-truth/log-hash-salt \
    --secret-string "$GW_SALT" --description 'source-truth gateway LOG_HASH_SALT (telemetry de-identification)' >/dev/null 2>&1 \
    && say ok "created LOG_HASH_SALT in Secrets Manager" \
    || say warn "could not create source-truth/log-hash-salt; gateway runs with weak public fallback (saltWeak)"
  unset GW_SALT
fi
PROJECT_ID="$PID" bash "$SCRIPT_DIR/activate_gateway.sh" \
  "$REGION" "$IID" "$RT_ARN" "$FEISHU_SECRET" \
  "${LOCALE:-zh}" "" "${FEISHU_API_BASE:-}" "${DEPLOY_IDLE_TIMEOUT:-900}" "${ARTIFACT_BUCKET:-}" \
  || { say err "gateway activation failed for $PID — backend is up; fix and re-run"; exit 1; }
say ok "project $PID fully deployed (bridge:$PORT + runtime + gateway)"
