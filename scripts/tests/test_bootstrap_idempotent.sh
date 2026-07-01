#!/usr/bin/env bash
# test_bootstrap_idempotent.sh — static guards that bootstrap.sh is safe to re-run on a live host.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$ROOT/index-service/bootstrap.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_bootstrap_idempotent:"

bash -n "$B"; check "bootstrap.sh parses" $?
grep -q 'ln -sf .* /usr/local/bin/codegraph-server' "$B"; check "codegraph symlink uses ln -sf" $?
grep -q 'command -v node >/dev/null 2>&1 && return 0' "$B"; check "ensure_node guards re-install" $?
# bootstrap must NOT stop/restart the resident project bridge (it doesn't own it)
! grep -qE 'systemctl (stop|restart) .*index-bridge-' "$B"; check "bootstrap never touches a project bridge" $?
[[ "$_fail" -eq 0 ]]; exit $?
