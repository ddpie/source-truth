#!/usr/bin/env bash
# activate_gateway.sh <region> <instance_id> <runtime_arn> <feishu_secret_id> [locale] [log_hash_salt] [feishu_api_base] [idle_timeout] [bucket]
# Requires PROJECT_ID in the environment (which project's gateway to (re)activate).
#
# Writes /etc/bot-gateway-<projectId>.env on the index-service host (which also runs the
# gateways, see index-service/bootstrap.sh) and enable/(re)starts bot-gateway@<projectId> — all
# via SSM send-command, because the host is in a private subnet. Idempotent: safe to re-run; it
# overwrites the env file with current values and restarts. One gateway instance PER project, each
# bound to its own Feishu app (long-connection, no port), coexisting on the shared host.
#
# It also refreshes /opt/bot-gateway when the staged tarball changed. That tree is SHARED by every
# project's gateway and the other projects are LIVE while this runs, so the rebuild is staged and
# then rsync-published (atomic per file); /opt/config is synced, never rm -rf'd. This script
# restarts exactly one unit — its own project's. See the RESTART OWNERSHIP note at the rebuild
# block for who owns the rest.
#
# Runs AFTER the AgentCore runtime exists (RUNTIME_ARN must be real). The Feishu
# app credentials are NOT written here — only the SECRET ID goes in the env file;
# run.sh fetches the actual app_id/secret from Secrets Manager at service start.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REGION="$1"; IID="$2"; RUNTIME_ARN="$3"; SECRET_ID="$4"
LOCALE="${5:-zh}"; LOG_HASH_SALT="${6:-}"; FEISHU_API_BASE="${7:-}"; IDLE_TIMEOUT="${8:-}"; BUCKET="${9:-}"

[[ -n "$IID" && "$IID" != "None" ]] || { say err "activate_gateway: missing index instance id"; exit 2; }
[[ -n "$RUNTIME_ARN" ]] || { say err "activate_gateway: missing RUNTIME_ARN"; exit 2; }
[[ -n "$SECRET_ID" ]] || { say err "activate_gateway: missing FEISHU_SECRET_ID"; exit 2; }

# PROJECT_ID is resolved FIRST, before anything derived from it. It used to be resolved AFTER the
# HEALTH_PORT lookup below, so on the ordinary path where the id comes from deploy-config rather
# than the environment, that lookup ran with an EMPTY id, matched no project, and the gateway unit's
# readiness probe was skipped on every activation.
PROJECT_ID="${PROJECT_ID:-}"
if [[ -z "$PROJECT_ID" && -f "$SCRIPT_DIR/../../.local/deploy-config" ]]; then
  PROJECT_ID="$(grep -E '^PROJECT_ID=' "$SCRIPT_DIR/../../.local/deploy-config" 2>/dev/null | head -1 | cut -d= -f2- || echo "")"
  # Strip surrounding single/double quotes if a human hand-wrote PROJECT_ID='x' (deploy
  # writes unquoted, but be robust): the value is re-quoted on the env line below.
  PROJECT_ID="${PROJECT_ID#[\"\']}"; PROJECT_ID="${PROJECT_ID%[\"\']}"
fi
# Per-project gateway instance (bot-gateway@<projectId>, env at /etc/bot-gateway-<projectId>.env)
# when a PROJECT_ID is known; multiple projects' gateways coexist on one host. PROJECT_ID is
# required in the multi-project world (deploy_project always passes it); guard so a misconfigured
# call can't silently write the wrong file.
[[ -n "$PROJECT_ID" ]] || { say err "activate_gateway: PROJECT_ID required (which project's gateway to activate)"; exit 2; }
[[ "$PROJECT_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say err "activate_gateway: invalid PROJECT_ID '$PROJECT_ID'"; exit 2; }
GW_ENV_PATH="/etc/bot-gateway-${PROJECT_ID}.env"
GW_UNIT="bot-gateway@${PROJECT_ID}.service"
# Deployment-specific project config, on the DEPLOY machine (see PROJECT ROUTING below). Declared
# once, here, because both the HEALTH_PORT derivation and the routing block read it.
LOCAL_PROJECTS="$SCRIPT_DIR/../../.local/projects.json"

# Build the env-file contents the host should write. Single-quote every value: the
# secret ARN, salt, etc. are arbitrary strings, and run.sh `source`s this file, so an
# unquoted value with a shell metachar would break sourcing (the same .env quoting
# trap already burned this project — see the deploy-env quoting lesson). LOG_HASH_SALT
# and FEISHU_API_BASE are optional (gateway has safe defaults), so emit them only when set.
ENV_BODY="RUNTIME_ARN='${RUNTIME_ARN}'
AWS_REGION='${REGION}'
FEISHU_SECRET_ID='${SECRET_ID}'
LOCALE='${LOCALE}'
PROJECT_ID='${PROJECT_ID}'"
[[ -n "$LOG_HASH_SALT" ]] && ENV_BODY="${ENV_BODY}
LOG_HASH_SALT='${LOG_HASH_SALT}'"
[[ -n "$FEISHU_API_BASE" ]] && ENV_BODY="${ENV_BODY}
FEISHU_API_BASE='${FEISHU_API_BASE}'"
# The runtime's idle timeout (seconds) — the gateway derives its session-reuse TTL
# from this so "reusable on the gateway" never outlives "still warm on AgentCore".
[[ -n "$IDLE_TIMEOUT" ]] && ENV_BODY="${ENV_BODY}
RUNTIME_IDLE_TIMEOUT_SECS='${IDLE_TIMEOUT}'"

# HEALTH_PORT — pinned EXPLICITLY per project rather than left to the gateway's own derivation.
# The gateway derives bridge+10000 when this is unset, but the systemd unit's ExecStartPost
# probe also has to know the number, and a template unit cannot compute it. Writing it here
# gives one authoritative value that both the process and the probe read, so a project whose
# bridge port is not 8080 no longer has its startup probe poll the wrong port.
# OMIT, NEVER EMIT EMPTY, when the port can't be resolved: the unit's probe treats an UNSET
# HEALTH_PORT as "skip the probe" (a clean no-op), while HEALTH_PORT='' would build
# http://127.0.0.1:/ready and make the probe log a spurious failure for every activation.
_HP=""
if [[ -f "$LOCAL_PROJECTS" ]]; then
  _HP="$(python3 -c 'import json,sys
try:
    cfg=json.load(open(sys.argv[1]))
    p=cfg.get("projects",{}).get(sys.argv[2],{})
    port=p.get("port")
    print(10000+int(port) if isinstance(port,int) and 0 < port < 55536 else "")
except Exception:
    print("")' "$LOCAL_PROJECTS" "$PROJECT_ID" 2>/dev/null || echo "")"
fi
if [[ -n "$_HP" ]]; then
  ENV_BODY="${ENV_BODY}
HEALTH_PORT='${_HP}'"
else
  say warn "activate_gateway: no bridge port for '$PROJECT_ID' in ${LOCAL_PROJECTS} — omitting HEALTH_PORT (the unit skips its readiness probe; it must never be written empty)"
fi

# PROJECT ROUTING (multi-repo plan 阶段1): the gateway's project config is DEPLOYMENT-SPECIFIC
# and lives at .local/projects.json on the DEPLOY machine (gitignored, not in the gateway
# tarball). The gateway on the host resolves its config from PROJECTS_CONFIG_PATH (NOT a
# relative ../../.local walk — the host layout is /opt/bot-gateway, where that would land at
# /opt/.local). So: if .local/projects.json exists here, ship it to a fixed host path and point
# the gateway at it. PROJECT_ID (which project this gateway serves) comes from deploy-config or
# the env; omitted = the gateway's sole-project default. All OPTIONAL — a deploy with no
# projects.json simply runs without a projectId dimension (the loader's soft path).
HOST_PROJECTS_PATH="/etc/source-truth-projects.json"
PROJECTS_B64=""
if [[ -f "$LOCAL_PROJECTS" ]]; then
  PROJECTS_B64="$(base64 < "$LOCAL_PROJECTS" | tr -d '\n')"
  ENV_BODY="${ENV_BODY}
PROJECTS_CONFIG_PATH='${HOST_PROJECTS_PATH}'"
fi

# Base64 the body so arbitrary content survives the JSON/shell trip through
# send-command intact (no escaping games with quotes/newlines in the parameters).
ENV_B64="$(printf '%s\n' "$ENV_BODY" | base64 | tr -d '\n')"

# The remote script: write the env file (0600 — it names the secret id), optionally write the
# project-routing config, then restart the unit. `systemctl restart` re-evaluates
# ConditionPathExists (now true) and (re)starts cleanly whether first activation or a config update.
REMOTE_CMD="set -e
echo '${ENV_B64}' | base64 -d > ${GW_ENV_PATH}
chmod 600 ${GW_ENV_PATH}"
if [[ -n "$PROJECTS_B64" ]]; then
  REMOTE_CMD="${REMOTE_CMD}
echo '${PROJECTS_B64}' | base64 -d > '${HOST_PROJECTS_PATH}'
chmod 644 '${HOST_PROJECTS_PATH}'"
fi
# REBUILD-IF-STALE (cross-review: a re-staged bot-gateway.tar.gz never took effect because
# activate only restarted — the gateway is BUILT on the instance, and the host is updated IN
# PLACE, so nothing else ever refreshes dist/ and the deploy silently shipped stale gateway
# code). Re-pull the tarball, and rebuild ONLY when its content hash changed (a stamp
# gates the ~90s npm ci+build so a no-change re-run is still fast). Needs BUCKET.
#
# /opt/bot-gateway is SHARED by every project's gateway on this host, and this script runs while
# the OTHER projects' gateways are live. So the rebuild happens in a STAGING tree and only the
# finished result is published with rsync (per-file rename(2); open fds keep the old inode; no file
# is ever missing or half-written). The previous version ran `npm ci` (which DELETES node_modules
# wholesale) and `npm prune` directly in the live tree, then restarted only THIS project's unit —
# so deploying project B could crash-loop project A's gateway on MODULE_NOT_FOUND. `rm -rf
# /opt/config; mv` likewise left every project's card copy absent for the duration.
#
# RESTART OWNERSHIP: this script restarts exactly ONE unit — its own project's ${GW_UNIT}, below.
# It deliberately does NOT restart other projects' gateways (that would drop their Feishu
# long-connections behind their owners' backs) and it is not the component that stops/starts units
# around an in-place re-bootstrap — provision_index_service.sh owns that, and index-bridge-* belongs
# to activate_project.sh. Where this leaves another project's gateway running older code than what
# is now on disk, it prints a CODE_NEWER_THAN_RUNNING line naming the unit instead of acting.
if [[ -n "$BUCKET" ]]; then
  REMOTE_CMD="${REMOTE_CMD}
GW=/opt/bot-gateway
STAGE=/opt/bot-gateway.stage
aws s3 cp s3://${BUCKET}/bot-gateway.tar.gz /tmp/gw.tar.gz --region ${REGION}
NEW_SIG=\$(sha256sum /tmp/gw.tar.gz | cut -d' ' -f1)
OLD_SIG=\$(cat \$GW/.src_sig 2>/dev/null || echo none)
if [ \"\$NEW_SIG\" != \"\$OLD_SIG\" ] || [ ! -f \$GW/dist/index.js ]; then
  echo \"gateway source changed (\$OLD_SIG -> \$NEW_SIG) or dist missing — rebuilding in \$STAGE (live tree untouched until verified)\"
  command -v rsync >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y rsync || true
  command -v rsync >/dev/null || { echo 'BOOTSTRAP_FAILED: rsync missing on host — refusing a non-atomic publish over a live gateway tree'; exit 1; }
  exec 9>/var/lock/source-truth-gw-build.lock
  flock -w 900 9 || echo 'WARN: gateway build lock not acquired within 900s — proceeding unserialized'
  rm -rf \$STAGE
  mkdir -p \$STAGE \$GW
  tar xzf /tmp/gw.tar.gz -C \$STAGE
  ( cd \$STAGE && npm ci && npm run build && npm prune --omit=dev ) || { rm -rf \$STAGE; echo 'BOOTSTRAP_FAILED: gateway rebuild'; exit 1; }
  [ -f \$STAGE/dist/index.js ] || { rm -rf \$STAGE; echo 'BOOTSTRAP_FAILED: gateway build produced no dist/index.js'; exit 1; }
  chmod +x \$STAGE/run.sh
  if [ -d \$STAGE/config ]; then mkdir -p /opt/config; rsync -a --delay-updates --delete-after \$STAGE/config/ /opt/config/; rm -rf \$STAGE/config; fi
  rsync -a --delay-updates --delete-after --exclude=/.src_sig \$STAGE/ \$GW/
  rm -rf \$STAGE
  [ -f \$GW/dist/index.js ] || { echo 'BOOTSTRAP_FAILED: gateway dist/index.js missing after publish'; exit 1; }
  echo \"\$NEW_SIG\" > \$GW/.src_sig
  for u in \$(systemctl list-units --plain --no-legend --state=active 'bot-gateway@*' 2>/dev/null | awk '{print \$1}' | grep -Fvx '${GW_UNIT}' || true); do
    echo \"CODE_NEWER_THAN_RUNNING: \$u belongs to another project and is still executing the PREVIOUS gateway dist (on-disk sig is now \$NEW_SIG). Not restarted here on purpose — that would drop its Feishu long-connection; its own activate_gateway.sh run (or provision_index_service.sh around a re-bootstrap) owns the restart.\"
  done
else
  echo 'gateway source unchanged — skipping rebuild'
fi
rm -f /tmp/gw.tar.gz"
fi
REMOTE_CMD="${REMOTE_CMD}
systemctl enable ${GW_UNIT}
systemctl restart ${GW_UNIT}
sleep 2
systemctl is-active ${GW_UNIT}"

say info "activating ${GW_UNIT} on $IID (writing ${GW_ENV_PATH} + enable/restart)"
# Build --parameters as a JSON FILE: commands is an array where EACH element is ONE
# command LINE (SSM joins them with newlines and runs the result as a script). Two bugs
# this avoids: (1) json.dumps([whole_block]) → commands=[["..."]] list-of-list, rejected
# by AWS; (2) json.dumps(whole_block_with_\n) → a single element whose literal "\n" is NOT
# a shell newline, so lines ran glued ("...envnecho", "set: Illegal option -c"). Splitting
# on real newlines into separate array elements is the shape SSM actually expects.
PARAM_FILE="$(mktemp /tmp/gw-ssm-params.XXXXXX)"  # X's at end (BSD/macOS-safe); .json suffix cosmetic (passed as file://)
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
# Default deadline is generous: when BUCKET is set the remote step may rebuild the gateway
# (npm ci + tsc, ~60-120s) before restarting, so 120s could time out mid-build. The build now runs
# in a staging tree and is then rsync-published into /opt/bot-gateway (a few thousand node_modules
# files), and it may WAIT up to 900s on the shared gateway-build lock if another project's
# activation is mid-rebuild — 480s covers the normal case; raise
# GATEWAY_ACTIVATE_TIMEOUT_SECS when two projects are activated concurrently. The no-rebuild path
# (source unchanged) still returns in seconds.
DEADLINE=$(( SECONDS + ${GATEWAY_ACTIVATE_TIMEOUT_SECS:-480} ))
while (( SECONDS < DEADLINE )); do
  sleep 5
  STATUS="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
    --instance-id "$IID" --query Status --output text 2>/dev/null || echo "")"
  case "$STATUS" in
    Success)
      OUT="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
        --instance-id "$IID" --query StandardOutputContent --output text 2>/dev/null || echo "")"
      # The final command is `systemctl is-active`; with the rebuild step there are now log
      # lines BEFORE it, so check the LAST non-empty line == active (not the whole blob).
      LAST="$(printf '%s' "$OUT" | grep -v '^[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
      if [[ "$LAST" == "active" ]]; then
        say ok "${GW_UNIT} is active on $IID"; exit 0
      fi
      say err "${GW_UNIT} started but is not active (last line: ${LAST:-unknown}). Inspect: aws ssm start-session --target $IID ; journalctl -u ${GW_UNIT} -n 50; tail -50 /var/log/bot-gateway-${PROJECT_ID}.log"
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
say err "activate_gateway: timed out waiting for SSM command to finish (${GATEWAY_ACTIVATE_TIMEOUT_SECS:-480}s)"
exit 1
