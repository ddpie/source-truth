#!/usr/bin/env bash
# test_deploy_all_local.sh — OFFLINE static checks for deploy-all.sh --local. We do NOT execute
# deploy-all (even --dry-run calls aws sts).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$ROOT/scripts/deploy-all.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_deploy_all_local:"

bash -n "$D"; check "deploy-all.sh parses" $?
"$D" --help 2>&1 | grep -q -- '--local'; check "--help documents --local" $?
grep -q -- '--local) LOCAL_MODE=true' "$D"; check "--local sets LOCAL_MODE" $?
grep -q 'uname -m' "$D"; check "has an arch guard" $?
grep -q 'ST_LOCAL_MODE=' "$D"; check "Phase 3 passes ST_LOCAL_MODE to provisioner" $?
grep -qi 'local mode' "$D"; check "Phase 2 has a local-mode network branch" $?
grep -q 'sudo grep .*BOOTSTRAP_DONE\|sudo tail' "$D"; check "local-mode confirms BOOTSTRAP_DONE with sudo" $?
[[ "$_fail" -eq 0 ]]; exit $?
