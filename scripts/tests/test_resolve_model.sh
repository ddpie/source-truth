#!/usr/bin/env bash
# test_resolve_model.sh — scripts/lib/resolve_model.sh 单元测试（纯 bash）。
# 约定：scripts/tests/test_*.sh 可独立 `bash` 运行；退出码 0 = 全绿。
# 由 scripts/test.sh 的 unit 层自动发现并运行。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resolve_model.sh
source "$ROOT/scripts/lib/resolve_model.sh"

_run=0
_fail=0

assert_eq() { # <name> <expected> <actual>
  _run=$((_run + 1))
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s (want [%s], got [%s])\n' "$1" "$2" "$3"
    _fail=$((_fail + 1))
  fi
}

assert_rc() { # <name> <expected_rc> <cmd...>
  _run=$((_run + 1))
  local want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s (want rc=%s, got rc=%s)\n' "$1" "$want" "$got"
    _fail=$((_fail + 1))
  fi
}

echo "test_resolve_model:"

# region_geo_prefix
assert_eq "us-east-1 → us"        "us"   "$(region_geo_prefix us-east-1)"
assert_eq "us-west-2 → us"        "us"   "$(region_geo_prefix us-west-2)"
assert_eq "eu-west-1 → eu"        "eu"   "$(region_geo_prefix eu-west-1)"
assert_eq "ap-southeast-1 → apac" "apac" "$(region_geo_prefix ap-southeast-1)"
assert_eq "ap-northeast-1 → apac" "apac" "$(region_geo_prefix ap-northeast-1)"

# resolve_model_profile — the core bug: a global. id deployed to Singapore must
# either be rewritten or (since the operator chose global.) left for a warning.
# Here we test the geo-scoped rewrite path that the resolver applies to non-global ids.
assert_eq "global stays global (operator opt-in)" \
  "global.anthropic.claude-opus-4-8" \
  "$(resolve_model_profile global.anthropic.claude-opus-4-8 ap-southeast-1)"

# A us. id deployed to Singapore is rewritten to apac.
assert_eq "us.→apac. in Singapore" \
  "apac.anthropic.claude-opus-4-8" \
  "$(resolve_model_profile us.anthropic.claude-opus-4-8 ap-southeast-1)"

# A bare anthropic. id gets the geo prefix prepended.
assert_eq "bare anthropic. → apac. in Singapore" \
  "apac.anthropic.claude-opus-4-8" \
  "$(resolve_model_profile anthropic.claude-opus-4-8 ap-southeast-1)"

# Same bare id in a US region → us.
assert_eq "bare anthropic. → us. in us-east-1" \
  "us.anthropic.claude-opus-4-8" \
  "$(resolve_model_profile anthropic.claude-opus-4-8 us-east-1)"

# apac. id in Tokyo stays apac.
assert_eq "apac. unchanged in Tokyo" \
  "apac.anthropic.claude-opus-4-8" \
  "$(resolve_model_profile apac.anthropic.claude-opus-4-8 ap-northeast-1)"

# eu. region path
assert_eq "us.→eu. in eu-west-1" \
  "eu.anthropic.claude-sonnet-4-6" \
  "$(resolve_model_profile us.anthropic.claude-sonnet-4-6 eu-west-1)"

# Unrecognized id is left untouched (don't corrupt non-Bedrock / custom ids).
assert_eq "custom id untouched" \
  "my-custom-model" \
  "$(resolve_model_profile my-custom-model ap-southeast-1)"

# region_carries_global — Tokyo yes, Singapore no (drives the global.* warning).
assert_rc "Tokyo carries global"       0 region_carries_global ap-northeast-1
assert_rc "Singapore does NOT"         1 region_carries_global ap-southeast-1
assert_rc "us-east-1 carries global"   0 region_carries_global us-east-1
assert_rc "eu-west-1 carries global"   0 region_carries_global eu-west-1
assert_rc "us-west-2 carries global"   0 region_carries_global us-west-2

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
