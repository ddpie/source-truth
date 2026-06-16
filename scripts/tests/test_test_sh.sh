#!/usr/bin/env bash
# test_test_sh.sh — scripts/test.sh 自身行为的单元测试。
# 只调 test.sh 的轻量子命令（--help / --list / --lint），不触发完整 unit 层（避免自递归）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_SH="$ROOT/scripts/test.sh"

_run=0
_fail=0

check() {
  local name="$1" cond="$2"
  _run=$((_run + 1))
  if [[ "$cond" -eq 0 ]]; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s\n' "$name"; _fail=$((_fail + 1)); fi
}

echo "test_test_sh:"

# 可执行存在
[[ -x "$TEST_SH" ]]; check "test.sh 存在且可执行" $?

# --help 退出 0 且打印用法关键字
help_out="$("$TEST_SH" --help 2>&1)"; help_rc=$?
check "--help 退出码 0" "$help_rc"
[[ "$help_out" == *"Usage"* || "$help_out" == *"用法"* ]]; check "--help 含用法说明" $?
[[ "$help_out" == *"--full"* ]]; check "--help 列出 --full" $?

# --list 列出已发现的 unit 测试文件，且至少含本测试约定文件名 test_common.sh
list_out="$("$TEST_SH" --list 2>&1)"; list_rc=$?
check "--list 退出码 0" "$list_rc"
[[ "$list_out" == *"test_common.sh"* ]]; check "--list 发现 test_common.sh" $?

# --lint 跑结构自检（等价 check-invariants），全绿应退出 0 且输出含 OK 标记
lint_out="$("$TEST_SH" --lint 2>&1)"; lint_rc=$?
check "--lint 退出码 0" "$lint_rc"
[[ "$lint_out" == *"check-invariants: OK"* ]]; check "--lint 跑了结构自检" $?

# --list-py 列出发现的 Python 测试目录，应含 agent-container
listpy_out="$("$TEST_SH" --list-py 2>&1)"; listpy_rc=$?
check "--list-py 退出码 0" "$listpy_rc"
[[ "$listpy_out" == *"agent-container"* ]]; check "--list-py 发现 agent-container/tests" $?

# 未知参数应报错退出非零
"$TEST_SH" --bogus-flag >/dev/null 2>&1; bogus_rc=$?
[[ "$bogus_rc" -ne 0 ]]; check "未知参数退出非零" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
