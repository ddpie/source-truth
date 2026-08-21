#!/usr/bin/env bash
# teardown 的失败计数与退出码。
#
# 为什么值得单独一个套件：teardown.sh 此前没有任何测试，而"计数"就是它的功能本身 ——
# 早先的版本在漏下一个还在计费的 VPC 时依然 exit 0，运维以为清干净了，下个月账单才知道。
# 另外 wait_gone 的 `return 0` 是承重的：它一度返回 1，而每个调用点都是 `set -euo pipefail`
# 下的裸命令，于是第一个慢 NAT 就把整个 teardown 中断 —— EIP 没释放、VPC/子网/安全组没动、
# 监控没清，而屏幕上那句警告写着"continuing"。这两条性质都只差一次随手修改就会静默回退，
# 而症状是客户的账单，所以用最便宜的方式（纯 bash，不需要 aws 桩）把它们钉住。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

# 只抽出被测函数（两者都是列首左花括号），连同 say 的桩一起在子 shell 里驱动。
harness() {
  cat <<'STUB'
say() { printf '%s %s\n' "$1" "${*:2}"; }
TEARDOWN_INCOMPLETE=0
LEFT_BEHIND=""
STUB
  sed -n '/^del()/,/^}/p;/^wait_gone()/,/^}/p' "$ROOT/scripts/teardown.sh"
}

drive() { # drive <body>  -> 打印 "rc|counter|left_behind"
  { harness; printf '%s\n' "$1"; printf 'printf "COUNTER=%%s\\n" "$TEARDOWN_INCOMPLETE"\nprintf "LEFT=%%s\\n" "$(printf "%%s" "$LEFT_BEHIND" | tr -d "\\n")"\n'; } | bash 2>&1
}

# ---- del(): 真删成功 --------------------------------------------------------
out="$(drive 'del "thing" true; printf "RC=%s\n" "$?"')"
[[ "$out" == *"RC=0"* && "$out" == *"COUNTER=0"* ]]; check "del 成功：不计数" $?

# ---- del(): 资源本就不存在 = 成功，不能计成失败 ------------------------------
out="$(drive 'notfound() { echo "An error occurred (ResourceNotFoundException) when calling the X operation" >&2; return 255; }
del "gone-thing" notfound; printf "RC=%s\n" "$?"')"
[[ "$out" == *"RC=0"* && "$out" == *"COUNTER=0"* ]]; check "del 遇 NotFound：视为已删除，不计数" $?
[[ "$out" == *"already gone"* ]]; check "del 遇 NotFound：措辞是 already gone" $?

# ---- del(): 真实 API 错误必须计数并留名 --------------------------------------
out="$(drive 'denied() { echo "An error occurred (AccessDenied) when calling the DeleteVpc operation" >&2; return 255; }
del "vpc-123" denied; printf "RC=%s\n" "$?"')"
[[ "$out" == *"COUNTER=1"* ]]; check "del 遇 AccessDenied：计数 +1" $?
[[ "$out" == *"LEFT="*"vpc-123"* ]]; check "del 遇 AccessDenied：资源名进 LEFT_BEHIND" $?
[[ "$out" == *"RC=0"* ]]; check "del 失败仍返回 0（否则 set -e 会中断整轮清理）" $?
[[ "$out" == *"AccessDenied"* ]]; check "del 失败：把真实 API 错误打出来" $?

out="$(drive 'dep() { echo "An error occurred (DependencyViolation) when calling the DeleteSubnet operation" >&2; return 255; }
del "subnet-1" dep')"
[[ "$out" == *"COUNTER=1"* ]]; check "del 遇 DependencyViolation：计数 +1" $?

# ---- wait_gone(): 资源已消失 ------------------------------------------------
out="$(drive 'empty() { echo ""; }
wait_gone "nat" 5 empty; printf "RC=%s\n" "$?"')"
[[ "$out" == *"RC=0"* && "$out" == *"COUNTER=0"* ]]; check "wait_gone 立即消失：返回 0 且不计数" $?

out="$(drive 'none() { echo "None"; }
wait_gone "nat" 5 none; printf "RC=%s\n" "$?"')"
[[ "$out" == *"RC=0"* && "$out" == *"COUNTER=0"* ]]; check "wait_gone 认 \"None\" 为已消失" $?

# ---- wait_gone(): 超时必须返回 0 且计数（承重性质）--------------------------
out="$(drive 'still() { echo "nat-abc"; }
wait_gone "nat-abc" 5 still; printf "RC=%s\n" "$?"')"
[[ "$out" == *"RC=0"* ]]; check "wait_gone 超时返回 0（返回 1 会在 set -e 下中断整轮 teardown）" $?
[[ "$out" == *"COUNTER=1"* ]]; check "wait_gone 超时：计数 +1，让退出码带上这个信号" $?

# ---- 结尾判定：失败时非零，且成功行只在真干净时打印 -------------------------
tail_block="$(sed -n '/^if \[\[ "\$TEARDOWN_INCOMPLETE" -gt 0 \]\]; then/,/^fi/p' "$ROOT/scripts/teardown.sh")"
[[ -n "$tail_block" ]]; check "结尾存在基于计数的判定块" $?
printf '%s' "$tail_block" | grep -q 'exit 1'; check "计数 >0 时以非零退出" $?
# 成功行必须位于判定块之后（早于判定就会先宣布成功再报失败）。
# 注意匹配的是真正的 say ok 语句，不是提到这句话的注释 —— 先前用宽松的 'teardown complete'
# 会命中文件上方的注释行，于是这条断言自己先失败了一次，正好说明为何要钉住语句而非文本。
succ_ln="$(grep -n 'say ok "teardown complete' "$ROOT/scripts/teardown.sh" | head -1 | cut -d: -f1)"
chk_ln="$(grep -n '^if \[\[ "\$TEARDOWN_INCOMPLETE" -gt 0 \]\]; then' "$ROOT/scripts/teardown.sh" | head -1 | cut -d: -f1)"
[[ -n "$succ_ln" && -n "$chk_ln" && "$succ_ln" -gt "$chk_ln" ]]; check "成功行在失败判定之后（不会先宣布成功）" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
