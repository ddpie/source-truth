#!/usr/bin/env bash
# stop_gateway.sh <region> <instance_id>
#
# Best-effort SYNCHRONOUS stop of bot-gateway.service on an instance, via SSM.
# Used to enforce break-before-make for the gateway: the Feishu long-connection is
# a GLOBAL singleton per app (cluster mode — two live clients steal each other's
# events), so before a blue-green refresh terminates the OLD index instance (which
# also runs the gateway), we must positively drop its long-connection FIRST, so it
# can never overlap with the NEW instance's gateway started later (deploy Phase 6).
#
# `systemctl stop` returns only once the process has exited, so when this returns
# the long-connection is down. Best-effort: a stop hiccup must not fail the deploy
# (the subsequent instance terminate drops the connection anyway, just less cleanly).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
REGION="$1"; IID="$2"
[[ -n "$IID" && "$IID" != "None" ]] || { say info "stop_gateway: no instance id — nothing to stop"; exit 0; }

say info "stop_gateway: stopping bot-gateway.service on $IID (drop Feishu long-connection before make)"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop bot-gateway.service 2>/dev/null || true; systemctl is-active bot-gateway.service || true"]' \
  --query Command.CommandId --output text 2>/dev/null || echo "")"
if [[ -z "$CID" ]]; then
  say warn "stop_gateway: send-command failed for $IID (SSM unreachable / instance already gone) — relying on instance terminate to drop the connection"
  exit 0
fi
# Bounded wait for the command to finish so the stop is synchronous wrt the caller.
DEADLINE=$(( SECONDS + ${GATEWAY_STOP_TIMEOUT_SECS:-60} ))
while (( SECONDS < DEADLINE )); do
  sleep 4
  ST="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" \
    --instance-id "$IID" --query Status --output text 2>/dev/null || echo "")"
  case "$ST" in
    Success) say ok "stop_gateway: bot-gateway stopped on $IID"; exit 0 ;;
    Failed|Cancelled|TimedOut) say warn "stop_gateway: stop command $ST on $IID (best-effort; continuing)"; exit 0 ;;
  esac
done
say warn "stop_gateway: timed out confirming stop on $IID (best-effort; continuing)"
exit 0
