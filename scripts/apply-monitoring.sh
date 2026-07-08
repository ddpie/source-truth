#!/usr/bin/env bash
# apply-monitoring.sh — single entry point for the CloudWatch monitoring stack.
#
# Dispatches to the four stage implementations in scripts/lib/ (each idempotent):
#   dashboards : lib/apply-dashboards.sh      — render + put-dashboard the three dashboards
#   filters    : lib/apply-metric-filters.sh  — A-class metric-filters, then the by-project
#                (projectId-dimensioned) companions
#   alarms     : lib/apply-alarms.sh          — SNS topic + alarms (ensures its dense backing
#                filters first)
#   dau        : lib/apply-dau-lambda.sh      — DAU pre-aggregation Lambda + daily schedule
#
# Default (no --only): run ALL stages in the deploy-all Phase 7 order —
# dashboards → filters → by-project filters → alarms → dau — best-effort per stage
# (a stage failure WARNs and the rest still run; exit is nonzero if any failed).
#
# Usage:
#   ./scripts/apply-monitoring.sh [--region <r>] [--dry-run] [--only <stage>]... [stage args]
#   --only <s>   run only this stage (filters|dashboards|alarms|dau); repeatable
#   --region     AWS region (default: DEPLOY_REGION from .local/deploy-config)
#   --dry-run    print each stage's plan; make NO AWS calls
#
# Stage-specific flags (--namespace/--prefix/--topic-name/--defs/--log-group/--list/--tz/
# --schedule) are forwarded UNCHANGED to the stage script — allowed only when exactly ONE
# --only stage is selected (the stages accept different flags, so a multi-stage run with
# extras would hard-fail inside one of them).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

LIB="$ROOT/scripts/lib"
BYPROJ_DEFS="$ROOT/infra/monitoring/queries/metric-filters/by-project-metrics.json"

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-monitoring.sh [--region <r>] [--dry-run] [--only <stage>]... [stage args]

Applies the CloudWatch monitoring stack (idempotent). Default runs every stage in order:
dashboards → metric-filters (A-class + by-project) → alarms → DAU lambda.

  --only <s>    run only this stage: filters | dashboards | alarms | dau  (repeatable)
  --region <r>  AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --dry-run     print each stage's plan; NO AWS calls
  -h, --help    this help

With exactly one --only stage, any further flags are forwarded to that stage's script
(e.g. --only filters --defs <f> --list | --only dashboards --namespace <ns> --prefix <p>
 | --only alarms --topic-name <n> | --only dau --tz <zone> --schedule <cron>).
EOF
}

REGION="" DRY_RUN=0
ONLY=()          # selected stages, in canonical order below
EXTRA=()         # stage-specific flags, forwarded on a single-stage run
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      case "${2:-}" in
        filters|dashboards|alarms|dau) ONLY+=("$2") ;;
        *) say err "unknown --only stage: '${2:-}' (want filters|dashboards|alarms|dau)"; exit 2 ;;
      esac
      shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

# Which stages run? Default = all, in the deploy-all Phase 7 order.
run_stage() { # run_stage <name> : true if <name> was selected (or no --only given)
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local s; for s in "${ONLY[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

# Stage-specific flags only make sense for a single stage (they differ per script).
if [[ ${#EXTRA[@]} -gt 0 ]]; then
  # count DISTINCT selected stages (default = all four)
  # bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
  _distinct=(); while IFS= read -r _line; do _distinct+=("$_line"); done \
    < <(printf '%s\n' "${ONLY[@]:-}" | grep -v '^$' | sort -u)
  if [[ ${#_distinct[@]} -ne 1 ]]; then
    say err "stage-specific flags (${EXTRA[*]}) need exactly one --only stage"
    usage >&2; exit 2
  fi
fi

COMMON=()
[[ -n "$REGION" ]] && COMMON+=(--region "$REGION")
[[ "$DRY_RUN" -eq 1 ]] && COMMON+=(--dry-run)

rc=0
warn_fail() { say warn "  $1 failed (non-fatal) — re-run: ./scripts/apply-monitoring.sh --only $2${REGION:+ --region $REGION}"; rc=1; }

if run_stage dashboards; then
  say step "monitoring: dashboards"
  bash "$LIB/apply-dashboards.sh" "${COMMON[@]}" "${EXTRA[@]}" || warn_fail apply-dashboards dashboards
fi
if run_stage filters; then
  say step "monitoring: metric-filters"
  if [[ ${#EXTRA[@]} -gt 0 ]]; then
    # custom flags (e.g. --defs/--list) → a single forwarded invocation
    bash "$LIB/apply-metric-filters.sh" "${COMMON[@]}" "${EXTRA[@]}" || warn_fail apply-metric-filters filters
  else
    bash "$LIB/apply-metric-filters.sh" "${COMMON[@]}" \
      || warn_fail "apply-metric-filters (log group may not exist until the gateway logs once)" filters
    # Per-project breakdown filters (projectId-dimensioned companions; the by-project
    # dashboard reads these). Separate defs so the rollup metrics stay dense/un-dimensioned.
    bash "$LIB/apply-metric-filters.sh" "${COMMON[@]}" --defs "$BYPROJ_DEFS" \
      || warn_fail "apply-metric-filters (by-project)" filters
  fi
fi
if run_stage alarms; then
  say step "monitoring: alarms"
  bash "$LIB/apply-alarms.sh" "${COMMON[@]}" "${EXTRA[@]}" || warn_fail apply-alarms alarms
fi
if run_stage dau; then
  say step "monitoring: DAU lambda"
  bash "$LIB/apply-dau-lambda.sh" "${COMMON[@]}" "${EXTRA[@]}" || warn_fail apply-dau-lambda dau
fi

if [[ "$rc" -eq 0 ]]; then
  say ok "monitoring applied"
else
  say err "some monitoring stages failed (see warnings above)"
fi
exit "$rc"
