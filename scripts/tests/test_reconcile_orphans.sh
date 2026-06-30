#!/usr/bin/env bash
# test_reconcile_orphans.sh — reconcile must be driven by the OLD manifest's subdirs (orphans =
# old − new), NOT by refresh timers (local repos have none) or glossary slices (may be absent on a
# no-engine host). Static assertions on the source.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
A="$ROOT/index-service/activate_project.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_reconcile_orphans:"

# OLD_SUBDIRS captured BEFORE the manifest is overwritten
grep -q 'OLD_SUBDIRS=' "$A"; check "captures old subdirs" $?
ovl=$(grep -n 'OLD_SUBDIRS="\$(python3' "$A" | head -1 | cut -d: -f1)
wrl=$(grep -n "printf '%s' \"\$REPO_MANIFEST_JSON\" > \"\$MANIFEST\"" "$A" | head -1 | cut -d: -f1)
[[ -n "$ovl" && -n "$wrl" && "$ovl" -lt "$wrl" ]]; check "old subdirs captured before manifest overwrite" $?
# reconcile iterates OLD_SUBDIRS, NOT refresh timers
grep -q 'for sub in \$OLD_SUBDIRS' "$A"; check "reconcile iterates old manifest subdirs" $?
! grep -q "list-unit-files 'index-refresh-\*.timer'" "$A"; check "reconcile no longer driven by refresh timers" $?
# orphan cleanup removes the repo copy + .incoming, not just the slice
grep -q 'rm -rf "$LOCAL_REPO_ROOT/${sub}" "$LOCAL_REPO_ROOT/${sub}.incoming"' "$A"; check "orphan repo copy + .incoming removed" $?
bash -n "$A"; check "activate_project.sh parses" $?
[[ "$_fail" -eq 0 ]]; exit $?
