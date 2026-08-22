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
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"; source "$SCRIPT_DIR/resolve_model.sh"

REGION="${1:?usage: deploy_project.sh <region> <project_id>}"
PID="${2:?usage: deploy_project.sh <region> <project_id>}"
CONFIG_FILE="$ROOT/.local/deploy-config"
PROJECTS_CFG="$ROOT/.local/projects.json"
[[ -f "$PROJECTS_CFG" ]] || { say err "no $PROJECTS_CFG — nothing to deploy"; exit 1; }
[[ "$PID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say err "invalid projectId '$PID'"; exit 1; }

safe_source_env "$CONFIG_FILE"
# Fail with an actionable message, not `ARTIFACT_BUCKET: unbound variable`. This script is reached
# DIRECTLY by install.sh's add-project / redeploy flows, so a deploy-config written before that key
# existed (or a partial Phase 1) hits the SSM heredoc below (`aws s3 cp s3://${ARTIFACT_BUCKET}/…`)
# and aborts on set -u with no hint about which phase is missing. Same shape as the
# INDEX_SERVICE_INSTANCE / PRIVATE_SUBNET guards further down.
: "${ARTIFACT_BUCKET:?not set in .local/deploy-config — run scripts/deploy-all.sh (artifacts phase) first}"
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
specs = [{"subdir": r["subdir"], "source": r.get("source", "git"),
          "git": r.get("git", ""), "ref": r.get("ref", ""),
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

# The model for this project: per-project override (projects.json) > persisted default >
# built-in default. Resolve to THIS region's actual inference profile ONCE here, because BOTH
# consumers need the region-correct id: the runtime (below) AND the host-side glossary engine
# (activate_project's Bedrock converse precheck + cc build). Resolving only for the runtime, but
# passing the raw region-agnostic `global.…` to activate_project, made the glossary precheck fail
# in regions that carry no `global.` profile (e.g. Tokyo, jp.-only) → glossary silently skipped
# while the runtime worked. resolve_model_for_region returns the id unchanged if it can't ask
# Bedrock (rc=2 = unverified → WARN, so a multi-project deploy doesn't silently diverge).
RT_MODEL_DECLARED="${MODEL:-${DEPLOY_MODEL:-global.anthropic.claude-opus-4-8}}"
RT_RC=0
RT_MODEL="$(resolve_model_for_region "$RT_MODEL_DECLARED" "$REGION")" || RT_RC=$?
if [[ "$RT_RC" == 2 ]]; then
  say warn "[$PID] couldn't query Bedrock inference profiles for $REGION — using '$RT_MODEL' unverified"
  say warn "  (check the deploy identity's bedrock:ListInferenceProfiles perm; the invoke-probe rechecks it)."
elif [[ "$RT_MODEL" != "$RT_MODEL_DECLARED" ]]; then
  say info "[$PID] resolved model for $REGION: $RT_MODEL_DECLARED → $RT_MODEL"
fi

# ============================================================
# 1) Attach the project to the index host: ship its manifest + run activate_project.sh via SSM.
# ============================================================
# activate_project.sh is staged to S3 alongside the index-service code (deploy-all artifacts);
# the host pulls it. The manifest (which can carry git URLs with @/:) rides as base64 so no
# shell/JSON escaping games. The git credential is fetched HOST-SIDE by activate_project (only
# its secret id crosses SSM, never the token).
MANIFEST_B64="$(printf '%s' "$REPO_MANIFEST_JSON" | base64 | tr -d '\n')"
# Publish the index-service tree via a STAGING dir + rsync, not `tar xzf` straight over
# /opt/idx/app. Every other project's index-bridge is live out of that directory, and the
# transient glossary-build / index-refresh units run from it too, so extracting in place swaps
# files under running Python. rsync renames per file, so an open fd keeps its old inode, and
# --delete-after removes modules dropped upstream (a plain untar left them behind forever).
# Same fix bootstrap.sh got; this path runs far more often — on every per-project deploy.
REMOTE_CMD="set -e
aws s3 cp s3://${ARTIFACT_BUCKET}/index-service.tar.gz /tmp/idx-refresh.tar.gz --region ${REGION}
# rsync is REQUIRED here, not optional: a non-atomic publish over a tree other projects are
# executing from is exactly what this block exists to avoid. Hosts bootstrapped before rsync
# became a bootstrap dependency may not have it, so install-or-fail rather than discovering it
# after the download and extract. Mirrors the guard activate_gateway.sh already carries.
command -v rsync >/dev/null 2>&1 || { yum install -y rsync || { apt-get update -qq && apt-get install -y -qq rsync; }; } >/dev/null 2>&1 || true
command -v rsync >/dev/null 2>&1 || { echo 'ACTIVATE_FAILED: rsync missing on host and could not be installed — refusing a non-atomic publish over the live index-service tree'; exit 1; }
# FIXED staging path with a leading rm -rf, not mktemp -d: EXIT traps do not fire on SIGKILL, and
# this payload runs under SSM where the command can be cancelled or time out — deploy_project.sh's
# own deadline gives up WITHOUT cancelling the remote run. A random mktemp name therefore stranded
# a full copy of the tree on the root volume (shared with graph.db) on every abnormal exit, and
# nothing in the repo ever collected /opt/idx/app.stage.*. bootstrap.sh already uses this pattern.
# Unique LEAF under a fixed parent. A fixed leaf fixed the disk leak but introduced a worse race:
# two concurrent deploys (two projects, or an operator redeploy racing a scripted one) shared one
# path, so run B's rm -rf wiped run A's staged tree mid-flight and B's EXIT trap deleted it again
# while A was still rsyncing — letting A publish a PARTIAL tree into the live /opt/idx/app with
# --delete-after, which is exactly what the completeness guard cannot catch because it runs before
# the rsync, not during it. Unique leaf keeps mktemp's isolation; the sweep keeps the leak closed
# even when a trap never fires (SIGKILL, SSM cancel).
find /opt/idx/stage -maxdepth 1 -name 'deploy-app.*' -mmin +120 -exec rm -rf {} + 2>/dev/null || true
IDX_STAGE=/opt/idx/stage/deploy-app.\$\$
rm -rf \"\$IDX_STAGE\"; mkdir -p \"\$IDX_STAGE\"
trap 'rm -rf \"\$IDX_STAGE\"' EXIT
IDX_TGZ_SIG=\$(sha256sum /tmp/idx-refresh.tar.gz 2>/dev/null | cut -d\" \" -f1 || true)
tar xzf /tmp/idx-refresh.tar.gz -C \"\$IDX_STAGE\" && rm -f /tmp/idx-refresh.tar.gz
# Refuse to publish an incomplete extract — a truncated download would otherwise wipe the
# live tree via --delete-after. Check EVERY file the payload goes on to need: the guard used to
# check two while the next line chmod'd four, so a tarball missing one of the other two passed the
# guard and died on a bare 'chmod: cannot access', hiding the real cause behind a confusing error.
for f in http_bridge.py activate_project.sh git_fetch.sh glossary_refresh.sh reindex_local_repo.sh requirements.txt; do
  [ -f \"\$IDX_STAGE/\$f\" ] || { echo \"ACTIVATE_FAILED: staged index-service tree is incomplete (missing \$f)\"; exit 1; }
done
chmod +x \"\$IDX_STAGE\"/activate_project.sh \"\$IDX_STAGE\"/git_fetch.sh \"\$IDX_STAGE\"/glossary_refresh.sh \"\$IDX_STAGE\"/reindex_local_repo.sh
mkdir -p /opt/idx/app
rsync -a --delay-updates --delete-after \"\$IDX_STAGE\"/ /opt/idx/app/
# Re-stamp: this path publishes app code without going through bootstrap.sh, so without this
# /opt/idx/.app_sig would still describe the PREVIOUS tree and the bridge skew field of the bridge would
# report \"unchanged\" across a deploy that changed everything. The value is opaque — only that
# it CHANGES when the code changes matters.
[ -n \"\$IDX_TGZ_SIG\" ] || { echo 'ACTIVATE_FAILED: could not compute the artifact hash, refusing to leave a stale /opt/idx/.app_sig'; exit 1; }
printf '%s\\n' \"\$IDX_TGZ_SIG\" > /opt/idx/.app_sig
mkdir -p /etc/index-projects
echo '${MANIFEST_B64}' | base64 -d > /tmp/manifest-${PID}.json
PROJECT_ID='${PID}' GIT_SECRET_ID='${GIT_SECRET_ID}' MODEL='${RT_MODEL}' REPO_MANIFEST_JSON=\"\$(cat /tmp/manifest-${PID}.json)\" bash /opt/idx/app/activate_project.sh
rm -f /tmp/manifest-${PID}.json"

PARAM_FILE="$(mktemp /tmp/ap-ssm.XXXXXX)"  # X's at end (BSD/macOS-safe); .json suffix cosmetic (passed as file://)
printf '%s' "$REMOTE_CMD" | python3 -c 'import sys,json; print(json.dumps({"commands": sys.stdin.read().split("\n")}))' > "$PARAM_FILE"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript --parameters "file://$PARAM_FILE" \
  --query Command.CommandId --output text 2>/dev/null || echo "")"
rm -f "$PARAM_FILE"
# Name the three things to check, not a question mark. "(SSM/NAT?)" told the operator there was a
# question without telling them where to look.
[[ -n "$CID" ]] || {
  say err "activate_project: SSM send-command failed — the host did not accept the command."
  say err "  1) is it registered with SSM?  aws ssm describe-instance-information --region $REGION --filters Key=InstanceIds,Values=$IID"
  say err "  2) does its private subnet have a 0.0.0.0/0 route to the NAT gateway? (SSM needs egress)"
  say err "  3) does the instance role carry AmazonSSMManagedInstanceCore?"
  exit 1
}
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
if (( SECONDS >= DEADLINE )); then
  # The Failed branch above dumps the remote output; the TIMEOUT branch used to dump nothing at
  # all — and on a large repo a timeout is the LIKELIER outcome, since graph builds take minutes.
  # Print the same evidence, then cancel the remote run so it stops working against a deploy that
  # has already given up (it holds the project's units).
  say err "activate_project $PID timed out after ${PROJECT_ACTIVATE_TIMEOUT_SECS:-900}s (graph builds on a large repo can exceed this; raise PROJECT_ACTIVATE_TIMEOUT_SECS)"
  OUT="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
    --query 'StandardOutputContent' --output text 2>/dev/null || echo "")"
  ERR="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$IID" \
    --query 'StandardErrorContent' --output text 2>/dev/null || echo "")"
  [[ -n "$ERR" ]] && { say err "  remote stderr:"; printf '%s\n' "$ERR" | tail -20 >&2; }
  [[ -n "$OUT" ]] && { say err "  remote stdout (last 20):"; printf '%s\n' "$OUT" | tail -20 >&2; }
  say err "  live progress: aws ssm start-session --target $IID --region $REGION, then sudo journalctl -u 'index-build@*' -n 100"
  aws ssm cancel-command --region "$REGION" --command-id "$CID" --instance-ids "$IID" >/dev/null 2>&1 || true
  exit 1
fi

# ============================================================
# 2) Per-project AgentCore runtime — CODEGRAPH_MCP_URL points at THIS project's bridge port.
# ============================================================
ECR_URI="${ECR_IMAGE:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/source-truth/agent:latest}"
ROLE_ARN="${AGENT_RUNTIME_ROLE:-arn:aws:iam::${ACCOUNT}:role/SourceTruthAgentRuntimeRole}"
SUBNET="${PRIVATE_SUBNET:?PRIVATE_SUBNET not set — run the network phase first}"
RUNTIME_SG="${INDEX_SERVICE_SG:?INDEX_SERVICE_SG not set — run the index-svc phase first}"
IDX_ENDPOINT="${INDEX_DNS_NAME:-${INDEX_SERVICE_IP:?INDEX_SERVICE_IP not set}}"
CODEGRAPH_URL="http://${IDX_ENDPOINT}:${PORT}/mcp"
# RT_MODEL was resolved once near the top (shared with the host-side glossary engine); reuse it.
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
# TENANT + LOCALE resolution, at the one point BOTH flows pass through.
#
# deploy-all.sh persists DEPLOY_FEISHU_DOMAIN / DEPLOY_LOCALE, but install.sh's "redeploy" flow
# does not call deploy-all — it invokes this script directly with FEISHU_DOMAIN/LOCALE as one-shot
# environment values. And activate_gateway.sh rewrites the gateway env file WHOLE. So
# `install.sh --feishu-domain lark` + redeploy took effect exactly once: the next flag-less
# redeploy read the stale DEPLOY_FEISHU_DOMAIN, rewrote the env file back to feishu, and the bot
# silently returned to the China tenant and stopped receiving events entirely. Same class as the
# discarded-flag defect the arg loop was rewritten to eliminate — moved into the persistence step.
#
# Resolving AND persisting here makes both flows equivalent and removes the dependency on whether
# deploy-all was ever involved.
_TENANT="${FEISHU_DOMAIN:-${DEPLOY_FEISHU_DOMAIN:-feishu}}"
# Locale default follows the tenant. The old fallback hardcoded zh, so a redeploy that switched to
# lark without an explicit --locale configured an international tenant with Chinese cards — the
# pipeline accident deploy-all.sh derives this default specifically to prevent. Only the DEFAULT is
# derived; an explicit LOCALE / DEPLOY_LOCALE still wins.
if [[ -n "${LOCALE:-}" ]]; then
  _LOCALE="$LOCALE"
elif [[ -n "${DEPLOY_LOCALE:-}" ]]; then
  _LOCALE="$DEPLOY_LOCALE"
elif [[ "$_TENANT" == "lark" ]]; then
  _LOCALE="en"
else
  _LOCALE="zh"
fi
# Persist so the NEXT flag-less redeploy keeps the tenant instead of silently reverting.
if [[ "${_TENANT}" != "${DEPLOY_FEISHU_DOMAIN:-}" || "${_LOCALE}" != "${DEPLOY_LOCALE:-}" ]]; then
  update_env "$CONFIG_FILE" DEPLOY_FEISHU_DOMAIN "$_TENANT"
  update_env "$CONFIG_FILE" DEPLOY_LOCALE "$_LOCALE"
  say info "persisted tenant=$_TENANT locale=$_LOCALE to deploy-config"
fi
PROJECT_ID="$PID" \
FEISHU_DOMAIN="$_TENANT" \
  bash "$SCRIPT_DIR/activate_gateway.sh" \
  "$REGION" "$IID" "$RT_ARN" "$FEISHU_SECRET" \
  "$_LOCALE" "" "${FEISHU_API_BASE:-}" "${DEPLOY_IDLE_TIMEOUT:-900}" "$ARTIFACT_BUCKET" \
  || { say err "gateway activation failed for $PID — backend is up. Logs: sudo journalctl -u bot-gateway@$PID -n 50, and /var/log/bot-gateway-$PID.log on $IID (aws ssm start-session --target $IID --region $REGION)"; exit 1; }
say ok "project $PID fully deployed (bridge:$PORT + runtime + gateway)"

# Local repos come up with their graph DEFERRED (activate doesn't require code to be present). The
# backend is live, but until the operator pushes code the bridge serves an empty graph and the bot
# would answer "not found" rather than a real answer — so surface the required next step explicitly
# here (the only place a redeploy / direct deploy-all run would see it; add-project already hints it).
LOCAL_SUBS="$(REPO_MANIFEST_JSON="$REPO_MANIFEST_JSON" python3 -c '
import json,os
m=json.loads(os.environ["REPO_MANIFEST_JSON"])
print(" ".join(r.get("subdir","") for r in m.get("repos",[]) if r.get("source")=="local" and r.get("subdir")))
' 2>/dev/null || true)"
if [[ -n "${LOCAL_SUBS// }" ]]; then
  say warn "项目 $PID 含本地仓 [${LOCAL_SUBS# }]：后端已就绪，但在推代码前机器人无法作答（索引为空）。"
  say warn "  从你自己的机器推代码即建图上线（首推=建图，之后每次改动重推=刷新）："
  for _s in $LOCAL_SUBS; do
    say warn "    scripts/push-local-repo.sh --host <ssh-host> [--identity <key>] $_s <本地路径>"
  done
fi
