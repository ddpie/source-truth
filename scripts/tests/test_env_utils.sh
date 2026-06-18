#!/usr/bin/env bash
# test_env_utils.sh — scripts/lib/env-utils.sh 单元测试
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/env-utils.sh
source "$ROOT/scripts/lib/env-utils.sh"

_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

echo "test_env_utils:"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# update_env: new key appended
ENV1="$TMP/env1"
update_env "$ENV1" "FOO" "bar"
[[ "$(cat "$ENV1")" == "FOO=bar" ]]; check "update_env appends new key" $?

# update_env: existing key updated in-place
printf 'AAA=111\nFOO=old\nBBB=222\n' > "$ENV1"
update_env "$ENV1" "FOO" "new-val"
grep -q '^FOO=new-val$' "$ENV1"; check "update_env updates existing key" $?
grep -q '^AAA=111$' "$ENV1"; check "update_env preserves other keys" $?

# update_env: value with special chars (/, &, |)
update_env "$ENV1" "URL" "https://a.b/c?d=1&e=2|3"
grep -q '^URL=https://a.b/c?d=1&e=2|3$' "$ENV1"; check "update_env handles special chars" $?

# safe_source_env: loads keys as env, skips comments/blank
printf '# comment\n\nKEY1=val1\nKEY2=val 2\n' > "$TMP/env2"
(
  unset KEY1 KEY2 2>/dev/null || true
  safe_source_env "$TMP/env2"
  [[ "$KEY1" == "val1" && "$KEY2" == "val 2" ]]
); check "safe_source_env loads keys" $?

# safe_source_env: missing file is no-op
safe_source_env "$TMP/no-such-file"; check "safe_source_env missing file ok" $?

# safe_source_env: a whitespace-only / malformed LAST line must NOT abort the
# caller (the bug was: trailing bad line → failing export → rc 1 under set -e).
printf 'GOOD=1\nAFTER=3\n   \n' > "$TMP/env3"
(
  unset GOOD AFTER 2>/dev/null || true
  safe_source_env "$TMP/env3"; rc=$?
  [[ "$rc" -eq 0 && "$GOOD" == "1" && "$AFTER" == "3" ]]
); check "safe_source_env tolerates trailing whitespace line" $?

# safe_source_env: indented key + blank lines are skipped/trimmed, not garbage
printf 'A=1\n   \n  INDENTED=x\nB=2\n' > "$TMP/env4"
(
  unset A B INDENTED 2>/dev/null || true
  safe_source_env "$TMP/env4"
  [[ "$A" == "1" && "$B" == "2" && "$INDENTED" == "x" ]]
); check "safe_source_env trims indented keys, skips blanks" $?

# safe_source_env: CRLF-saved config must not inject a trailing \r into values
printf 'REGION=ap-northeast-1\r\nBUCKET=my-bucket\r\n' > "$TMP/env5"
(
  unset REGION BUCKET 2>/dev/null || true
  safe_source_env "$TMP/env5"
  [[ "$REGION" == "ap-northeast-1" && "$BUCKET" == "my-bucket" ]]
); check "safe_source_env strips trailing CR (CRLF files)" $?

# safe_source_env: a non-identifier key line is skipped, not fatal
printf 'X=1\n123BAD=nope\nY=2\n' > "$TMP/env6"
(
  unset X Y 2>/dev/null || true
  safe_source_env "$TMP/env6"; rc=$?
  [[ "$rc" -eq 0 && "$X" == "1" && "$Y" == "2" ]]
); check "safe_source_env skips non-identifier keys" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
