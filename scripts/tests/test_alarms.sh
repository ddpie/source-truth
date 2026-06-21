#!/usr/bin/env bash
# test_alarms.sh — offline tests for the alarm renderer (scripts/lib/render_alarms.py)
# and the apply wrapper's dry-run path. No AWS calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="$ROOT/scripts/lib/render_alarms.py"
APPLY="$ROOT/scripts/apply-alarms.sh"
THRESH="$ROOT/config/alarm-thresholds.json"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_alarms:"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip (no python3)"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- the real thresholds render; all enabled alarms emitted ---
out="$(python3 "$RENDER" "$THRESH" --namespace SourceTruth/Gateway 2>"$TMP/err")"; rc=$?
check "real thresholds render (rc 0)" "$rc"
n="$(printf '%s\n' "$out" | grep -c . || true)"
[[ "$n" -eq 4 ]]; check "4 enabled alarms rendered (got $n)" $?
# AnswerFailedBurst must watch the DENSE AnswerFailedTotal (not the sparse dimensioned
# AnswerFailed) so a burst alarm evaluates stably — the documented gap, now closed.
printf '%s\n' "$out" | python3 -c '
import json,sys
m={json.loads(l)["alarmName"]: json.loads(l)["metricName"] for l in sys.stdin if l.strip()}
assert m.get("source-truth-AnswerFailedBurst")=="AnswerFailedTotal", m.get("source-truth-AnswerFailedBurst")
'; check "AnswerFailedBurst watches dense AnswerFailedTotal" $?

# each plan line is valid JSON with required put-metric-alarm fields
bad=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
for k in ("alarmName","metricName","namespace","statistic","period","evaluationPeriods","datapointsToAlarm","threshold","comparisonOperator","treatMissingData"):
    assert k in d, k
' "$line" 2>/dev/null || bad=1
done <<< "$out"
check "each alarm has required put-metric-alarm fields" "$bad"

# prefix applied to alarm names
printf '%s' "$out" | python3 -c 'import json,sys; assert all(json.loads(l)["alarmName"].startswith("source-truth-") for l in sys.stdin if l.strip())'
check "default prefix applied to alarm names" $?

# the liveness backstop watches the HEARTBEAT (not a traffic metric) as a dead-man's switch:
# LessThanThreshold 1 + treatMissingData=breaching → heartbeats present (Sum≥1) → NOT <1 → OK;
# pipeline dead → metric MISSING → breaching → ALARM. The operator MUST be LessThan: a
# GreaterThanOrEqual would fire whenever heartbeats ARE present (inverted — a live deploy
# tripped it on [5,5,1]) and stay OK if the pipeline died to 0/absent. Watching a traffic
# metric would false-page on a quiet night (cross-review HIGH).
printf '%s\n' "$out" | python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
live=[r for r in rows if r["alarmName"].endswith("LogPipelineStalled")]
assert len(live)==1, "LogPipelineStalled missing"
assert live[0]["treatMissingData"]=="breaching", "liveness must be breaching"
assert live[0]["metricName"]=="GatewayHeartbeat", "liveness MUST watch the heartbeat, not a traffic metric"
assert live[0]["comparisonOperator"]=="LessThanThreshold", "liveness is a dead-mans-switch: fire on LOW/absent (LessThan), NOT GreaterThanOrEqual (which pages when ALIVE)"
'
check "liveness backstop = LessThan+breaching on GatewayHeartbeat (dead-mans-switch)" $?

# topic arn wired into actions when provided
printf '%s' "$(python3 "$RENDER" "$THRESH" --namespace X/Y --topic-arn arn:aws:sns:r:1:t)" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["alarmActions"]==["arn:aws:sns:r:1:t"] and r["okActions"]==["arn:aws:sns:r:1:t"]'
check "topic arn wired into alarm+ok actions" $?

# no topic arn → no actions key (alarm created but pages no one)
printf '%s' "$(python3 "$RENDER" "$THRESH" --namespace X/Y)" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert "alarmActions" not in r'
check "no topic arn → no actions wired" $?

# --- CONTRACT violations fail loud ---
mk() { printf '%s' "$1" > "$TMP/t.json"; }

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Bogus", "comparisonOperator": "GreaterThanThreshold", "threshold": 1 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "invalid statistic rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "Nope", "threshold": 1 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "invalid comparisonOperator rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": "notnum" } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "non-numeric threshold rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1, "treatMissingData": "weird" } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "invalid treatMissingData rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1, "evaluationPeriods": 1, "datapointsToAlarm": 5 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "datapointsToAlarm > evaluationPeriods rejected" $?

mk '{ "alarms": [ { "name": "Dup", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1 }, { "name": "Dup", "metricName": "N", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 2 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "duplicate alarm name rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "comparisonOperator": "GreaterThanThreshold", "threshold": 1 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "missing statistic rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1, "periodSeconds": 45 } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "period not 10/30/multiple-of-60 rejected" $?

mk '{ "alarms": [ { "name": "A", "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1, "evaluationPeriods": true } ] }'
python3 "$RENDER" "$TMP/t.json" --namespace X/Y >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "bool-as-int evaluationPeriods rejected" $?

# missing namespace fails
python3 "$RENDER" "$THRESH" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "missing --namespace rejected" $?

# all-disabled config → zero plans (rc 0, empty)
mk '{ "alarms": [ { "name": "Off", "enabled": false, "metricName": "M", "statistic": "Sum", "comparisonOperator": "GreaterThanThreshold", "threshold": 1 } ] }'
out2="$(python3 "$RENDER" "$TMP/t.json" --namespace X/Y 2>/dev/null)"; rc=$?
[[ "$rc" -eq 0 && -z "$out2" ]]; check "all-disabled config renders zero plans (rc 0)" $?

# --- apply wrapper dry-run / help / unknown flag ---
dry="$("$APPLY" --dry-run --region us-east-1 2>&1)"; rc=$?
check "apply --dry-run exits 0" "$rc"
[[ "$dry" == *"ToolcallLeakDetected"* && "$dry" == *"LogPipelineStalled"* ]]; check "dry-run lists alarms" $?
[[ "$dry" == *"NOT created"* ]]; check "dry-run notes no SNS/actions" $?
"$APPLY" --help >/dev/null 2>&1; check "apply --help exits 0" $?
"$APPLY" --bogus >/dev/null 2>&1; [[ $? -ne 0 ]]; check "apply unknown flag exits nonzero" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
