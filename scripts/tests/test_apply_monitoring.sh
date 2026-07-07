#!/usr/bin/env bash
# test_apply_monitoring.sh — offline tests for the consolidated monitoring entry point
# (scripts/apply-monitoring.sh): stage selection, ordering, flag forwarding, error paths.
# All via --dry-run; no AWS calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLY="$ROOT/scripts/apply-monitoring.sh"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_apply_monitoring:"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip (no python3)"; exit 0
fi

bash -n "$APPLY"; check "apply-monitoring.sh parses" $?
[[ -x "$APPLY" ]]; check "apply-monitoring.sh is executable" $?

# --- default run covers all four stages, in the Phase 7 order ---
dry="$("$APPLY" --dry-run --region us-east-1 2>&1)"; rc=$?
check "default --dry-run exits 0" "$rc"
[[ "$dry" == *"monitoring: dashboards"* && "$dry" == *"monitoring: metric-filters"* \
   && "$dry" == *"monitoring: alarms"* && "$dry" == *"monitoring: DAU lambda"* ]]
check "default run includes all four stages" $?
# order: dashboards → filters → alarms → dau
python3 - "$dry" <<'PY'
import sys
s = sys.argv[1]
idx = [s.index(m) for m in ("monitoring: dashboards","monitoring: metric-filters","monitoring: alarms","monitoring: DAU lambda")]
sys.exit(0 if idx == sorted(idx) else 1)
PY
check "stages run in Phase 7 order (dashboards→filters→alarms→dau)" $?
# the filters stage covers BOTH defs (A-class rollup + by-project companions)
[[ "$dry" == *"QuestionsReceived"* && "$dry" == *"QuestionsReceivedByProject"* ]]
check "filters stage applies A-class AND by-project defs" $?
# dashboards stage names all three dashboards
[[ "$dry" == *"product"* && "$dry" == *"sre"* && "$dry" == *"by-project"* ]]
check "dashboards stage names all three dashboards" $?

# --- --only runs exactly the selected stage(s) ---
only="$("$APPLY" --dry-run --region us-east-1 --only dashboards 2>&1)"
[[ "$only" == *"monitoring: dashboards"* && "$only" != *"monitoring: alarms"* \
   && "$only" != *"monitoring: metric-filters"* && "$only" != *"monitoring: DAU lambda"* ]]
check "--only dashboards runs only that stage" $?
two="$("$APPLY" --dry-run --region us-east-1 --only alarms --only dau 2>&1)"
[[ "$two" == *"monitoring: alarms"* && "$two" == *"monitoring: DAU lambda"* \
   && "$two" != *"monitoring: dashboards"* ]]
check "--only is repeatable (alarms+dau)" $?

# --- stage flags forwarded on a single-stage run; rejected on multi-stage ---
fwd="$("$APPLY" --dry-run --region us-east-1 --only dashboards --prefix myprefix 2>&1)"; rc=$?
check "single-stage extra flag accepted (rc 0)" "$rc"
[[ "$fwd" == *"myprefix-product"* ]]; check "extra flag reaches the stage script (--prefix)" $?
"$APPLY" --dry-run --region us-east-1 --prefix myprefix >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]]; check "extra flag without single --only rejected" $?

# --- error paths ---
"$APPLY" --only bogus >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]]; check "unknown --only stage rejected" $?
"$APPLY" --help >/dev/null 2>&1; check "--help exits 0" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
