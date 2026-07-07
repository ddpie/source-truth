#!/usr/bin/env bash
# test_metric_filters.sh — offline tests for the A-class metric-filter renderer
# (scripts/lib/render_metric_filters.py) and the apply stage's dry-run path
# (scripts/lib/apply-metric-filters.sh, dispatched by scripts/apply-monitoring.sh).
# No AWS calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="$ROOT/scripts/lib/render_metric_filters.py"
APPLY="$ROOT/scripts/lib/apply-metric-filters.sh"
DEFS="$ROOT/infra/monitoring/queries/metric-filters/a-class-metrics.json"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_metric_filters:"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip (no python3)"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- the real defs file renders cleanly and emits one plan line per metric ---
out="$(python3 "$RENDER" "$DEFS" "/source-truth/bot-gateway" 2>"$TMP/err")"; rc=$?
check "real defs render with rc 0" "$rc"
n_lines="$(printf '%s\n' "$out" | grep -c . || true)"
n_metrics="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["metrics"]))' "$DEFS")"
[[ "$n_lines" == "$n_metrics" ]]; check "one plan line per metric ($n_lines == $n_metrics)" $?

# every plan line is valid JSON carrying the required put-metric-filter args
bad=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["filterName"] and d["logGroupName"] and d["filterPattern"]
mt=d["metricTransformations"]; assert isinstance(mt,list) and mt
t=mt[0]; assert t["metricName"] and t["metricNamespace"] and t["metricValue"]
' "$line" 2>/dev/null || bad=1
done <<< "$out"
check "each plan line has required put-metric-filter fields" "$bad"

# log group is threaded into every plan
printf '%s\n' "$out" | python3 -c 'import json,sys; assert all(json.loads(l)["logGroupName"]=="/source-truth/bot-gateway" for l in sys.stdin if l.strip())'
check "log group threaded into every plan" $?

# --- the alarm-backing defs render too, and carry the DENSE AnswerFailedTotal counter
# (no dimensions + defaultValue:0) that AnswerFailedBurst alarms on (closed gap) ---
ALARM_DEFS="$ROOT/infra/monitoring/queries/metric-filters/alarm-metrics.json"
aout="$(python3 "$RENDER" "$ALARM_DEFS" "/source-truth/bot-gateway" 2>"$TMP/aerr")"; check "alarm-metrics defs render with rc 0" $?
printf '%s\n' "$aout" | python3 -c '
import json,sys
byname={}
for l in sys.stdin:
    if not l.strip(): continue
    d=json.loads(l); byname[d["filterName"]]=d
t=byname.get("AnswerFailedTotal"); assert t is not None, "AnswerFailedTotal filter missing"
mt=t["metricTransformations"][0]
assert mt.get("defaultValue")==0, "AnswerFailedTotal must be dense (defaultValue:0)"
assert "dimensions" not in mt, "AnswerFailedTotal must have NO dimensions (else not dense/alarmable)"
'; check "AnswerFailedTotal is dense (defaultValue:0, no dimensions)" $?

# --- CONTRACT: defaultValue + dimensions together must FAIL loud ---
cat > "$TMP/bad-both.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "Bad", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1",
    "defaultValue": 0, "dimensions": { "k": "$.k" } } ] }
EOF
python3 "$RENDER" "$TMP/bad-both.json" "/x" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "defaultValue + dimensions rejected (nonzero rc)" $?
grep -q -i "defaultValue" "$TMP/err"; check "rejection message mentions defaultValue" $?

# --- CONTRACT: missing required field fails ---
cat > "$TMP/bad-missing.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "NoPattern", "event": "e", "metricValue": "1" } ] }
EOF
python3 "$RENDER" "$TMP/bad-missing.json" "/x" >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "missing filterPattern rejected" $?

# --- CONTRACT: duplicate metric name fails ---
cat > "$TMP/bad-dup.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "Dup", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1", "defaultValue": 0 },
  { "name": "Dup", "event": "f", "filterPattern": "{ $.y = 1 }", "metricValue": "1", "defaultValue": 0 } ] }
EOF
python3 "$RENDER" "$TMP/bad-dup.json" "/x" >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "duplicate metric name rejected" $?

# --- valid dimensioned (no defaultValue) renders and carries the dimension ---
cat > "$TMP/ok-dim.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "ByReason", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1",
    "unit": "Count", "dimensions": { "reason": "$.reason" } } ] }
EOF
out2="$(python3 "$RENDER" "$TMP/ok-dim.json" "/x")"; rc=$?
check "valid dimensioned metric renders (rc 0)" "$rc"
printf '%s' "$out2" | python3 -c 'import json,sys; t=json.load(sys.stdin)["metricTransformations"][0]; assert t["dimensions"]=={"reason":"$.reason"}; assert "defaultValue" not in t'
check "dimension carried, no defaultValue injected" $?

# --- CONTRACT: bad unit (not a CloudWatch StandardUnit) fails ---
cat > "$TMP/bad-unit.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "BadUnit", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1",
    "defaultValue": 0, "unit": "Millis" } ] }
EOF
python3 "$RENDER" "$TMP/bad-unit.json" "/x" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "invalid unit rejected" $?
grep -q -i "StandardUnit\|unit" "$TMP/err"; check "unit rejection message mentions unit" $?

# --- CONTRACT: dimension value not a $.field selector fails ---
cat > "$TMP/bad-dim.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "BadDim", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1",
    "dimensions": { "k": "literal-not-selector" } } ] }
EOF
python3 "$RENDER" "$TMP/bad-dim.json" "/x" >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "non-\$.field dimension value rejected" $?

# --- CONTRACT: metricValue neither number nor $.field fails ---
cat > "$TMP/bad-mv.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "BadMV", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "bogus" } ] }
EOF
python3 "$RENDER" "$TMP/bad-mv.json" "/x" >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "non-numeric non-selector metricValue rejected" $?

# --- a $.field metricValue is accepted (latency-style) ---
cat > "$TMP/ok-mv.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "Lat", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "$.latencyMs", "unit": "Milliseconds" } ] }
EOF
python3 "$RENDER" "$TMP/ok-mv.json" "/x" >/dev/null 2>/dev/null; check "\$.field metricValue accepted" $?

# --- counter WITHOUT defaultValue warns (to stderr) but still renders ---
cat > "$TMP/sparse.json" <<'EOF'
{ "metricNamespace": "X/Y", "logGroup": "/x", "metrics": [
  { "name": "SparseCounter", "event": "e", "filterPattern": "{ $.x = 1 }", "metricValue": "1" } ] }
EOF
python3 "$RENDER" "$TMP/sparse.json" "/x" >/dev/null 2>"$TMP/warn"; rc=$?
check "sparse counter still renders (rc 0)" "$rc"
grep -q -i "sparse" "$TMP/warn"; check "sparse counter emits a WARN" $?

# --- apply wrapper: --dry-run makes no AWS call and lists every filter ---
dry="$("$APPLY" --dry-run --region us-east-1 2>&1)"; rc=$?
check "apply --dry-run exits 0" "$rc"
[[ "$dry" == *"dry-run"* && "$dry" == *"QuestionsReceived"* && "$dry" == *"CardHealth"* ]]
check "dry-run prints the rendered plan" $?

# --- apply wrapper: --help and unknown flag ---
"$APPLY" --help >/dev/null 2>&1; check "apply --help exits 0" $?
"$APPLY" --bogus >/dev/null 2>&1; rc=$?; [[ "$rc" -ne 0 ]]; check "apply unknown flag exits nonzero" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
