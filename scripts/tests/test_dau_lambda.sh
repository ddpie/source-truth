#!/usr/bin/env bash
# test_dau_lambda.sh — offline tests for the DAU pre-aggregation Lambda's PURE helpers
# (infra/monitoring/lambda/dau_preaggregate.py: build_query / compute_window / parse_dau).
# No AWS, no boto3 (the helpers are import-safe without it; boto3 is imported only inside
# handler()).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAMBDA_DIR="$ROOT/infra/monitoring/lambda"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_dau_lambda:"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip (no python3)"; exit 0
fi

# All assertions in one python3 invocation (the module imports cleanly without boto3).
python3 - "$LAMBDA_DIR" <<'PY'
import sys, importlib.util
from datetime import datetime, timezone, date

lambda_dir = sys.argv[1]
spec = importlib.util.spec_from_file_location("dau_preaggregate", f"{lambda_dir}/dau_preaggregate.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)  # must not raise (no top-level boto3 import)

fails = []
def ck(name, cond):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}")
    if not cond: fails.append(name)

# build_query: event-name filter (robust), NOT a boolean `metric = 1` match
q = m.build_query()
ck("build_query filters on event=question_received", 'event = "question_received"' in q)
ck("build_query does NOT use the fragile boolean `metric = 1`", "metric = 1" not in q and "metric = true" not in q)
ck("build_query count_distinct(hashUserId) as dau", "count_distinct(hashUserId) as dau" in q)

# compute_window: a full 24h local day, Tokyo +9
now = datetime(2026, 6, 20, 3, 0, tzinfo=timezone.utc)
start, end = m.compute_window(date(2026, 6, 19), "Asia/Tokyo", now)
ck("window is exactly 24h", end - start == 24 * 3600)
# Tokyo 2026-06-19 00:00 = 2026-06-18 15:00 UTC = epoch 1750258800
expected_start = int(datetime(2026, 6, 18, 15, 0, tzinfo=timezone.utc).timestamp())
ck("Tokyo local-midnight start is correct (UTC-9h)", start == expected_start)
# UTC zone: midnight is midnight
s_utc, e_utc = m.compute_window(date(2026, 6, 19), "UTC", now)
ck("UTC window starts at UTC midnight", s_utc == int(datetime(2026, 6, 19, tzinfo=timezone.utc).timestamp()))

# parse_dau: one stats row → (dau, weak_rows)
rows = [[{"field": "dau", "value": "42"}, {"field": "weak_rows", "value": "3"}]]
ck("parse_dau reads dau + weak_rows", m.parse_dau(rows) == (42, 3))
# empty results → (0, 0)  (the explicit-zero contract)
ck("parse_dau empty → (0,0)", m.parse_dau([]) == (0, 0))
# missing/blank fields → 0, never crash
ck("parse_dau tolerates missing fields", m.parse_dau([[{"field": "dau", "value": ""}]]) == (0, 0))
# float-string value (Insights returns numbers as strings, sometimes "42.0")
ck("parse_dau tolerates float-string", m.parse_dau([[{"field": "dau", "value": "42.0"}]]) == (42, 0))

ck("NAMESPACE/METRIC constants", m.NAMESPACE == "SourceTruth/Gateway" and m.METRIC_NAME == "DAU")

sys.exit(1 if fails else 0)
PY
rc=$?
check "dau_preaggregate pure helpers" "$rc"

# --- apply-dau-lambda.sh: dry-run / help / unknown flag (no AWS) ---
APPLY="$ROOT/scripts/apply-dau-lambda.sh"
dry="$("$APPLY" --dry-run --region us-east-1 2>&1)"; rc=$?
check "apply --dry-run exits 0" "$rc"
[[ "$dry" == *"source-truth-dau-preaggregate"* && "$dry" == *"schedule"* ]]; check "dry-run prints the plan" $?
"$APPLY" --help >/dev/null 2>&1; check "apply --help exits 0" $?
"$APPLY" --bogus >/dev/null 2>&1; rc=$?; [[ "$rc" -ne 0 ]]; check "apply unknown flag exits nonzero" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
