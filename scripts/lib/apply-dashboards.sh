#!/usr/bin/env bash
# apply-dashboards.sh — render the CloudWatch dashboard TEMPLATES and put them
# (monitoring plan 阶段2: 看板代码化).
#
# Source of truth is the JSON templates in infra/monitoring/ (with ${REGION} /
# ${NAMESPACE} placeholders); this renders them via scripts/lib/render_dashboard.py
# and calls `aws cloudwatch put-dashboard` (an upsert — idempotent, re-run to update).
# The renderer ENFORCES the plan's hard constraint (no type:log Insights widgets)
# and that no placeholder is left unresolved, so a bad template fails BEFORE any
# AWS call.
#
# Deploy-time identity (operator / CI), NOT a runtime role: needs
# cloudwatch:PutDashboard (+ GetDashboard for --diff). The dashboards read the
# metrics created by apply-metric-filters.sh (run that first, or there's no data).
#
# Usage:
#   ./scripts/apply-monitoring.sh --only dashboards [--region <r>] [--namespace <ns>] [--prefix <p>] [--dry-run]
#   --region      AWS region (default: DEPLOY_REGION from .local/deploy-config)
#   --namespace   metric namespace (default: metricNamespace from the metric-filters defs)
#   --prefix      dashboard-name prefix (default: source-truth) → "<prefix>-product" / "<prefix>-sre"
#   --dry-run     render + validate; print the dashboard names + body sizes; NO AWS calls
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/env-utils.sh
source "$ROOT/scripts/lib/env-utils.sh"

RENDER="$ROOT/scripts/lib/render_dashboard.py"
DEFS="$ROOT/infra/monitoring/queries/metric-filters/a-class-metrics.json"
CONFIG_FILE="$ROOT/.local/deploy-config"

# Each entry: "<template-file>:<dashboard-name-suffix>"
TEMPLATES=(
  "$ROOT/infra/monitoring/dashboard.product.json:product"
  "$ROOT/infra/monitoring/dashboard.sre.json:sre"
  "$ROOT/infra/monitoring/dashboard.by-project.json:by-project"
)

REGION="" NAMESPACE="" PREFIX="source-truth" DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-monitoring.sh --only dashboards [--region <r>] [--namespace <ns>] [--prefix <p>] [--dry-run]

Renders infra/monitoring/dashboard.*.json templates and put-dashboard's them (idempotent).

  --region <r>     AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --namespace <n>  metric namespace (default: metricNamespace from the metric-filters defs)
  --prefix <p>     dashboard-name prefix (default: source-truth)
  --dry-run        render + validate only; NO AWS calls
  -h, --help       this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "unknown flag: $1"; usage; exit 2 ;;
  esac
done

require_cmd python3 "install Python 3" || exit 1

# Region: explicit flag → deploy-config DEPLOY_REGION (not needed for --dry-run).
if [[ -z "$REGION" ]]; then
  safe_source_env "$CONFIG_FILE"
  REGION="${DEPLOY_REGION:-}"
fi
if [[ "$DRY_RUN" -eq 0 && -z "$REGION" ]]; then
  say err "no region: pass --region or set DEPLOY_REGION in $CONFIG_FILE (or use --dry-run)"
  exit 2
fi
# --dry-run still needs a region to substitute into the template; use a placeholder.
[[ -z "$REGION" ]] && REGION="us-east-1"

# Namespace: explicit flag → the metric-filters defs' metricNamespace (single source,
# so the dashboard reads the SAME namespace the filters write to).
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("metricNamespace",""))' "$DEFS" 2>/dev/null || echo "")"
fi
[[ -n "$NAMESPACE" ]] || { say err "no namespace: pass --namespace or set metricNamespace in $DEFS"; exit 2; }

[[ "$DRY_RUN" -eq 0 ]] && { require_cmd aws "install/configure the AWS CLI" || exit 1; }

# Account id — needed to render alarm-widget ARNs (${ACCOUNT_ID}). Resolve via STS on a
# real run; --dry-run uses a placeholder so the template still substitutes + validates.
ACCOUNT_ID=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
  [[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "None" ]] || { say err "could not resolve AWS account id (sts get-caller-identity)"; exit 2; }
else
  ACCOUNT_ID="000000000000"
fi

# Per-run stderr capture (NOT a fixed /tmp path — two concurrent runs would clobber
# each other and cross-report errors). Cleaned up on exit.
ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT

rc=0
for entry in "${TEMPLATES[@]}"; do
  tpl="${entry%:*}"; suffix="${entry##*:}"
  name="${PREFIX}-${suffix}"
  [[ -f "$tpl" ]] || { say err "template not found: $tpl"; rc=1; continue; }

  # Render + validate (fails loud on banned widget type / unresolved placeholder).
  body="$(python3 "$RENDER" "$tpl" --region "$REGION" --namespace "$NAMESPACE" --account-id "$ACCOUNT_ID")" || {
    say err "render failed for $tpl (see message above) — $name NOT applied"
    rc=1; continue
  }
  bytes="${#body}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    say info "[dry-run] $name  (template: $(basename "$tpl"), body ${bytes} bytes, ns ${NAMESPACE}, region ${REGION})"
    continue
  fi

  if aws cloudwatch put-dashboard --region "$REGION" \
      --dashboard-name "$name" \
      --dashboard-body "$body" \
      --query 'DashboardValidationMessages' --output text 2>"$ERRF"; then
    # put-dashboard returns validation MESSAGES (non-fatal warnings) even on success.
    say ok "put-dashboard $name (${bytes} bytes)"
    if [[ -s "$ERRF" ]]; then
      say warn "  $name validation: $(cat "$ERRF")"
    fi
  else
    say err "put-dashboard $name FAILED: $(head -c 300 "$ERRF" 2>/dev/null)"
    rc=1
  fi
  : > "$ERRF"   # truncate for the next iteration (keep the mktemp'd file)
done

if [[ "$DRY_RUN" -eq 0 && "$rc" -eq 0 ]]; then
  # Derive the name list from TEMPLATES (the single source) — a hand-written list here
  # once omitted the by-project dashboard.
  NAMES=""
  for entry in "${TEMPLATES[@]}"; do NAMES+="${NAMES:+, }${PREFIX}-${entry##*:}"; done
  say ok "dashboards applied: ${NAMES} (region ${REGION})"
  say info "view: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards"
elif [[ "$rc" -ne 0 ]]; then
  say err "some dashboards failed"
fi
exit "$rc"
