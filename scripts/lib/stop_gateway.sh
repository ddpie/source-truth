#!/usr/bin/env bash
# stop_gateway.sh <region> <instance_id>
#
# Best-effort SYNCHRONOUS stop of ALL bot-gateway@* units on an instance, via SSM.
#
# STATUS: an OPERATOR / recovery tool. It has NO caller in the deploy path, and that is
# deliberate — do not add one without reading this. The Feishu long-connection is a global
# singleton per app (cluster mode: two live clients steal each other's events), so the process
# holding it must be positively dropped before another one starts; but each place in the deploy
# that needs that guarantee now enforces it WHERE it can also undo it:
#   - provision_index_service.sh → rebootstrap_in_place stops the active bot-gateway@* /
#     index-bridge-* units and restarts exactly that captured list INSIDE the same SSM run, so a
#     deploy machine that dies mid-flight cannot leave the host with everything stopped (an
#     external stop-then-bootstrap sequence has no such guarantee — this script stops and hands
#     back nothing, so nobody knows what to start again);
#   - activate_gateway.sh → `systemctl restart bot-gateway@<project>` is itself stop-then-start
#     for that project's own gateway.
# So use this by hand — to drop a stuck long-connection, or to quiesce a host before manual
# surgery — and remember that NOTHING restarts the gateways afterwards: that is on you
# (`systemctl start bot-gateway@<projectId>`).
#
# `systemctl stop` returns only once the process has exited, so when this returns the
# long-connection is down. Best-effort by design: a stop hiccup must not fail the caller.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
REGION="$1"; IID="$2"
[[ -n "$IID" && "$IID" != "None" ]] || { say info "stop_gateway: no instance id — nothing to stop"; exit 0; }

say info "stop_gateway: stopping all bot-gateway@* on $IID (drop Feishu long-connections before make)"
say warn "stop_gateway: nothing restarts them afterwards — start them again with 'systemctl start bot-gateway@<projectId>'"
# 主机上跑的是 per-project 模板实例 bot-gateway@<projectId>（bootstrap.sh 只装 @ 模板，
# 没有裸的 bot-gateway.service）——stop 必须枚举模板实例，停错名字会静默 no-op，
# 旧网关继续持有飞书长连接、与新主机互抢事件。
# Capture the AWS error rather than discarding it (M11): with stderr dropped, an
# InvalidInstanceId (agent unregistered / no NAT egress) is indistinguishable from an
# AccessDeniedException on ssm:SendCommand — and the guessed cause list below cannot tell you
# which one you hit.
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop \"bot-gateway@*\" bot-gateway.service 2>/dev/null || true; systemctl list-units --state=active --plain --no-legend \"bot-gateway@*\" || true"]' \
  --query Command.CommandId --output text 2>&1)" || {
  say warn "stop_gateway: send-command failed for $IID — could not confirm the long-connection is down"
  say warn "  → $(printf '%s' "$CID" | tr '\n' ' ' | cut -c1-300)"
  exit 0
}
if [[ -z "$CID" ]]; then
  say warn "stop_gateway: send-command returned no CommandId for $IID — could not confirm the long-connection is down"
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
