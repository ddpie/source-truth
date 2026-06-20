#!/usr/bin/env bash
# apply-alarms.sh — create the SNS topic + CloudWatch alarms (monitoring plan 阶段3:
# 关键健康事件主动报警).
#
# Source of truth is config/alarm-thresholds.json (operator-tunable knobs) + the
# metric-filters that produce the backing metrics. This:
#   1. ensures an SNS topic exists (idempotent create — returns the existing ARN);
#   2. renders the alarm plan via scripts/lib/render_alarms.py (fails loud on a bad
#      threshold/operator before any AWS call);
#   3. put-metric-alarm for each (idempotent upsert), wiring the topic as the action.
#
# SNS SUBSCRIPTION IS MANUAL: this creates the topic but does NOT subscribe anyone —
# email/webhook subscriptions need a confirmation handshake. After running, subscribe
# with e.g.:
#   aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint you@x
# then click the confirmation link. The script prints the topic ARN + this hint.
#
# Deploy-time identity (operator / CI), NOT a runtime role: needs
# cloudwatch:PutMetricAlarm, sns:CreateTopic, sns:GetTopicAttributes.
#
# Usage:
#   ./scripts/apply-alarms.sh [--region <r>] [--namespace <ns>] [--prefix <p>] [--topic-name <n>] [--dry-run]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/env-utils.sh
source "$ROOT/scripts/lib/env-utils.sh"

RENDER="$ROOT/scripts/lib/render_alarms.py"
THRESHOLDS="$ROOT/config/alarm-thresholds.json"
# Namespace is read from the ALARM metric defs (the metrics these alarms actually consume),
# not the a-class dashboard defs — so a future namespace split can't silently point the
# alarms at a namespace with no data (cross-review). Both files currently share the namespace.
DEFS="$ROOT/infra/monitoring/queries/metric-filters/alarm-metrics.json"
CONFIG_FILE="$ROOT/.local/deploy-config"

REGION="" NAMESPACE="" PREFIX="source-truth" TOPIC_NAME="source-truth-alarms" DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-alarms.sh [--region <r>] [--namespace <ns>] [--prefix <p>] [--topic-name <n>] [--dry-run]

Ensures the SNS topic + creates CloudWatch alarms from config/alarm-thresholds.json (idempotent).

  --region <r>      AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --namespace <n>   metric namespace (default: metricNamespace from the metric-filters defs)
  --prefix <p>      alarm-name prefix (default: source-truth)
  --topic-name <n>  SNS topic name (default: source-truth-alarms)
  --dry-run         render + validate; print the plan; NO AWS calls
  -h, --help        this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --topic-name) TOPIC_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "unknown flag: $1"; usage; exit 2 ;;
  esac
done

require_cmd python3 "install Python 3" || exit 1
[[ -f "$THRESHOLDS" ]] || { say err "alarm thresholds not found: $THRESHOLDS"; exit 1; }

if [[ -z "$REGION" ]]; then
  safe_source_env "$CONFIG_FILE"
  REGION="${DEPLOY_REGION:-}"
fi
if [[ "$DRY_RUN" -eq 0 && -z "$REGION" ]]; then
  say err "no region: pass --region or set DEPLOY_REGION in $CONFIG_FILE (or use --dry-run)"
  exit 2
fi

# Namespace from the metric-filters defs (single source — alarms read what filters write).
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("metricNamespace",""))' "$DEFS" 2>/dev/null || echo "")"
fi
[[ -n "$NAMESPACE" ]] || { say err "no namespace: pass --namespace or set metricNamespace in $DEFS"; exit 2; }

# Ensure the alarm BACKING metric-filters exist FIRST (deploy-ordering safety, cross-review).
# The LogPipelineStalled alarm uses treatMissingData=breaching on GatewayHeartbeat; if that
# filter doesn't exist yet, the alarm would sit in ALARM from creation (a never-published
# metric reads as missing → breaching) and false-page until the metric first appears. Applying
# the dense alarm filters here (idempotent) guarantees the metrics are defined before the
# alarms reference them — the operator can't get the order wrong. Skipped in --dry-run.
if [[ "$DRY_RUN" -eq 0 ]]; then
  say step "ensuring alarm backing metric-filters exist (deploy-order safety)"
  if ! bash "$ROOT/scripts/apply-metric-filters.sh" --region "$REGION" --defs "$DEFS"; then
    say err "could not apply alarm metric-filters ($DEFS) — alarms would watch non-existent metrics; aborting"
    exit 1
  fi
fi

# Ensure the SNS topic (create-topic is idempotent; returns the ARN either way). Skipped
# in dry-run (no AWS), where we render WITHOUT a topic arn so the plan is still printable.
TOPIC_ARN=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd aws "install/configure the AWS CLI" || exit 1
  TOPIC_ARN="$(aws sns create-topic --region "$REGION" --name "$TOPIC_NAME" \
    --query TopicArn --output text 2>/dev/null || echo "")"
  if [[ -z "$TOPIC_ARN" || "$TOPIC_ARN" == "None" ]]; then
    say err "could not create/find SNS topic '$TOPIC_NAME' (need sns:CreateTopic)"
    exit 1
  fi
  say ok "SNS topic ready: $TOPIC_ARN"
fi

# Render + validate the alarm plan (fails loud → abort before any put).
TOPIC_ARG=()
[[ -n "$TOPIC_ARN" ]] && TOPIC_ARG=(--topic-arn "$TOPIC_ARN")
PLAN="$(python3 "$RENDER" "$THRESHOLDS" --namespace "$NAMESPACE" --prefix "$PREFIX" "${TOPIC_ARG[@]}")" || {
  say err "alarm config invalid (see message above) — nothing applied"
  exit 1
}
COUNT="$(printf '%s\n' "$PLAN" | grep -c . || true)"
say info "rendered $COUNT alarm(s) in namespace $NAMESPACE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  say step "[dry-run] would put-metric-alarm (region: ${REGION:-<unset>}):"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pretty="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  {n}  [{sev}]  {m} {op} {t} ({st}/{p}s x{e}, missing={miss})".format(
    n=d["alarmName"], sev=d["severity"], m=d["metricName"], op=d["comparisonOperator"],
    t=d["threshold"], st=d["statistic"], p=d["period"], e=d["evaluationPeriods"],
    miss=d["treatMissingData"]))
' <<< "$line")"
    say info "$pretty"
  done <<< "$PLAN"
  say warn "[dry-run] SNS topic NOT created and alarms have NO actions wired (real run wires the topic)"
  exit 0
fi

rc=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Extract args as TAB-separated fields (descriptions contain spaces, so split on TAB
  # not whitespace; safe against quotes/metachars since the value travels via stdin).
  IFS=$'\t' read -r aname metric stat period evalp dpa thr cmp missing desc < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
fields = [d["alarmName"], d["metricName"], d["statistic"], d["period"], d["evaluationPeriods"],
          d["datapointsToAlarm"], d["threshold"], d["comparisonOperator"], d["treatMissingData"],
          d.get("alarmDescription", "")]
print("\t".join(str(f) for f in fields))
' <<< "$line")
  actions_arg=()
  [[ -n "$TOPIC_ARN" ]] && actions_arg=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN")
  if aws cloudwatch put-metric-alarm --region "$REGION" \
      --alarm-name "$aname" \
      --namespace "$NAMESPACE" \
      --metric-name "$metric" \
      --statistic "$stat" \
      --period "$period" \
      --evaluation-periods "$evalp" \
      --datapoints-to-alarm "$dpa" \
      --threshold "$thr" \
      --comparison-operator "$cmp" \
      --treat-missing-data "$missing" \
      --alarm-description "$desc" \
      "${actions_arg[@]}" >/dev/null 2>&1; then
    say ok "put-metric-alarm $aname"
  else
    say err "put-metric-alarm $aname FAILED"
    rc=1
  fi
done <<< "$PLAN"

if [[ "$rc" -eq 0 ]]; then
  say ok "all alarms applied (topic: $TOPIC_ARN)"
  say warn "SUBSCRIBE someone or no one is paged: aws sns subscribe --region $REGION --topic-arn $TOPIC_ARN --protocol email --notification-endpoint you@example.com  (then confirm the email)"
else
  say err "some alarms failed"
fi
exit "$rc"
