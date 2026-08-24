#!/usr/bin/env bash
# trace.sh — pull the FULL cross-VM timeline for one traceId, both sides, merged.
#
# A single question spans TWO log groups: the bot-gateway (/source-truth/bot-gateway, on the
# index host) and the agent INSIDE the AgentCore microVM
# (/aws/bedrock-agentcore/runtimes/<runtime>-DEFAULT). Both stamp the same `traceId`
# (newTraceId() on the gateway → passed in the invoke payload → the agent's _plog/_perf echo
# it), so they join into one timeline. This wraps the two Logs-Insights queries + the merge so
# an operator types ONE thing:
#
#   ./scripts/trace.sh st-00000000000000000000000000000000
#
# Everything else (region, both log group names, the time window, the query, sorting) is
# resolved automatically. Region + runtime are read from .local/deploy-config; override with
# --region / --since / --runtime if needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/.local/deploy-config"

TRACE=""
REGION=""
SINCE_HOURS=6          # how far back to scan (a trace is minutes long; 6h covers "the one I just ran")
RUNTIME_ID=""
RAW=false              # --raw: dump each side's events as-is (no merge), for debugging

usage() {
  cat <<EOF
Usage: ./scripts/trace.sh <traceId> [--region <r>] [--since-hours N] [--runtime <id>] [--raw]

Pulls the full gateway+agent timeline for one traceId, merged by timestamp.
  <traceId>        e.g. st-00000000000000000000000000000000 (from a card footer / answer_* log)
  --region         AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --since-hours    how far back to scan (default: 6)
  --runtime        AgentCore runtime id (default: derived from AGENT_RUNTIME_ARN in config)
  --raw            print each side separately, unmerged
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --since-hours) SINCE_HOURS="$2"; shift 2 ;;
    --runtime) RUNTIME_ID="$2"; shift 2 ;;
    --raw) RAW=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *) TRACE="$1"; shift ;;
  esac
done

[[ -n "$TRACE" ]] || { echo "ERROR: traceId required" >&2; usage >&2; exit 2; }

# Read region + runtime from persisted deploy config (best-effort).
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG" 2>/dev/null || true
fi
REGION="${REGION:-${DEPLOY_REGION:-}}"
[[ -n "$REGION" ]] || { echo "ERROR: --region required (and not in $CONFIG)" >&2; exit 2; }

# Derive the runtime id from the ARN (…:runtime/<id>) if not given. The multi-project
# deploy writes namespaced keys RUNTIME_ARN_<pid>; the legacy single AGENT_RUNTIME_ARN
# is a fallback only. With several projects, pick the first namespaced key (best-effort;
# pass --runtime to disambiguate) and say which one was picked.
if [[ -z "$RUNTIME_ID" ]]; then
  ARN="${AGENT_RUNTIME_ARN:-${RUNTIME_ARN:-}}"
  if [[ -z "$ARN" && -f "$CONFIG" ]]; then
    _arn_line="$(grep -E '^RUNTIME_ARN_[A-Za-z0-9_]+=' "$CONFIG" | head -1 || true)"
    if [[ -n "$_arn_line" ]]; then
      ARN="${_arn_line#*=}"; ARN="${ARN#\'}"; ARN="${ARN%\'}"
      _n="$(grep -cE '^RUNTIME_ARN_[A-Za-z0-9_]+=' "$CONFIG" || true)"
      [[ "${_n:-1}" -gt 1 ]] && echo "note: multiple RUNTIME_ARN_* in config — using ${_arn_line%%=*} (pass --runtime to override)" >&2
    fi
  fi
  RUNTIME_ID="${ARN##*/}"
fi

GW_LG="/source-truth/bot-gateway"
# The AgentCore runtime log group ends with -DEFAULT; discover it by prefix so a suffix
# change doesn't break us. Falls back to the conventional name if discovery returns nothing.
RT_LG=""
if [[ -n "$RUNTIME_ID" ]]; then
  RT_LG="$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/${RUNTIME_ID}" \
    --query 'logGroups[0].logGroupName' --output text 2>/dev/null || echo "")"
  [[ "$RT_LG" == "None" ]] && RT_LG=""
fi

# Time window: Logs Insights needs epoch seconds. Date math without GNU-only flags:
END="$(date +%s)"
START=$(( END - SINCE_HOURS * 3600 ))

# One Logs-Insights run over a log group, filtered to this traceId, returning ts+message.
# Returns NDJSON lines: {"t": <epoch_ms_or_iso>, "src": "...", "msg": "..."} for merging.
run_insights() {  # <log-group> <src-label>
  local lg="$1" src="$2" qid status
  [[ -n "$lg" ]] || return 0
  qid="$(aws logs start-query --region "$REGION" \
    --log-group-name "$lg" \
    --start-time "$START" --end-time "$END" \
    --query-string "fields @timestamp, @message | filter @message like /$TRACE/ | sort @timestamp asc | limit 1000" \
    --query 'queryId' --output text 2>/dev/null || echo "")"
  [[ -n "$qid" && "$qid" != "None" ]] || { echo "  (no query for $src — log group $lg missing?)" >&2; return 0; }
  # Poll until Complete (Insights is async).
  for _ in $(seq 1 30); do
    status="$(aws logs get-query-results --region "$REGION" --query-id "$qid" --query 'status' --output text 2>/dev/null || echo "")"
    [[ "$status" == "Complete" || "$status" == "Failed" || "$status" == "Cancelled" ]] && break
    sleep 1
  done
  aws logs get-query-results --region "$REGION" --query-id "$qid" --output json 2>/dev/null \
    | SRC="$src" python3 -c '
import os, sys, json
src = os.environ["SRC"]
d = json.load(sys.stdin)
for row in d.get("results", []):
    cells = {c["field"]: c["value"] for c in row}
    ts = cells.get("@timestamp", "")
    msg = cells.get("@message", "").rstrip()
    print(json.dumps({"ts": ts, "src": src, "msg": msg}))
'
}

echo "── trace $TRACE (region $REGION, last ${SINCE_HOURS}h) ──" >&2
echo "   gateway: $GW_LG" >&2
echo "   agent:   ${RT_LG:-<not found — runtime id ${RUNTIME_ID:-unknown}>}" >&2
echo >&2

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
run_insights "$GW_LG" "GW " >> "$TMP"
run_insights "$RT_LG" "AGT" >> "$TMP"

if [[ ! -s "$TMP" ]]; then
  echo "no log lines found for traceId $TRACE in the last ${SINCE_HOURS}h." >&2
  echo "  • is the traceId correct? (copy from the card footer or an answer_* log line)" >&2
  echo "  • try --since-hours 24, or check the agent log group exists yet (it appears after the first invoke)." >&2
  exit 1
fi

if [[ "$RAW" == true ]]; then
  cat "$TMP"
  exit 0
fi

# Merge both sides by @timestamp (lexical sort works on ISO-8601), print a compact timeline.
sort -t'"' -k4 "$TMP" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    ts = e.get("ts", "")[:23]
    src = e.get("src", "?")
    msg = e.get("msg", "")
    # Pretty: if the message is one of our JSON log lines, show event + a few key fields.
    show = msg
    s = msg.find("{")
    if s != -1:
        try:
            o = json.loads(msg[s:])
            if isinstance(o, dict) and ("event" in o or "perf" in o):
                ev = o.get("event", "perf" if o.get("perf") else "?")
                extra = {k: o[k] for k in ("status","detail","error","reason","tool","latencyMs","ttfbMs","numToolCalls","toolErrors","turnCount","evidenceCitationCount","num_turns","cache_read") if k in o}
                show = ev + ("  " + json.dumps(extra, ensure_ascii=False) if extra else "")
        except Exception:
            pass
    print(f"{ts}  {src}  {show[:300]}")
'
