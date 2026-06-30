#!/usr/bin/env bash
# test_reindex_local_repo.sh — static checks: arg validation + orchestration order + rollback arm
# + prepare mode. No systemd, no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/index-service/reindex_local_repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_reindex_local_repo:"

[[ -f "$S" ]]; check "script exists" $?
bash -n "$S"; check "parses" $?
bash "$S" "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?
bash "$S" --prepare "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "prepare rejects invalid subdir" $?
# orchestration: stop bridge BEFORE build, build BEFORE final bridge start
stop_ln=$(grep -nF 'systemctl stop "$BRIDGE"' "$S" | head -1 | cut -d: -f1)
build_ln=$(grep -nF 'systemctl start "index-build@' "$S" | head -1 | cut -d: -f1)
start_ln=$(grep -nF 'systemctl start "$BRIDGE"' "$S" | tail -1 | cut -d: -f1)
[[ -n "$stop_ln" && -n "$build_ln" && -n "$start_ln" && "$stop_ln" -lt "$build_ln" && "$build_ln" -lt "$start_ln" ]]
check "stop bridge < build < start bridge" $?
grep -q 'trap rollback EXIT' "$S"; check "arms rollback on failure" $?
grep -q 'REINDEX_PREPARED' "$S"; check "has --prepare mode" $?
# MVP: reindex builds ONLY the graph — it must NOT run the glossary engine (deferred; see plan).
! grep -q 'glossary_gen' "$S"; check "reindex does NOT rebuild glossary (deferred to redeploy)" $?
[[ "$_fail" -eq 0 ]]; exit $?
