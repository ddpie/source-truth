#!/usr/bin/env bash
# apply-metric-filters.sh — create/update the A-class CloudWatch metric-filters
# on the gateway log group from the single source of metric intent
# (infra/monitoring/queries/metric-filters/a-class-metrics.json).
#
# This is monitoring-plan 阶段1's "make the definitions real": it turns the JSON
# metric definitions into actual CloudWatch metrics so 阶段2 dashboards can read
# cheap pre-extracted metrics (not raw-log scans) and 阶段3 alarms can use them.
#
# Idempotent: `aws logs put-metric-filter` is an upsert keyed by (logGroup,
# filterName), so re-running reconciles. Safe to run any number of times.
#
# Deploy-time identity (operator / CI), NOT a runtime role: requires
# logs:PutMetricFilter (+ logs:DescribeMetricFilters for --list) on the log group.
#
# Usage:
#   ./scripts/apply-metric-filters.sh [--region <r>] [--log-group <g>] [--dry-run] [--list]
#   --region      AWS region (default: DEPLOY_REGION from .local/deploy-config)
#   --log-group   override the log group (default: logGroup from the defs JSON)
#   --dry-run     print the put-metric-filter plan; make NO AWS calls
#   --list        after applying, list the live filters on the group
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/env-utils.sh
source "$ROOT/scripts/lib/env-utils.sh"

DEFS="$ROOT/infra/monitoring/queries/metric-filters/a-class-metrics.json"
RENDER="$ROOT/scripts/lib/render_metric_filters.py"
CONFIG_FILE="$ROOT/.local/deploy-config"

REGION="" LOG_GROUP="" DRY_RUN=0 DO_LIST=0

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-metric-filters.sh [--region <r>] [--log-group <g>] [--dry-run] [--list]

Creates/updates the A-class CloudWatch metric-filters from
infra/monitoring/queries/metric-filters/a-class-metrics.json (idempotent upsert).

  --region <r>     AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --log-group <g>  log group override (default: logGroup field in the defs JSON)
  --dry-run        print the plan; make NO AWS calls
  --list           list the live metric-filters on the group after applying
  -h, --help       this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --log-group) LOG_GROUP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --list) DO_LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "unknown flag: $1"; usage; exit 2 ;;
  esac
done

require_cmd python3 "install Python 3" || exit 1
[[ -f "$DEFS" ]] || { say err "metric defs not found: $DEFS"; exit 1; }

# Region: explicit flag → deploy-config DEPLOY_REGION. (--dry-run does not need it.)
if [[ -z "$REGION" ]]; then
  safe_source_env "$CONFIG_FILE"
  REGION="${DEPLOY_REGION:-}"
fi
if [[ "$DRY_RUN" -eq 0 && -z "$REGION" ]]; then
  say err "no region: pass --region or set DEPLOY_REGION in $CONFIG_FILE (or use --dry-run)"
  exit 2
fi

# Log group: explicit flag → the defs JSON's logGroup field. The defs file is the
# single source so the group name can't drift from the metric-filter intent.
if [[ -z "$LOG_GROUP" ]]; then
  LOG_GROUP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("logGroup",""))' "$DEFS")"
fi
[[ -n "$LOG_GROUP" ]] || { say err "no log group: pass --log-group or set logGroup in $DEFS"; exit 2; }

# Render + validate the plan (the python helper fails loud on any contract violation,
# e.g. defaultValue+dimensions). Capture so a validation failure aborts BEFORE any AWS call.
PLAN="$(python3 "$RENDER" "$DEFS" "$LOG_GROUP")" || {
  say err "metric-filter definitions are invalid (see message above) — nothing applied"
  exit 1
}
COUNT="$(printf '%s\n' "$PLAN" | grep -c . || true)"
say info "rendered $COUNT metric-filter(s) for log group $LOG_GROUP"

if [[ "$DRY_RUN" -eq 1 ]]; then
  say step "[dry-run] would put-metric-filter (region: ${REGION:-<unset>}):"
  # Pretty one line per filter: name → pattern.
  printf '%s\n' "$PLAN" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fn="$(printf '%s' "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["filterName"])')"
    fp="$(printf '%s' "$line" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["filterPattern"])')"
    say info "  $fn  ←  $fp"
  done
  exit 0
fi

require_cmd aws "install/configure the AWS CLI" || exit 1

# Pre-check the log group exists — put-metric-filter on a missing group errors with
# a cryptic message; this gives an actionable one (the group is created by the
# index host's CloudWatch agent on first gateway log line; see bootstrap.sh).
if ! aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)" --output text 2>/dev/null | grep -q '^1$'; then
  say warn "log group '$LOG_GROUP' not found in $REGION — it's created on the first gateway log line."
  say warn "Applying filters anyway will fail; deploy/start the gateway first, then re-run."
fi

rc=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  fn="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["filterName"])')"
  fp="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["filterPattern"])')"
  mt="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["metricTransformations"]))')"
  if aws logs put-metric-filter --region "$REGION" \
      --log-group-name "$LOG_GROUP" \
      --filter-name "$fn" \
      --filter-pattern "$fp" \
      --metric-transformations "$mt" >/dev/null 2>&1; then
    say ok "put-metric-filter $fn"
  else
    say err "put-metric-filter $fn FAILED"
    rc=1
  fi
done <<< "$PLAN"

if [[ "$DO_LIST" -eq 1 ]]; then
  say step "live metric-filters on $LOG_GROUP:"
  aws logs describe-metric-filters --region "$REGION" \
    --log-group-name "$LOG_GROUP" \
    --query 'metricFilters[].filterName' --output text 2>/dev/null || true
fi

[[ "$rc" -eq 0 ]] && say ok "all metric-filters applied" || say err "some metric-filters failed"
exit "$rc"
