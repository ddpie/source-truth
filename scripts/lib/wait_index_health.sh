#!/usr/bin/env bash
# wait_index_health.sh <region> <instance_id>
# Polls the index-service bridge's /health from inside the instance via SSM
# (the instance is private — not reachable from the deploy host). Exits 0 once
# /health returns healthy:true, non-zero on timeout.
#
# The poll timer starts when the deploy host begins polling, but the instance
# still has to finish a LONG serial bootstrap BEFORE the graph build even starts:
# apt installs, awscli, a repo download + extract, pip, then
# the cold codegraph build, then the bridge's own ~20s cold warmup. On a large repo
# / fresh account this can exceed the old 480s. So the default is 900s and it is
# overridable via INDEX_HEALTH_TIMEOUT_SECS. A timeout is NOT necessarily a failure
# (the instance carries the same ArtifactSig, so simply re-running deploy-all reuses
# it and re-polls — idempotent resume); the message says so.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
REGION="$1"; IID="$2"
DEADLINE=$(( SECONDS + ${INDEX_HEALTH_TIMEOUT_SECS:-900} ))

# Gate on SSM-agent registration FIRST (bounded), and report it DISTINCTLY. The
# health probe runs entirely via SSM send-command; if the agent never registers
# (NAT egress broken / SSM unreachable / agent crash), every send-command no-ops
# and the old code would burn the full timeout then blame a "still-building cold
# graph" — pointing the operator at the wrong cause. So first wait up to
# INDEX_SSM_ONLINE_SECS for PingStatus=Online; if it never comes online, fail with
# a connectivity-specific message instead of the build message.
SSM_DEADLINE=$(( SECONDS + ${INDEX_SSM_ONLINE_SECS:-300} ))
ssm_online=""
while (( SECONDS < SSM_DEADLINE )); do
  PING="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$IID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "")"
  if [[ "$PING" == "Online" ]]; then ssm_online="yes"; break; fi
  say info "  waiting for SSM agent to register (PingStatus=${PING:-none}) ..."
  sleep 10
done
if [[ -z "$ssm_online" ]]; then
  say err "SSM agent never registered for $IID within ${INDEX_SSM_ONLINE_SECS:-300}s."
  say info "  This is a CONNECTIVITY problem, NOT a slow build: the instance can't reach SSM."
  say info "  Check NAT egress (private subnet → NAT → ssm/ssmmessages/ec2messages endpoints),"
  say info "  the instance's IAM profile (AmazonSSMManagedInstanceCore), and that the AMI ships ssm-agent."
  exit 2
fi

while (( SECONDS < DEADLINE )); do
  CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["curl -fs -o /dev/null -w %{http_code} http://127.0.0.1:8080/health || echo 000"]' \
    --query Command.CommandId --output text 2>/dev/null || echo "")"
  if [[ -n "$CID" ]]; then
    sleep 6
    CODE="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
      --instance-id "$IID" --query StandardOutputContent --output text 2>/dev/null | tr -d '[:space:]' || echo "")"
    [[ "$CODE" == "200" ]] && { say ok "index-service healthy"; exit 0; }
    say info "  /health → ${CODE:-pending} (still building/warming) ..."
  fi
  sleep 20
done
say err "index-service did not become healthy within ${INDEX_HEALTH_TIMEOUT_SECS:-900}s."
say info "  This is often a still-in-progress cold build, NOT a failure. The instance carries the"
say info "  current ArtifactSig, so simply RE-RUN deploy-all.sh (without --refresh-index) to reuse"
say info "  it and resume polling. Raise INDEX_HEALTH_TIMEOUT_SECS for very large repos."
exit 1
