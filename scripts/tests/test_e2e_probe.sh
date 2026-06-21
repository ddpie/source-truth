#!/usr/bin/env bash
# test_e2e_probe.sh — offline tests for the e2e probe's pure helpers
# (scripts/e2e-probe.py). No AWS, no network — only the region-priority and
# payload-shape logic, which are pure and were the source of a real bug.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/e2e-probe.py"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_e2e_probe:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }

# import the module by file path (it's a script, not a package).
PY=$(cat <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("e2e_probe", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ARN = "arn:aws:bedrock-agentcore:ap-northeast-1:111122223333:runtime/source_truth_agent-x"

# --- region priority: ARN region must WIN over a mismatched AWS_REGION env ---
# (the real bug: env us-east-1 + Tokyo ARN → ResourceNotFound)
assert m.resolve_region(ARN, None, "us-east-1") == "ap-northeast-1", "env must NOT override ARN region"
assert m.resolve_region(ARN, "eu-west-1", "us-east-1") == "eu-west-1", "--region must win"
assert m.resolve_region("arn:aws:x:::runtime/y", None, "us-east-1") == "us-east-1", "env is fallback when ARN has no region"
assert m.resolve_region("", "ap-south-1", None) == "ap-south-1", "explicit wins with empty arn"
assert m.resolve_region("", None, None) == "", "no source → empty (caller skips)"

# --- payload shape MUST match gateway (bot-gateway/src/sigv4.ts) ---
p = m.build_payload("Q?", "st-e2eabc", ["repoA", "repoB"])
assert p == {"prompt": "Q?", "traceId": "st-e2eabc", "repos": ["repoA", "repoB"]}, p
# repos omitted entirely when empty (single-repo / zero-config wire shape)
p2 = m.build_payload("Q?", "st-x", [])
assert p2 == {"prompt": "Q?", "traceId": "st-x"}, p2
assert "repos" not in p2, "empty repos must be omitted, not []"
# never leaks fields the agent does not read (e.g. projectId)
assert set(p2.keys()) <= {"prompt", "traceId", "repos"}, p2.keys()
print("PYOK")
PYEOF
)

out="$(python3 -c "$PY" "$P" 2>&1)"; rc=$?
check "pure helpers import + assertions pass" "$rc"
[[ "$out" == *PYOK* ]]; check "region priority + payload shape contract holds" $?
if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$out" | sed 's/^/    /'; fi

echo "  $_run run, $_fail failed"
[[ "$_fail" -eq 0 ]]
