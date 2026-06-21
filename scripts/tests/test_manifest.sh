#!/usr/bin/env bash
# test_manifest.sh — offline tests for the multi-repo / multi-project manifest parser
# (scripts/lib/render_manifest.py). No AWS, no network. Pure validation + emit.
#
# Schema (single-host multi-project + git refresh, pre-launch — NO legacy `source`):
#   { "projectId": "<id>", "port": <int>,
#     "repos": [ { "subdir": "<name>", "git": "<git url>", "ref": "<branch?>",
#                  "refreshIntervalSec": <int?> }, ... ] }
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="$ROOT/scripts/lib/render_manifest.py"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_manifest:"
command -v python3 >/dev/null 2>&1 || { echo "  skip (no python3)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk() { printf '%s' "$1" > "$TMP/m.json"; }

# --- valid: single repo with git source ---
mk '{"projectId":"starfall","port":8080,"repos":[{"subdir":"sf-client","git":"git@github.com:org/sf.git","ref":"main"}]}'
out="$(python3 "$R" "$TMP/m.json" 2>"$TMP/err")"; rc=$?
check "single-repo manifest parses (rc 0)" "$rc"
n="$(printf '%s\n' "$out" | grep -c . || true)"; [[ "$n" -eq 1 ]]; check "emits one record" $?
printf '%s' "$out" | python3 -c 'import json,sys; r=json.loads(sys.stdin.readline()); assert r["git"]=="git@github.com:org/sf.git" and r["ref"]=="main", r'; check "git + ref preserved" $?

# --- valid: multi-repo + --field subdir (the bootstrap for-loop driver) ---
mk '{"projectId":"p","port":8081,"repos":[{"subdir":"client","git":"git@h:client.git"},{"subdir":"backend-svc","git":"https://x/b.git","refreshIntervalSec":600}]}'
subs="$(python3 "$R" --field subdir "$TMP/m.json")"; rc=$?
check "--field subdir lists names (rc 0)" "$rc"
[[ "$subs" == $'client\nbackend-svc' ]]; check "subdir column is exactly the two names" $?

# --- top-level scalar fields: projectId + port ---
[[ "$(python3 "$R" --field projectId "$TMP/m.json")" == "p" ]]; check "--field projectId prints top-level id" $?
[[ "$(python3 "$R" --field port "$TMP/m.json")" == "8081" ]]; check "--field port prints top-level port" $?

# --- --repo-field: per-subdir field lookup (bootstrap git clone driver) ---
[[ "$(python3 "$R" --repo-field git client "$TMP/m.json")" == "git@h:client.git" ]]; check "--repo-field git <subdir>" $?
[[ "$(python3 "$R" --repo-field refreshIntervalSec backend-svc "$TMP/m.json")" == "600" ]]; check "--repo-field refreshIntervalSec <subdir>" $?
# a repo without an explicit interval → empty (caller falls back to default)
[[ -z "$(python3 "$R" --repo-field refreshIntervalSec client "$TMP/m.json")" ]]; check "--repo-field interval empty when unset" $?

# --- CONTRACT: subdir name whitelist (injection guard — name → useradd/path/unit/pgrep) ---
for bad in '../etc' 'Code5x' 'a b' 'repo;rm' 'a_b' 'a/b' 'a.bak'; do
  mk "{\"projectId\":\"p\",\"port\":8080,\"repos\":[{\"subdir\":\"$bad\",\"git\":\"https://x/y.git\"}]}"
  python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; rc=$?
  [[ "$rc" -ne 0 ]] || { echo "  FAIL bad subdir '$bad' was ACCEPTED"; _fail=$((_fail+1)); }
done
_run=$((_run+1)); printf '  ok   illegal subdir names rejected (../etc, Code5x, a b, repo;rm, a_b, a/b, a.bak)\n'

# TRAILING-NEWLINE bypass (\A\Z anchor, not ^$): "sf\n" must be REJECTED.
printf '%s' '{"projectId":"p","port":8080,"repos":[{"subdir":"sf\n","git":"https://x/y.git"}]}' > "$TMP/m.json"
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "subdir with trailing newline rejected" $?
# LEADING-DASH option-injection
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"-rf","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "leading-dash subdir rejected (option injection)" $?
# interior dash still fine
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"backend-svc-2","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; check "interior-dash subdir still accepted" $?

# --- CONTRACT: git required (pre-launch — `source` is NOT honored) ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"r","source":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "legacy 'source' (no git) rejected" $?
grep -q -i "git" "$TMP/err"; check "missing-git error mentions git" $?
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"r","git":""}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "empty git rejected" $?

# --- CONTRACT: refreshIntervalSec must be int if present (per-repo and top-level) ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"r","git":"https://x/y.git","refreshIntervalSec":"soon"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "non-int per-repo interval rejected" $?
grep -q -i "refreshIntervalSec" "$TMP/err"; check "interval error names the field" $?
mk '{"projectId":"p","port":8080,"refreshIntervalSec":"soon","repos":[{"subdir":"r","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "non-int top-level interval rejected" $?

# --- CONTRACT: port required + integer ---
mk '{"projectId":"p","repos":[{"subdir":"r","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "missing port rejected" $?
grep -q -i "port" "$TMP/err"; check "missing-port error mentions port" $?
mk '{"projectId":"p","port":"8080","repos":[{"subdir":"r","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "non-int port rejected" $?

# --- CONTRACT: projectId required + charset ---
mk '{"port":8080,"repos":[{"subdir":"r","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "missing projectId rejected" $?
mk '{"projectId":"Bad_Id","port":8080,"repos":[{"subdir":"r","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "bad projectId charset rejected" $?

# --- CONTRACT: empty subdir / duplicate subdir ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"","git":"https://x/y.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "empty subdir rejected" $?
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"dup","git":"https://x/a.git"},{"subdir":"dup","git":"https://x/b.git"}]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>"$TMP/err"; [[ $? -ne 0 ]]; check "duplicate subdir rejected" $?
grep -q -i "duplicate\|corruption" "$TMP/err"; check "duplicate error mentions corruption" $?

# --- CONTRACT: structural junk ---
mk 'not json'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "non-JSON rejected" $?
mk '{"projectId":"p","port":8080,"repos":[]}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "empty repos array rejected" $?
mk '{"projectId":"p","port":8080}'
python3 "$R" "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]; check "missing repos rejected" $?

# --- stdin path works too ---
echo '{"projectId":"p","port":8080,"repos":[{"subdir":"x","git":"https://x/y.git"}]}' | python3 "$R" --field subdir | grep -qx 'x'; check "reads manifest from stdin" $?

# --- --serve-args: the bridge serve unit's --workspace/--local-workspace argv ---
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"client","git":"https://x/a.git"},{"subdir":"backend-svc","git":"https://x/b.git"}]}'
sa="$(python3 "$R" --serve-args /data/repo "$TMP/m.json")"; rc=$?
check "--serve-args emits (rc 0)" "$rc"
[[ "$sa" == "--workspace /data/repo/client --local-workspace /data/repo/client --workspace /data/repo/backend-svc --local-workspace /data/repo/backend-svc" ]]
check "serve args pair each repo by path, in manifest order" $?
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"sf-client","git":"https://x/a.git"}]}'
sa1="$(python3 "$R" --serve-args /data/repo/ "$TMP/m.json")"   # trailing slash normalized
[[ "$sa1" == "--workspace /data/repo/sf-client --local-workspace /data/repo/sf-client" ]]
check "single-repo serve args (root trailing slash normalized)" $?
mk '{"projectId":"p","port":8080,"repos":[{"subdir":"a b","git":"https://x/a.git"}]}'
python3 "$R" --serve-args /data/repo "$TMP/m.json" >/dev/null 2>/dev/null; [[ $? -ne 0 ]]
check "--serve-args rejects an invalid manifest (no partial argv)" $?

# --- build_multi_manifest: construct a per-project manifest (single build authority) ---
bm="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from render_manifest import build_multi_manifest
print(build_multi_manifest("harbor", 8082, [{"subdir":"harbor-app","git":"https://github.com/org/h.git","ref":""}], default_interval=300))
' "$ROOT/scripts/lib")"; rc=$?
check "build_multi_manifest (rc 0)" "$rc"
printf '%s' "$bm" | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); assert o["projectId"]=="harbor" and o["port"]==8082 and o["repos"][0]["git"]=="https://github.com/org/h.git" and o["repos"][0]["refreshIntervalSec"]==300, o'
check "build_multi_manifest fills projectId/port and default interval" $?
# the built JSON must re-parse cleanly through the same parser
printf '%s' "$bm" | python3 "$R" --field subdir | grep -qx 'harbor-app'; check "build_multi_manifest output re-parses" $?
# per-repo interval overrides the default
bm2="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from render_manifest import build_multi_manifest
print(build_multi_manifest("p", 8080, [{"subdir":"r","git":"https://x/y.git","refreshIntervalSec":900}], default_interval=300))
' "$ROOT/scripts/lib")"
printf '%s' "$bm2" | python3 -c 'import json,sys; assert json.loads(sys.stdin.read())["repos"][0]["refreshIntervalSec"]==900'
check "build_multi_manifest per-repo interval overrides default" $?
# fail-loud on a bad subdir at build time
python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from render_manifest import build_multi_manifest
try:
    build_multi_manifest("p", 8080, [{"subdir":"Bad Name","git":"https://x/y.git"}], default_interval=300)
    sys.exit(0)
except ValueError:
    sys.exit(7)
' "$ROOT/scripts/lib"; [[ $? -eq 7 ]]; check "build_multi_manifest rejects a bad subdir" $?
# fail-loud on a non-int port
python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
from render_manifest import build_multi_manifest
try:
    build_multi_manifest("p", "8080", [{"subdir":"r","git":"https://x/y.git"}], default_interval=300)
    sys.exit(0)
except ValueError:
    sys.exit(7)
' "$ROOT/scripts/lib"; [[ $? -eq 7 ]]; check "build_multi_manifest rejects a non-int port" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
