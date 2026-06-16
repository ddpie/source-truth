#!/usr/bin/env bash
# test_deploy.sh — scripts/deploy.sh offline behavior tests.
# Only tests --help and flag parsing (no AWS calls).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_deploy:"

# exists and executable
[[ -x "$DEPLOY" ]]; check "deploy.sh exists and executable" $?

# --help exits 0 and prints usage
help_out="$("$DEPLOY" --help 2>&1)"; help_rc=$?
check "--help exits 0" "$help_rc"
[[ "$help_out" == *"--dry-run"* ]]; check "--help mentions --dry-run" $?
[[ "$help_out" == *"--region"* ]]; check "--help mentions --region" $?
[[ "$help_out" == *"idempotent"* || "$help_out" == *"幂等"* ]]; check "--help mentions idempotent" $?

# unknown flag exits non-zero
"$DEPLOY" --bogus 2>/dev/null; bogus_rc=$?
[[ "$bogus_rc" -ne 0 ]]; check "unknown flag exits non-zero" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
