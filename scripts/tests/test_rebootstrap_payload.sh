#!/usr/bin/env bash
# rebootstrap_in_place 的远端 payload：退出码与停启顺序。
#
# 为什么必须有这个套件：这段 payload 是全仓风险最高的 shell —— 它在共享主机上把**每个项目**的
# gateway 和 bridge 停掉数分钟，带两层嵌套 trap、一次回滚、一把 flock 和一个 break-before-make
# 窗口，而在此之前没有任何测试执行过它。
#
# 它确实藏着一个静默 bug（本套件的第一条断言就是为它写的）：start_captured() 在 POSIX sh 里设的
# 是**全局** rc，而 EXIT trap 又用同名变量保存真实退出码并在最后 `exit $rc`。on_failure 先跑、
# 且回滚重启成功时把 rc 抹成 0 —— 也就是正常情况。于是：bootstrap 失败 → trap 回滚 env 并重启单元
# → payload 退出 0 → SSM 报 Success → 部署侧走 Success 分支、从不取 StandardErrorContent →
# 调用方给实例打上 ArtifactSig=<目标签名> → 主机跑着旧代码，却带着一个声称是新代码的标签，
# 于是之后每次部署都打印「already on the current base artifacts — skipping re-bootstrap」。
# 永久卡死，而这个文件的头注释承诺的正相反。
#
# 方法：把 heredoc 原文抽出来交给 bash 自己插值（被测对象就是**发货的那段文本**），再用一个
# stub PATH 在本机跑它。不需要 aws、不需要 SSM、不需要 root。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/scripts/lib/provision_index_service.sh"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# 渲染 payload。注意不要用 `sed -n '/^rebootstrap_in_place() {/,/^}$/p'`：heredoc 里
# start_captured() / on_failure() 的右花括号在第 0 列，范围会在 payload 内部提前结束。
render() {
  {
    printf 'remote_cmd="$(cat <<REMOTE\n'
    sed -n '/^  remote_cmd="\$(cat <<REMOTE$/,/^REMOTE$/p' "$SRC" | sed '1d'
    printf ')"\nprintf %%s "$remote_cmd"\n'
  } > "$T/render.sh"
  BUCKET=test-bucket REGION=xx-test-1 MAX_FILES=1234 MODEL=test-model \
    GLOSSARY_MAX_FILES=77 REBOOT_UNITS_FILE="$T/units" \
    bash "$T/render.sh" > "$T/payload.sh" 2>/dev/null
}
render
[[ -s "$T/payload.sh" ]]; check "能从源码渲染出 payload" $?
grep -q 'start_captured' "$T/payload.sh"; check "渲染出的 payload 含 start_captured" $?

# stub：把 argv 记到一个日志里。payload 跑在 sh 下，所以影子化 bash 是安全的，
# 并且让我们能用环境变量控制 bootstrap 的退出码。
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in
  list-units) printf 'bot-gateway@a.service\nindex-bridge-a.service\nbot-gateway@b.service\n' ;;
  start) [ "${FAIL_START:-}" = "$2" ] && exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/bash" <<'EOF'
#!/bin/sh
echo "bash $*" >> "$STUB_LOG"
case "$*" in *bootstrap.sh*) exit "${BOOTSTRAP_RC:-0}" ;; esac
exit 0
EOF
cat > "$T/bin/aws" <<'EOF'
#!/bin/sh
echo "aws $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$T/bin"/*

run_payload() {  # run_payload <bootstrap-rc> [extra env assignments...]
  : > "$T/log"
  printf 'OLD=1\n' > "$T/env"
  env PATH="$T/bin:$PATH" STUB_LOG="$T/log" BOOTSTRAP_RC="$1" \
      INDEX_ENV_FILE="$T/env" REBOOT_LOCK_FILE="$T/lock" REBOOT_UNITS_FILE="$T/units" \
      "${@:2}" sh "$T/payload.sh" >"$T/out" 2>&1
  echo $?
}

# ---- 1) bootstrap 失败必须以非零退出（这条就是那个 bug）----------------------
rc="$(run_payload 1)"
[[ "$rc" -ne 0 ]]; check "bootstrap 失败时 payload 以非零退出（trap 与 start_captured 不得共用 rc）" $?

# ---- 2) 失败时回滚 env 且把捕获到的每个单元都重启回去 ------------------------
grep -q '^OLD=1$' "$T/env" 2>/dev/null; check "失败时 env 文件被回滚" $?
started="$(grep -c 'systemctl start' "$T/log" || true)"
[[ "$started" -eq 3 ]]; check "失败时捕获到的 3 个单元都被重启（实际 $started）" $?

# ---- 3) 捕获必须早于停止；bootstrap 夹在停与启之间 --------------------------
cap_ln="$(grep -n 'list-units' "$T/log" | head -1 | cut -d: -f1)"
stop_ln="$(grep -n 'systemctl stop' "$T/log" | head -1 | cut -d: -f1)"
[[ -n "$cap_ln" && -n "$stop_ln" && "$cap_ln" -lt "$stop_ln" ]]; check "先捕获再停止" $?
last_stop="$(grep -n 'systemctl stop' "$T/log" | tail -1 | cut -d: -f1)"
boot_ln="$(grep -n 'bootstrap.sh' "$T/log" | head -1 | cut -d: -f1)"
[[ -n "$boot_ln" && "$boot_ln" -gt "$last_stop" ]]; check "bootstrap 在最后一次 stop 之后运行" $?

# ---- 4) 停掉的集合 == 捕获的集合 --------------------------------------------
stopped="$(grep -oE 'systemctl stop .*' "$T/log" | sed 's/systemctl stop //' | tr ' ' '\n' | grep -c . || true)"
[[ "$stopped" -eq 3 ]]; check "停止的单元数与捕获的一致（实际 $stopped）" $?

# ---- 5) 成功路径：退出 0，且备份被清掉 --------------------------------------
rc="$(run_payload 0)"
[[ "$rc" -eq 0 ]]; check "bootstrap 成功时 payload 退出 0" $?
[[ ! -f "$T/env.rebootstrap-bak" ]]; check "成功后不留备份文件" $?

# ---- 6) 并发第二次运行必须 exit 75 且一个单元都没停 -------------------------
if command -v flock >/dev/null 2>&1; then
  : > "$T/log"; printf 'OLD=1\n' > "$T/env"
  exec 9>"$T/lock"
  if flock -n 9; then
    set +e
    env PATH="$T/bin:$PATH" STUB_LOG="$T/log" BOOTSTRAP_RC=0 \
        INDEX_ENV_FILE="$T/env" REBOOT_LOCK_FILE="$T/lock" REBOOT_UNITS_FILE="$T/units" \
        sh "$T/payload.sh" >/dev/null 2>&1
    rc=$?
    set -e
    flock -u 9
    [[ "$rc" -eq 75 ]]; check "已有实例持锁时第二次运行 exit 75（实际 $rc）" $?
    [[ "$(grep -c 'systemctl stop' "$T/log" || true)" -eq 0 ]]; check "被锁挡住时一个单元都没停" $?
  fi
  exec 9>&-
fi

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
