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

[[ "$_fail" -eq 0 ]]; exit $?
