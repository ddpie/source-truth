#!/usr/bin/env bash
# test_dashboards.sh — offline tests for the dashboard renderer
# (scripts/lib/render_dashboard.py) and the apply wrapper's dry-run path.
# No AWS calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="$ROOT/scripts/lib/render_dashboard.py"
APPLY="$ROOT/scripts/apply-dashboards.sh"
PROD="$ROOT/infra/monitoring/dashboard.product.json"
SRE="$ROOT/infra/monitoring/dashboard.sre.json"
BYPROJ="$ROOT/infra/monitoring/dashboard.by-project.json"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_dashboards:"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip (no python3)"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- both real templates render to valid JSON with no leftover placeholders ---
# --account-id is always supplied: the SRE template uses ${ACCOUNT_ID} in its alarm-widget
# ARNs (apply-dashboards.sh resolves it via STS), so a render without it would fail-loud on
# the unresolved placeholder. A template that doesn't use it just ignores the value.
for tpl in "$PROD" "$SRE" "$BYPROJ"; do
  name="$(basename "$tpl")"
  out="$(python3 "$RENDER" "$tpl" --region ap-northeast-1 --namespace SourceTruth/Gateway --account-id 000000000000 2>"$TMP/err")"; rc=$?
  check "$name renders (rc 0)" "$rc"
  # valid JSON
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; check "$name output is valid JSON" $?
  # no leftover ${...}
  printf '%s' "$out" | grep -q '\${' && check "$name has leftover placeholder (BAD)" 1 || check "$name has no leftover placeholder" 0
  # region + namespace substituted in
  printf '%s' "$out" | grep -q 'ap-northeast-1'; check "$name substituted region" $?
  printf '%s' "$out" | grep -q 'SourceTruth/Gateway'; check "$name substituted namespace" $?
  # _doc stripped
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "_doc" not in d'; check "$name _doc stripped" $?
done

# --- HARD CONSTRAINT: a type:"log" widget is REJECTED ---
cat > "$TMP/bad-log.json" <<'EOF'
{ "widgets": [
  { "type": "log", "x": 0, "y": 0, "width": 12, "height": 6,
    "properties": { "query": "fields @message", "region": "${REGION}" } } ] }
EOF
python3 "$RENDER" "$TMP/bad-log.json" --region us-east-1 --namespace X/Y >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "type:log widget rejected (nonzero rc)" $?
grep -q -i "log" "$TMP/err"; check "rejection mentions the banned log widget" $?

# --- unresolved placeholder (e.g. ${ACCOUNT_ID} not provided) fails ---
cat > "$TMP/needs-acct.json" <<'EOF'
{ "widgets": [
  { "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
    "properties": { "title": "acct ${ACCOUNT_ID}", "region": "${REGION}",
    "metrics": [["${NAMESPACE}", "X"]] } } ] }
EOF
python3 "$RENDER" "$TMP/needs-acct.json" --region us-east-1 --namespace X/Y >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "unresolved placeholder rejected" $?
grep -q -i "placeholder\|ACCOUNT_ID" "$TMP/err"; check "rejection names the unresolved placeholder" $?
# ...but succeeds when --account-id is given
python3 "$RENDER" "$TMP/needs-acct.json" --region us-east-1 --namespace X/Y --account-id 123456789012 >/dev/null 2>/dev/null; rc=$?
check "resolves once --account-id provided" "$rc"

# --- a typo'd placeholder (lowercase / hyphen) is caught as unresolved, not silently kept ---
cat > "$TMP/typo-ph.json" <<'EOF'
{ "widgets": [
  { "type": "metric", "x": 0, "y": 0, "width": 12, "height": 6,
    "properties": { "title": "oops ${Region}", "region": "${REGION}",
    "metrics": [["${NAMESPACE}", "X"]] } } ] }
EOF
python3 "$RENDER" "$TMP/typo-ph.json" --region us-east-1 --namespace X/Y >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "typo'd placeholder \${Region} caught as unresolved" $?

# --- a namespace value with JSON-special chars is escaped, not corrupting the JSON ---
# (real AWS namespaces can't contain quotes, but the renderer must not produce invalid JSON)
out_q="$(python3 "$RENDER" "$PROD" --region us-east-1 --namespace 'Ns"With/Quote' 2>/dev/null)"; rc=$?
check "namespace with a quote still renders (escaped, rc 0)" "$rc"
printf '%s' "$out_q" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; check "escaped namespace yields valid JSON" $?
printf '%s' "$out_q" | python3 -c 'import json,sys; d=json.load(sys.stdin); s=json.dumps(d); assert "Ns\"With/Quote".replace(chr(34),"") in s.replace(chr(92)+chr(34),"")'; check "escaped value present" $?

# --- missing required flags ---
python3 "$RENDER" "$PROD" --region us-east-1 >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "missing --namespace rejected" $?
python3 "$RENDER" "$PROD" --namespace X/Y >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "missing --region rejected" $?

# --- empty widgets array fails ---
echo '{ "widgets": [] }' > "$TMP/empty.json"
python3 "$RENDER" "$TMP/empty.json" --region us-east-1 --namespace X/Y >/dev/null 2>/dev/null; rc=$?
[[ "$rc" -ne 0 ]]; check "empty widgets array rejected" $?

# --- SRE latency widget keeps p95/p99 extended statistics (not averages) ---
sre_out="$(python3 "$RENDER" "$SRE" --region us-east-1 --namespace X/Y --account-id 000000000000)"
printf '%s' "$sre_out" | grep -q 'p95' && printf '%s' "$sre_out" | grep -q 'p99'; check "SRE keeps p95/p99 extended stats" $?

# --- SRE has the TraceID → Logs-Insights lookup shortcut (text widget, NOT a type:log widget) ---
printf '%s' "$sre_out" | grep -q 'logs-insights' && printf '%s' "$sre_out" | grep -q 'traceId'
check "SRE has the TraceID log-lookup shortcut" $?
# it must be a text widget (cost-free), never type:log (renderer would reject, but assert intent)
printf '%s' "$sre_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); w=[x for x in d["widgets"] if "logs-insights" in json.dumps(x)]; assert w and all(x["type"]=="text" for x in w), "traceId shortcut must be a text widget"'
check "TraceID shortcut is a text widget (no live log re-scan)" $?
# the console link must carry the substituted region (a real deep-link, not a placeholder)
printf '%s' "$sre_out" | grep -q 'us-east-1.console.aws.amazon.com'; check "TraceID shortcut link has the substituted region" $?
# --- by-project dashboard groups KPIs by projectId (SEARCH on …ByProject metrics) ---
bp_out="$(python3 "$RENDER" "$BYPROJ" --region us-east-1 --namespace X/Y --account-id 000000000000)"
printf '%s' "$bp_out" | grep -q 'projectId' && printf '%s' "$bp_out" | grep -q 'ByProject'
check "by-project dashboard groups by projectId (…ByProject SEARCH)" $?
printf '%s' "$bp_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all(w["type"] in ("metric","text") for w in d["widgets"]), "by-project widgets must be metric/text"'
check "by-project widgets are all metric/text (no type:log)" $?

# --- apply wrapper: --dry-run names both dashboards, no AWS ---
dry="$("$APPLY" --dry-run --region us-east-1 2>&1)"; rc=$?
check "apply --dry-run exits 0" "$rc"
[[ "$dry" == *"product"* && "$dry" == *"sre"* && "$dry" == *"by-project"* ]]; check "dry-run names all three dashboards" $?

# --- apply wrapper: --help and unknown flag ---
"$APPLY" --help >/dev/null 2>&1; check "apply --help exits 0" $?
"$APPLY" --bogus >/dev/null 2>&1; rc=$?; [[ "$rc" -ne 0 ]]; check "apply unknown flag exits nonzero" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
