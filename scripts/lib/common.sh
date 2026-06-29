#!/usr/bin/env bash
# common.sh — scripts/ 共享 shell：格式化输出 + 依赖检查。
# 用法：在脚本顶部 `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`。
# 设计为可被单测 source（无副作用、不自动执行），见 scripts/tests/test_common.sh。

# AWS CLI v2 默认把多行输出送进 pager（less），交互式终端里要按 q 才继续——会卡住
# install.sh / deploy-all.sh 这类无人值守/半交互脚本。统一在这里清空 AWS_PAGER，
# 覆盖所有 source 本文件的脚本里的每一次 aws 调用（比逐条加 --no-cli-pager 干净）。
export AWS_PAGER=""

# term_bg_class <colorfgbg> — 判定终端背景明暗，回显 dark|light。纯函数（无副作用、可单测）。
# COLORFGBG（konsole/rxvt/iTerm 等会设）形如 "fg;bg" 或 "fg;default;bg"，末段是背景 ANSI 色号：
# 0–6 与 8 是深色，7 与 9–15 是浅色（7=浅灰、15=白）。取末段判断；空/无法解析时回退 dark
# ——绝大多数终端默认深色背景，深底误判成浅底会让亮色字发虚，反之只是稍暗，所以默认偏向 dark。
term_bg_class() {
  local cfb="${1:-}" bg
  bg="${cfb##*;}"                       # 末段 = 背景色号
  case "$bg" in
    7|9|10|11|12|13|14|15) echo light ;;
    *)                     echo dark ;; # 含空、非数字、0–6、8
  esac
}

# 颜色：仅当 stdout 是 TTY 且未设 NO_COLOR 时启用 ANSI。按背景明暗选强度——普通蓝 34 在深底
# 上偏暗难读，深底改用亮蓝 94（青同理 36→96）；浅底保留标准蓝/青（亮色在白底反而发虚）。
# 红/绿/黄基础色两种背景都够清晰，不随主题切换。
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_RED=$'\e[31m'; _C_GREEN=$'\e[32m'; _C_YELLOW=$'\e[33m'
  _C_DIM=$'\e[2m'; _C_RESET=$'\e[0m'
  if [[ "$(term_bg_class "${COLORFGBG:-}")" == dark ]]; then
    _C_BLUE=$'\e[94m'; _C_CYAN=$'\e[96m'   # 亮蓝/亮青：深底清晰
  else
    _C_BLUE=$'\e[34m'; _C_CYAN=$'\e[36m'   # 标准蓝/青：浅底清晰
  fi
else
  _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_CYAN=''; _C_DIM=''; _C_RESET=''
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

# is_https_git_url <url> — 该 git 地址是否走 https（因而可能需要用户名/令牌认证）。
# ssh 形式（git@host:org/repo、ssh://…）用主机密钥认证，不靠 git-credentials 令牌，匿名探测
# 没有意义，所以排除——只有 https:// 的私有仓才会因缺令牌在 clone 时报 "could not read Username"。
# 纯函数，可单测。
is_https_git_url() {
  case "${1:-}" in
    https://*) return 0 ;;
    *)         return 1 ;;
  esac
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
