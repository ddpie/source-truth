#!/usr/bin/env bash
# test_push_local_repo.sh — arg validation + dry-run command assembly + injection guards. No network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/scripts/push-local-repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_push_local_repo:"

[[ -f "$S" ]]; check "script exists" $?
bash -n "$S"; check "parses" $?
bash "$S" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "no args exits non-zero" $?
bash "$S" --host h "Bad/Sub" /tmp 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?
# refuse a / local path (would mirror the whole disk)
bash "$S" --host h sub / 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "root local path rejected" $?
# NO --ssh-opts knob (injection vector) — unknown flag must error
bash "$S" --ssh-opts "-oProxyCommand=evil" --host h sub /tmp 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "--ssh-opts not accepted (no ProxyCommand injection)" $?

SRC="$(mktemp -d)"; echo hi > "$SRC/f.txt"
out="$(bash "$S" --host ec2host --dry-run localsub "$SRC" 2>&1)"; rc=$?
[[ $rc -eq 0 ]]; check "dry-run rc 0" $?
grep -q 'rsync' <<<"$out"; check "dry-run shows rsync" $?
grep -q 'safe-links' <<<"$out" && grep -q 'no-links' <<<"$out"; check "dry-run rsync refuses symlink escape" $?
grep -q '/data/repo/localsub.incoming' <<<"$out"; check "dry-run stages to .incoming (not live dir)" $?
grep -q 'reindex_local_repo.sh --prepare localsub' <<<"$out"; check "dry-run prepares stage via host script (no raw sudo mkdir)" $?
grep -q 'reindex_local_repo.sh localsub' <<<"$out"; check "dry-run triggers host reindex" $?
! grep -qE 'sudo (mkdir|chown)' <<<"$out"; check "no raw sudo mkdir/chown in remote commands" $?
rm -rf "$SRC"
[[ "$_fail" -eq 0 ]]; exit $?
