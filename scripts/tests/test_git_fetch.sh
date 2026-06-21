#!/usr/bin/env bash
# test_git_fetch.sh — offline tests for index-service/git_fetch.sh using a LOCAL bare repo
# as the "upstream" (no network, no credentials). Covers clone, fast-forward pull, ref reset,
# delete-then-pull, and the fail-loud GIT_FETCH_FAILED marker on a bad URL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FETCH="$ROOT/index-service/git_fetch.sh"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_git_fetch:"
command -v git >/dev/null 2>&1 || { echo "  skip (no git)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"   # isolate from the dev machine's git config
export GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" user.name t

# --- build a local bare "upstream" with one commit on main ---
ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$WORK"
( cd "$WORK" && echo "def one(): pass" > a.py && git add a.py && git commit -qm init && git push -q origin main )

DEST="$TMP/repo/myrepo"

# --- clone (dest absent) ---
bash "$FETCH" myrepo "$ORIGIN" main "$DEST" >/dev/null 2>"$TMP/err"; rc=$?
check "clone succeeds (rc 0)" "$rc"
[[ -f "$DEST/a.py" ]]; check "clone landed a.py" $?

# --- pull (upstream advances) fast-forwards ---
( cd "$WORK" && echo "def two(): pass" > b.py && git add b.py && git commit -qm two && git push -q origin main )
bash "$FETCH" myrepo "$ORIGIN" main "$DEST" >/dev/null 2>"$TMP/err"; rc=$?
check "pull succeeds (rc 0)" "$rc"
[[ -f "$DEST/b.py" ]]; check "pull brought b.py" $?

# --- pull resets a locally-diverged working tree to upstream (in-place, force) ---
( cd "$DEST" && echo "garbage" > a.py )   # simulate a dirty/divergent tree
bash "$FETCH" myrepo "$ORIGIN" main "$DEST" >/dev/null 2>"$TMP/err"; rc=$?
check "pull over a dirty tree succeeds (rc 0)" "$rc"
grep -q "def one" "$DEST/a.py"; check "pull hard-reset restored a.py" $?

# --- empty ref → default branch HEAD ---
DEST2="$TMP/repo/defref"
bash "$FETCH" defref "$ORIGIN" "" "$DEST2" >/dev/null 2>"$TMP/err"; rc=$?
check "clone with empty ref uses default branch (rc 0)" "$rc"
[[ -f "$DEST2/a.py" && -f "$DEST2/b.py" ]]; check "default-ref clone has both files" $?

# --- failure path: bogus url → non-zero + GIT_FETCH_FAILED marker ---
bash "$FETCH" bad "file://$TMP/nonexistent.git" main "$TMP/repo/bad" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "bad url returns non-zero" $?
grep -q "GIT_FETCH_FAILED: bad" "$TMP/err"; check "bad url prints GIT_FETCH_FAILED marker" $?

# --- usage guard: missing args fail loud ---
bash "$FETCH" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "no args → non-zero" $?

# --- graph-dir guard: the live .codegraph/.home survive a hard-reset (untracked, info/exclude) ---
mkdir -p "$DEST/.codegraph" "$DEST/.home/.codegraph"; echo "GRAPHDATA" > "$DEST/.codegraph/graph.db"
( cd "$WORK" && echo "def three(): pass" > c.py && git add c.py && git commit -qm three && git push -q origin main )
bash "$FETCH" myrepo "$ORIGIN" main "$DEST" >/dev/null 2>"$TMP/err"; rc=$?
check "pull with graph dirs present succeeds (rc 0)" "$rc"
[[ -f "$DEST/c.py" ]]; check "pull brought new c.py" $?
[[ -f "$DEST/.codegraph/graph.db" ]] && grep -q GRAPHDATA "$DEST/.codegraph/graph.db"; check "live graph.db SURVIVED reset --hard" $?
grep -qxF "/.codegraph/" "$DEST/.git/info/exclude"; check ".codegraph added to .git/info/exclude" $?

# --- graph-dir guard: a repo that TRACKS .codegraph fails loud (unsupported, would clobber) ---
BAD_ORIGIN="$TMP/badorigin.git"; BAD_WORK="$TMP/badwork"
git init -q --bare -b main "$BAD_ORIGIN"; git clone -q "$BAD_ORIGIN" "$BAD_WORK"
( cd "$BAD_WORK" && mkdir -p .codegraph && echo x > .codegraph/tracked && echo y > a.py \
  && git add -A && git commit -qm init && git push -q origin main )
bash "$FETCH" badrepo "$BAD_ORIGIN" main "$TMP/repo/badrepo" >/dev/null 2>"$TMP/err"; rc=$?
[[ "$rc" -ne 0 ]]; check "repo tracking .codegraph → non-zero (unsupported)" $?
grep -q "GIT_FETCH_FAILED: badrepo" "$TMP/err"; check "tracked-.codegraph prints GIT_FETCH_FAILED" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
