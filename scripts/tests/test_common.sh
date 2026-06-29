#!/usr/bin/env bash
# test_common.sh — scripts/lib/common.sh 的单元测试（纯 bash，无外部依赖）。
# 约定：scripts/tests/test_*.sh 可独立 `bash` 运行；退出码 0 = 全绿。
# 由 scripts/test.sh 的 unit 层自动发现并运行。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

_run=0
_fail=0

# assert_rc <expected_rc> <cmd...> — 断言命令退出码
assert_rc() {
  local want="$1" name="$2"; shift 2
  _run=$((_run + 1))
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (want rc=%s, got rc=%s)\n' "$name" "$want" "$got"
    _fail=$((_fail + 1))
  fi
}

# assert_contains <substr> <name> <text> — 断言文本含子串
assert_contains() {
  local needle="$1" name="$2" hay="$3"
  _run=$((_run + 1))
  if [[ "$hay" == *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (missing %q in %q)\n' "$name" "$needle" "$hay"
    _fail=$((_fail + 1))
  fi
}

# assert_not_contains <substr> <name> <text>
assert_not_contains() {
  local needle="$1" name="$2" hay="$3"
  _run=$((_run + 1))
  if [[ "$hay" != *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (unexpected %q in %q)\n' "$name" "$needle" "$hay"
    _fail=$((_fail + 1))
  fi
}

echo "test_common:"

# have_cmd: 真命令返回 0，假命令返回 1
assert_rc 0 "have_cmd 识别存在的命令" have_cmd bash
assert_rc 1 "have_cmd 拒绝不存在的命令" have_cmd __no_such_cmd_xyz__

# require_cmd: 缺失命令返回 1 且报错文本含命令名
assert_rc 1 "require_cmd 缺失命令返回非零" require_cmd __no_such_cmd_xyz__
require_out="$(require_cmd __no_such_cmd_xyz__ 2>&1 || true)"
assert_contains "__no_such_cmd_xyz__" "require_cmd 报错含命令名" "$require_out"
assert_rc 0 "require_cmd 存在命令返回 0" require_cmd bash

# say: 输出含消息体；NO_COLOR 下无 ANSI 转义
say_out="$(NO_COLOR=1 say ok "hello-world" 2>&1)"
assert_contains "hello-world" "say 输出含消息体" "$say_out"
assert_not_contains $'\e[' "say 在 NO_COLOR 下无 ANSI 转义" "$say_out"

# run_timeout: 命令照常跑、退出码透传；无 timeout/gtimeout 时直接执行（mac 无 coreutils）
rt_out="$(run_timeout 5 echo "rt-ok" 2>&1)"
assert_contains "rt-ok" "run_timeout 正常透传输出" "$rt_out"
assert_rc 3 "run_timeout 透传命令退出码" run_timeout 5 bash -c 'exit 3'
# 模拟 mac（无 timeout/gtimeout）：仍应直接跑命令、成功
assert_rc 0 "run_timeout 缺 timeout 时回退直跑" bash -c \
  'source "'"$ROOT"'/scripts/lib/common.sh"; have_cmd() { [[ "$1" != timeout && "$1" != gtimeout ]]; }; run_timeout 5 true'

# assert_eq <expected> <name> <actual>
assert_eq() {
  local want="$1" name="$2" got="$3"
  _run=$((_run + 1))
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s (want %q, got %q)\n' "$name" "$want" "$got"
    _fail=$((_fail + 1))
  fi
}

# term_bg_class: 末段背景色号 7/9-15 = light，其余（含 0-6/8/空/非数字）= dark
assert_eq dark  "term_bg_class 空回退 dark"        "$(term_bg_class "")"
assert_eq dark  "term_bg_class 默认黑底 (15;0)"     "$(term_bg_class "15;0")"
assert_eq light "term_bg_class 白底 (0;15)"         "$(term_bg_class "0;15")"
assert_eq light "term_bg_class 浅灰底 (0;7)"        "$(term_bg_class "0;7")"
assert_eq dark  "term_bg_class 深色 6"              "$(term_bg_class "7;6")"
assert_eq dark  "term_bg_class 亮黑 8"              "$(term_bg_class "7;8")"
assert_eq light "term_bg_class 三段式取末段 (1;default;15)" "$(term_bg_class "1;default;15")"
assert_eq dark  "term_bg_class 非数字回退 dark"     "$(term_bg_class "fg;bg")"

# is_https_git_url: 仅 https:// 返回 0；ssh/git@/其他返回 1
assert_rc 0 "is_https_git_url 认 https"        is_https_git_url "https://github.com/o/r.git"
assert_rc 1 "is_https_git_url 拒 git@ ssh"      is_https_git_url "git@github.com:o/r.git"
assert_rc 1 "is_https_git_url 拒 ssh://"        is_https_git_url "ssh://git@host/o/r.git"
assert_rc 1 "is_https_git_url 拒 http (非 s)"   is_https_git_url "http://github.com/o/r.git"
assert_rc 1 "is_https_git_url 拒空"             is_https_git_url ""

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
