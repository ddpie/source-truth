#!/usr/bin/env bash
# wait_index_health.sh <region> <instance_id>
# Polls the index-service bridge's /health from inside the instance via SSM
# (the instance is private — not reachable from the deploy host). Exits 0 once
# /health returns healthy:true, non-zero on timeout. Build+warmup on EFS can
# take several minutes, so we allow up to ~8 min.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
REGION="$1"; IID="$2"
DEADLINE=$(( SECONDS + 480 ))

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
say err "index-service did not become healthy within timeout"
exit 1
