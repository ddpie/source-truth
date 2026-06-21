#!/usr/bin/env bash
# wait_base_host.sh <region> <instance_id>
# Waits for the BASE index host's bootstrap to finish. The base host has NO bridge yet (projects
# attach later via deploy_project.sh → activate_project.sh), so we do NOT poll a bridge /health —
# we gate on (1) SSM agent online, then (2) the `BOOTSTRAP_DONE` marker in /var/log/index-svc-
# bootstrap.log (or a BOOTSTRAP_FAILED marker → fail fast). The instance is private, so all checks
# run via SSM send-command. Exits 0 once bootstrap is done, non-zero on failure/timeout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
REGION="$1"; IID="$2"
DEADLINE=$(( SECONDS + ${BASE_HOST_TIMEOUT_SECS:-900} ))

# Gate on SSM-agent registration FIRST (bounded), reported DISTINCTLY: every check below runs via
# SSM, so if the agent never registers (NAT egress broken / SSM unreachable), the run would
# otherwise burn the whole timeout blaming a slow build. Fail with a connectivity message instead.
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
  say info "  CONNECTIVITY problem, NOT a slow build: check NAT egress (private subnet → NAT →"
  say info "  ssm/ssmmessages/ec2messages endpoints), the instance IAM profile, and the ssm-agent."
  exit 2
fi

# Poll the bootstrap log for the terminal marker. BOOTSTRAP_DONE = success; a BOOTSTRAP_FAILED
# line means a hard failure → fail fast (re-running won't help until the cause is fixed).
while (( SECONDS < DEADLINE )); do
  CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["tail -3 /var/log/index-svc-bootstrap.log 2>/dev/null | grep -oE \"BOOTSTRAP_DONE|BOOTSTRAP_FAILED[^\\n]*\" | tail -1 || echo PENDING"]' \
    --query Command.CommandId --output text 2>/dev/null || echo "")"
  if [[ -n "$CID" ]]; then
    sleep 6
    OUT="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
      --instance-id "$IID" --query StandardOutputContent --output text 2>/dev/null | tr -d '[:space:]' || echo "")"
    case "$OUT" in
      BOOTSTRAP_DONE) say ok "base host bootstrap complete"; exit 0 ;;
      BOOTSTRAP_FAILED*) say err "base host bootstrap FAILED ($OUT). Inspect /var/log/index-svc-bootstrap.log on $IID."; exit 1 ;;
      *) say info "  bootstrap in progress (${OUT:-pending}) ..." ;;
    esac
  fi
  sleep 20
done
say err "base host did not finish bootstrap within ${BASE_HOST_TIMEOUT_SECS:-900}s."
say info "  Often a still-in-progress cold setup, NOT a failure — RE-RUN deploy-all.sh to resume."
exit 1
