#!/usr/bin/env bash
# common.sh — scripts/ 共享 shell：格式化输出 + 依赖检查。
# 用法：在脚本顶部 `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`。
# 设计为可被单测 source（无副作用、不自动执行），见 scripts/tests/test_common.sh。

# AWS CLI v2 默认把多行输出送进 pager（less），交互式终端里要按 q 才继续——会卡住
# install.sh / deploy-all.sh 这类无人值守/半交互脚本。统一在这里清空 AWS_PAGER，
# 覆盖所有 source 本文件的脚本里的每一次 aws 调用（比逐条加 --no-cli-pager 干净）。
export AWS_PAGER=""

# 颜色：仅当 stdout 是 TTY 且未设 NO_COLOR 时启用 ANSI。
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_RED=$'\e[31m'; _C_GREEN=$'\e[32m'; _C_YELLOW=$'\e[33m'
  _C_BLUE=$'\e[34m'; _C_DIM=$'\e[2m'; _C_RESET=$'\e[0m'
else
  _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_DIM=''; _C_RESET=''
fi

# say <level> <message...> — 结构化人读输出。level: ok|info|warn|err|step。
# err/warn 走 stderr，其余走 stdout。
say() {
  local level="$1"; shift
  local msg="$*" color marker stream=1
  case "$level" in
    ok)   color="$_C_GREEN";  marker='✓' ;;
    info) color="$_C_BLUE";   marker='•' ;;
    step) color="$_C_BLUE";   marker='▶' ;;
    warn) color="$_C_YELLOW"; marker='!'; stream=2 ;;
    err)  color="$_C_RED";    marker='✗'; stream=2 ;;
    *)    color="$_C_DIM";    marker='-' ;;
  esac
  printf '%s%s %s%s\n' "$color" "$marker" "$msg" "$_C_RESET" >&"$stream"
}

# have_cmd <name> — 命令存在返回 0，否则非零。静默。
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# run_timeout <secs> <cmd...> — 跑命令并限定墙钟时长，跨平台。
# GNU coreutils 的 `timeout` 在 Linux 自带；macOS 没有（brew 装了叫 `gtimeout`）。
# 有 timeout/gtimeout 就用（超时退 124），都没有就直接跑命令（不加墙钟限制）——
# 调用方本就把它当尽力而为的预检（AWS CLI 自身的 --cli-*-timeout 已能兜住挂起），
# 所以缺 timeout 只是少一层保险，而不是让 mac 上报 "command not found"。
run_timeout() {
  local secs="$1"; shift
  if have_cmd timeout; then timeout "$secs" "$@"
  elif have_cmd gtimeout; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# require_cmd <name> [hint] — 命令缺失则报错（含命令名）并返回 1。
require_cmd() {
  local name="$1" hint="${2:-}"
  if have_cmd "$name"; then
    return 0
  fi
  if [[ -n "$hint" ]]; then
    say err "缺少依赖命令：${name}（${hint}）"
  else
    say err "缺少依赖命令：$name"
  fi
  return 1
}
