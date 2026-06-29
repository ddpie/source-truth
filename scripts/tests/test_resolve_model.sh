#!/usr/bin/env bash
# test_resolve_model.sh — scripts/lib/resolve_model.sh 单元测试（纯 bash，无网络）。
# 只测纯函数 model_basename / rank_profiles；list_region_profiles /
# resolve_model_for_region 走 AWS,由 e2e 覆盖,这里不联网。
# 约定：scripts/tests/test_*.sh 可独立 `bash` 运行；退出码 0 = 全绿。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resolve_model.sh
source "$ROOT/scripts/lib/resolve_model.sh"

_run=0
_fail=0
assert_eq() { # <name> <expected> <actual>
  _run=$((_run + 1))
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s (want [%s], got [%s])\n' "$1" "$2" "$3"; _fail=$((_fail + 1)); fi
}

echo "test_resolve_model:"

# model_basename — strip whatever prefix the operator typed (even a bogus one).
assert_eq "global. stripped"     "claude-opus-4-8" "$(model_basename global.anthropic.claude-opus-4-8)"
assert_eq "us. stripped"         "claude-opus-4-8" "$(model_basename us.anthropic.claude-opus-4-8)"
assert_eq "jp. stripped"         "claude-opus-4-8" "$(model_basename jp.anthropic.claude-opus-4-8)"
assert_eq "bogus apac. stripped" "claude-opus-4-8" "$(model_basename apac.anthropic.claude-opus-4-8)"
assert_eq "bare anthropic."      "claude-opus-4-8" "$(model_basename anthropic.claude-opus-4-8)"
assert_eq "no prefix"            "claude-opus-4-8" "$(model_basename claude-opus-4-8)"
assert_eq "sonnet basename"      "claude-sonnet-4-6" "$(model_basename eu.anthropic.claude-sonnet-4-6)"

# rank_profiles — geo beats global; only same-model candidates count.
# Tokyo offers jp. + global. → prefer jp.
assert_eq "Tokyo: prefer jp over global" \
  "jp.anthropic.claude-opus-4-8" \
  "$(rank_profiles claude-opus-4-8 jp.anthropic.claude-opus-4-8 global.anthropic.claude-opus-4-8)"

# Singapore offers ONLY global. (no geo) → use global.
assert_eq "Singapore: only global available" \
  "global.anthropic.claude-opus-4-8" \
  "$(rank_profiles claude-opus-4-8 global.anthropic.claude-opus-4-8)"

# US offers us. + global. → prefer us.
assert_eq "US: prefer us over global" \
  "us.anthropic.claude-opus-4-8" \
  "$(rank_profiles claude-opus-4-8 us.anthropic.claude-opus-4-8 global.anthropic.claude-opus-4-8)"

# Candidate list contains OTHER models — must not cross-match.
assert_eq "ignores other models" \
  "us.anthropic.claude-opus-4-8" \
  "$(rank_profiles claude-opus-4-8 us.anthropic.claude-sonnet-4-6 global.anthropic.claude-haiku-4-5 us.anthropic.claude-opus-4-8)"

# No candidate matches the model → empty (caller keeps original id).
assert_eq "no match → empty" \
  "" \
  "$(rank_profiles claude-opus-4-8 us.anthropic.claude-sonnet-4-6 eu.anthropic.claude-haiku-4-5)"

# Substring-safety: a basename must match at the END, not mid-string. A profile for a
# DIFFERENT, longer model name must not be picked for the shorter basename.
assert_eq "suffix match, not substring" \
  "" \
  "$(rank_profiles claude-opus-4 us.anthropic.claude-opus-4-8)"

# au. geo (Sydney/Melbourne)
assert_eq "AU geo preferred" \
  "au.anthropic.claude-opus-4-8" \
  "$(rank_profiles claude-opus-4-8 au.anthropic.claude-opus-4-8 global.anthropic.claude-opus-4-8)"

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
