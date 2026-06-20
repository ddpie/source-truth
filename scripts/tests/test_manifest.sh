#!/usr/bin/env bash
# test_manifest.sh — offline tests for the multi-repo manifest parser
# (scripts/lib/render_manifest.py). No AWS, no network. Pure validation + emit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="$ROOT/scripts/lib/render_manifest.py"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_manifest:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk() { printf '%s' "$1" > "$TMP/m.json"; }

# --- valid: single repo (the current single-repo deploy expressed as a 1-element manifest) ---
mk '{"repos":[{"subdir":"code-5x","source":"s3://b/code-5x.tar.gz","sig":"etag-1|etag-2"}]}'
out="$(python3 "$R" "$TMP/m.json" 2>"$TMP/err")"; rc=$?
check "single-repo manifest parses (rc 0)" "$rc"
n="$(printf '%s\n' "$out" | grep -c . || true)"; [[ "$n" -eq 1 ]]; check "emits one record" $?
# sig with a pipe survives intact (the whole reason for JSON, not shell vars)
printf '%s' "$out" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["sig"]=="etag-1|etag-2", r["sig"]'; check "ETag with | preserved verbatim" $?

# --- valid: multi-repo + --field subdir (the bootstrap for-loop driver) ---
mk '{"repos":[{"subdir":"client","source":"git@h:client.git"},{"subdir":"backend-svc","source":"s3://b/backend.tgz","sig":"e3"}]}'
subs="$(python3 "$R" --field subdir "$TMP/m.json")"; rc=$?
check "--field subdir lists names (rc 0)" "$rc"
[[ "$subs" == $'client\nbackend-svc' ]]; check "subdir column is exactly the two names" $?
# a missing sig defaults to empty string (bootstrap = always re-extract)
python3 "$R" "$TMP/m.json" | head -1 | python3 -c 'import json,sys; assert json.loads(sys.stdin.readline())["sig"]==""'; check "missing sig → empty string" $?

# --- CONTRACT: subdir name whitelist (injection guard — name → useradd/path/unit/pgrep) ---
for bad in '../etc' 'Code5x' 'a b' 'repo;rm' 'a_b' 'a/b' 'a.bak'; do
  mk "{\"repos\":[{\"subdir\":\"$bad\",\"source\":\"s3://b/x\"}]}"
  python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; rc=$?
  [[ "$rc" -ne 0 ]] || { echo "  FAIL bad subdir '$bad' was ACCEPTED"; _fail=$((_fail+1)); }
done
_run=$((_run+1)); printf '  ok   illegal subdir names rejected (../etc, Code5x, a b, repo;rm, a_b, a/b, a.bak)\n'

# --- CONTRACT: empty subdir / empty source (rm -rf root-wipe guard) ---
mk '{"repos":[{"subdir":"","source":"s3://b/x"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "empty subdir rejected" $?
mk '{"repos":[{"subdir":"ok","source":""}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "empty source rejected" $?
grep -q -i "rm -rf\|non-empty" "$TMP/err"; check "empty-source error explains the rm -rf risk" $?

# --- CONTRACT: duplicate subdir (shared graph.db/HOME → corruption) ---
mk '{"repos":[{"subdir":"dup","source":"s3://b/a"},{"subdir":"dup","source":"s3://b/b"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "duplicate subdir rejected" $?
grep -q -i "duplicate\|corruption" "$TMP/err"; check "duplicate error mentions corruption" $?

# --- CONTRACT: structural junk ---
mk 'not json'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "non-JSON rejected" $?
mk '{"repos":[]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "empty repos array rejected" $?
mk '{"foo":1}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "missing repos rejected" $?

# --- stdin path works too (bootstrap may pipe the env var) ---
echo '{"repos":[{"subdir":"x","source":"s3://b/x"}]}' | python3 "$R" --field subdir | grep -qx 'x'; check "reads manifest from stdin" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
