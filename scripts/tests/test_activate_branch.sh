#!/usr/bin/env bash
# test_activate_branch.sh — the source-aware branch helper in activate_project.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_activate_branch:"

# Extract the helper (multi-line def, closing brace on its OWN line at column 0).
HELPER="$(sed -n '/^repo_uses_git() {$/,/^}$/p' "$ROOT/index-service/activate_project.sh")"
[[ -n "$HELPER" ]]; check "repo_uses_git helper extractable" $?
eval "$HELPER"

repo_uses_git git;   rc=$?; [[ $rc -eq 0 ]]; check "git source uses git" $?
repo_uses_git "";    rc=$?; [[ $rc -eq 0 ]]; check "empty source defaults to git" $?
repo_uses_git local; rc=$?; [[ $rc -ne 0 ]]; check "local source does NOT use git" $?

# The initial glossary build MUST detach via systemd-run, not `nohup … &`. activate_project.sh runs
# over SSM RunCommand, which does not return until every process holding the command's stdout has
# exited; a nohup child inherits that pipe and blocks the whole deploy (the gateway never starts)
# on the multi-minute cc scan. Guard the regression: systemd-run present, no ACTUAL nohup command.
A="$ROOT/index-service/activate_project.sh"
grep -q 'systemd-run' "$A"; check "initial glossary build detaches via systemd-run" $?
! grep -vE '^\s*#' "$A" | grep -qE '\bnohup\b'; check "no nohup-backgrounded glossary build under SSM" $?

# DEFER, DON'T FAIL: a local repo with no code yet must NOT abort activation. "装服务" stands up the
# bridge/runtime/gateway now; the graph build waits for the first push-local-repo.sh. Guard that
# (a) the old hard-fail is gone, and (b) empty local repos are tracked as deferred and SKIPPED by
# both the graph-build loop and the initial-glossary loop (an empty dir would fail / waste a token).
! grep -q 'ACTIVATE_FAILED: local repo' "$A"; check "empty local repo no longer hard-fails activation" $?
grep -q 'DEFERRED_SUBDIRS' "$A"; check "tracks empty local repos as deferred" $?
grep -q 'deferring graph build to first push' "$A"; check "logs the deferral (build waits for push)" $?
# Both loops must skip a deferred subdir (membership test on the space-padded list).
[ "$(grep -c 'DEFERRED_MEMBER" in \*" \$SUBDIR "\*)' "$A")" -ge 2 ]; check "build + glossary loops both skip deferred repos" $?

[[ "$_fail" -eq 0 ]]; exit $?
