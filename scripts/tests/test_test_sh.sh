#!/usr/bin/env bash
# test_test_sh.sh — scripts/test.sh 自身行为的单元测试。
# 只调 test.sh 的轻量子命令（--help / --list / --lint），不触发完整 unit 层。
# _TEST_SH_SELF=1 让 test.sh 的发现逻辑排除本文件，防递归。
set -uo pipefail
export _TEST_SH_SELF=1

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

# --lint 聚合：check-invariants 失败时必须非零（守卫失败曾被后一步的退出码掩盖）。
# 用最小假仓复现：真 test.sh + 真 common.sh + 一失败一成功的守卫桩。
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/lib" "$TMP/scripts/tests"
cp "$TEST_SH" "$TMP/scripts/test.sh"
cp "$ROOT/scripts/lib/common.sh" "$TMP/scripts/lib/common.sh"
# 第三个 lint 守卫（IAM 策略校验器）也必须存在，否则 python3 会因文件缺失非零退出，
# 使 --lint 在假仓里恒为非零 —— 两条「聚合」断言就变成永真：把 run_lint 整体改成
# `return 0` 它们照样通过，而这正是它们要守的性质。
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$TMP/scripts/tests/validate_iam_policies.py"
# 同理：run_lint 现在还调许可清单漂移校验。少了它，假仓的 --lint 又会恒为非零，
# 下面那条「全部守卫通过时退出零」的正向断言就会失败 —— 它正是为了发现这种情况才加的。
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$TMP/scripts/tests/validate_license_manifest.py"
# 以及可观测接线校验。这条桩是被上面那条注释预言到的情况抓出来的：给 run_lint 加了新一步却
# 没在假仓里造桩，正向断言立刻挂 —— 正是它存在的意义。以后每加一个 lint 校验器都要在这里加一行。
printf '#!/usr/bin/env python3\\nimport sys\\nsys.exit(0)\\n' > "$TMP/scripts/tests/validate_observability_wiring.py"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/scripts/check-invariants.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/check-versions.sh"
bash "$TMP/scripts/test.sh" --lint >/dev/null 2>&1; lintfail_rc=$?
[[ "$lintfail_rc" -ne 0 ]]; check "--lint 在 check-invariants 失败时退出非零" $?
# 对称：后一步守卫失败同样必须非零。
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/check-invariants.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/scripts/check-versions.sh"
bash "$TMP/scripts/test.sh" --lint >/dev/null 2>&1; lintfail2_rc=$?
[[ "$lintfail2_rc" -ne 0 ]]; check "--lint 在 check-versions 失败时退出非零" $?
# 缺了这条正向用例，上面两条都可能是永真断言：只有「全通过时为 0」才真正钉住聚合语义。
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/check-versions.sh"
bash "$TMP/scripts/test.sh" --lint >/dev/null 2>&1; lintpass_rc=$?
[[ "$lintpass_rc" -eq 0 ]]; check "--lint 在全部守卫通过时退出零" $?
# 第三个守卫失败也必须被聚合（它是最近加入的，此前无任何断言覆盖）。
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$TMP/scripts/tests/validate_iam_policies.py"
bash "$TMP/scripts/test.sh" --lint >/dev/null 2>&1; lintfail3_rc=$?
[[ "$lintfail3_rc" -ne 0 ]]; check "--lint 在 IAM 策略校验失败时退出非零" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
