#!/usr/bin/env bash
# codegraph-server 下载校验：可执行测试，而不是文本存在性检查。
#
# 为什么必须是可执行的：这段校验刚被加进 deploy-all.sh 时**一次都没有执行过**——它调用
# `is_set`，而那个函数只定义在 teordown.sh 里；`if <不存在的命令>` 返回 127，在 if 条件位置
# 不触发 set -e，于是恒走 else 分支"没有可用摘要"，然后把字节暂存进 S3。sha256sum 从未被调用。
#
# 而同一个提交里加的守卫 check-invariants 8c 是 `grep -q 'sha256sum "$CG_TMP"'`，它只能确认
# 那一行**存在**，不能确认它**会跑**，所以对一棵校验完全失效的树报绿——比没有守卫更危险。
# 这套测试把真实代码块抽出来，用桩喂各种摘要形态，断言的是行为：该中止的中止，
# 且未校验的字节永远不会到达 aws s3 cp。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
DA="scripts/deploy-all.sh"
ran=0; failed=0

check() {
  local desc="$1"; shift
  ran=$((ran + 1))
  if "$@"; then echo "  ok   $desc"; else echo "  FAIL $desc"; failed=$((failed + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 用哨兵注释抽取被测块。第一版靠"起点之后第一个 `^  fi$`"推断块尾，结果落在了显式-BIN
# 守卫自己的 fi 上，抽出来的 13 行既不含校验也不含暂存调用——于是行为类断言全挂，而三条
# "未调用 s3 cp" 反而**空洞通过**，因为什么都没执行。哨兵让边界显式，下面这两条自检保证
# "哨兵被重构掉"或"块被搬空"会大声失败，而不是安静地抽出空字符串。
BLOCK="$WORK/block.sh"
awk '/# --- codegraph-acquire:begin ---/{f=1; next} /# --- codegraph-acquire:end ---/{f=0} f' \
  "$DA" > "$BLOCK"

check "找到了哨兵界定的被测块" bash -c "[[ -s '$BLOCK' ]]"
for tok in 'sha256sum' 's3 cp' 'MISMATCH' 'ALLOW_UNVERIFIED'; do
  check "被测块含关键语句：$tok" grep -qF "$tok" "$BLOCK"
done

# 运行一个场景：stub 掉外部命令，把真实代码块跑起来，回传 stdout+rc。
run_case() {  # run_case <env 赋值串> <伪造的 .sha256 内容或 __404__> <伪造的二进制内容>
  local envs="$1" sumbody="$2" binbody="$3"
  local sc="$WORK/case.sh"
  {
    printf 'set -uo pipefail\n'
    printf 'say() { local lvl="$1"; shift; printf "%%s %%s\\n" "$lvl" "$*"; }\n'
    printf 'run() { printf "RUN: %%s\\n" "$*"; "$@"; }\n'
    # 桩：aws 记录调用；但 `s3api head-object` 必须失败，否则代码走 S3 复用层
    # （"已暂存，复用"）而根本不下载——第一版就是这样让整块静默不执行的。
    # 顺带这也说明 F9 是真的：复用层不做任何校验，无条件信任上一轮暂存的字节。
    printf 'aws() { printf "AWS: %%s\\n" "$*"; if [[ "${1:-}" == "s3api" && "${2:-}" == "head-object" ]]; then return 1; fi; return 0; }\n'
    # curl 有两种真实用法，桩必须区分，否则无法单独构造"二进制下到了、摘要没下到"这个场景：
    #   1) 下载二进制：带 `-o <path>`，成功即写入字节；
    #   2) 抓摘要：无 `-o`，把内容打到 stdout。
    # 早先用一个不分情况的桩，`__404__` 会让**二进制下载**先失败，于是永远到不了校验步骤，
    # 而失败信息看起来像"下载失败"，与要测的性质无关。
    printf 'curl() {\n'
    printf '  local out="" a last=""\n'
    printf '  for a in "$@"; do if [[ "$last" == "-o" ]]; then out="$a"; fi; last="$a"; done\n'
    printf '  if [[ -n "$out" ]]; then printf "%%s" "%s" > "$out"; return 0; fi\n' "$binbody"
    printf '  if [[ "%s" == "__404__" ]]; then return 22; fi\n' "$sumbody"
    printf '  printf "%%s" "%s"\n' "$sumbody"
    printf '}\n'
    printf 'gh() { return 1; }\n'
    # 关键隔离：这台开发机上 codegraph-server 真的在 PATH 里，于是 `command -v` 命中、
    # `-x` 为真，代码直接走本地二进制暂存，永远不进下载与校验分支。第一版就是这样让
    # 每条消息断言都失败、而 "调用了 s3 cp" 反而通过的——测试必须与本机状态无关。
    printf 'command() { case "${2:-}" in gh|codegraph-server) return 1 ;; esac; builtin command "$@"; }\n'
    printf 'mktemp() { local f="%s/dl.bin"; printf "%%s" "%s" > "$f"; printf "%%s" "$f"; }\n' \
      "$WORK" "$binbody"
    printf 'DRY_RUN=false; REGION=x; BUCKET=test-bucket\n'
    printf 'HOME=%s/nohome\n' "$WORK"
    printf 'CODEGRAPH_SERVER_REPO=codegraph-ai/CodeGraph\n'
    printf 'CODEGRAPH_SERVER_TAG=v0.20.1\n'
    printf 'CODEGRAPH_SERVER_ASSET=codegraph-server-linux-arm64\n'
    printf 'CODEGRAPH_SERVER_URL_DEFAULT=https://example.invalid/asset\n'
    printf '%s\n' "$envs"
    cat "$BLOCK"
  } > "$sc"
  bash "$sc" 2>&1
  printf 'RC=%s\n' "$?"
}

BIN_BODY="the-real-bytes"
GOOD="$(printf '%s' "$BIN_BODY" | sha256sum | cut -d' ' -f1)"

echo "== 摘要匹配时放行 =="
out="$(run_case '' "$GOOD  codegraph-server-linux-arm64" "$BIN_BODY")"
check "正确摘要 → 校验通过并暂存" bash -c "printf '%s' \"\$1\" | grep -q 'checksum verified'" _ "$out"
check "正确摘要 → 确实调用了 s3 cp" bash -c "printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

echo
echo "== 摘要不匹配时必须中止，且不得暂存 =="
out="$(run_case '' "$(printf 'a%063d' 0)  asset" "$BIN_BODY")"
check "错误摘要 → 报 MISMATCH" bash -c "printf '%s' \"\$1\" | grep -q 'checksum MISMATCH'" _ "$out"
check "错误摘要 → 非零退出" bash -c "printf '%s' \"\$1\" | grep -q 'RC=1'" _ "$out"
check "错误摘要 → 未调用 s3 cp（关键）" bash -c "! printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

echo
echo "== 取不到摘要必须 fail closed（此前是静默放行）=="
out="$(run_case '' "__404__" "$BIN_BODY")"
check "摘要 404 → 拒绝暂存" bash -c "printf '%s' \"\$1\" | grep -q 'refusing to stage unverified'" _ "$out"
check "摘要 404 → 非零退出" bash -c "printf '%s' \"\$1\" | grep -q 'RC=1'" _ "$out"
check "摘要 404 → 未调用 s3 cp" bash -c "! printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

echo
echo "== 显式放行开关仍然可用 =="
out="$(run_case 'CODEGRAPH_SERVER_ALLOW_UNVERIFIED=1' "__404__" "$BIN_BODY")"
check "ALLOW_UNVERIFIED=1 → 放行但告警" bash -c "printf '%s' \"\$1\" | grep -q 'ALLOW_UNVERIFIED'" _ "$out"
check "ALLOW_UNVERIFIED=1 → 调用 s3 cp" bash -c "printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

echo
echo "== 摘要文件的各种形态 =="
out="$(run_case '' "$(printf '%s  asset\r' "$GOOD")" "$BIN_BODY")"
check "CRLF 摘要 → 仍然匹配（不再假 MISMATCH）" bash -c "printf '%s' \"\$1\" | grep -q 'checksum verified'" _ "$out"

out="$(run_case '' "SHA256 (asset) = $GOOD" "$BIN_BODY")"
check "openssl 字段序 → 仍然匹配" bash -c "printf '%s' \"\$1\" | grep -q 'checksum verified'" _ "$out"

out="$(run_case '' "asset  $GOOD" "$BIN_BODY")"
check "反序字段 → 仍然匹配" bash -c "printf '%s' \"\$1\" | grep -q 'checksum verified'" _ "$out"

out="$(run_case '' '<!DOCTYPE html><html>404</html>' "$BIN_BODY")"
check "HTML 错误页 → 报无法解析而非 MISMATCH" \
  bash -c "printf '%s' \"\$1\" | grep -q 'could not parse a sha256'" _ "$out"
check "HTML 错误页 → 未调用 s3 cp" bash -c "! printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

echo
echo "== 显式 pin 的摘要 =="
out="$(run_case "CODEGRAPH_SERVER_SHA256=$GOOD" "__404__" "$BIN_BODY")"
check "显式摘要正确 → 通过（不再被 is_set 吞掉）" \
  bash -c "printf '%s' \"\$1\" | grep -q 'checksum verified'" _ "$out"

out="$(run_case 'CODEGRAPH_SERVER_SHA256=None' "__404__" "$BIN_BODY")"
check "显式摘要为 None → 视为配置错误并中止" \
  bash -c "printf '%s' \"\$1\" | grep -q 'not a 64-hex sha256'" _ "$out"
check "显式摘要为 None → 未调用 s3 cp" bash -c "! printf '%s' \"\$1\" | grep -q 'AWS: s3 cp'" _ "$out"

out="$(run_case 'CODEGRAPH_SERVER_SHA256=deadbeef' "__404__" "$BIN_BODY")"
check "显式摘要长度不对 → 视为配置错误" \
  bash -c "printf '%s' \"\$1\" | grep -q 'not a 64-hex sha256'" _ "$out"

echo
echo "  ran=$ran failed=$failed"
[[ $failed -eq 0 ]] || exit 1
