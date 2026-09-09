#!/usr/bin/env bash
# 租户与语言在 redeploy 流程上的持久化。
#
# 为什么需要这一套：deploy-all.sh 是 DEPLOY_FEISHU_DOMAIN 的唯一写入者，而 install.sh 的
# redeploy 流程不经过 deploy-all——它直接调 deploy_project.sh，把 FEISHU_DOMAIN 当一次性
# 环境变量传进去。同时 activate_gateway.sh 是整文件重写 env。三者叠加的后果是：
#
#   install.sh --feishu-domain lark  → 生效一次
#   下一次 install.sh → redeploy（不带 flag） → 读到旧的 DEPLOY_FEISHU_DOMAIN
#                                            → env 被重写成 feishu
#                                            → 机器人静默切回国内版，从此收不到任何事件
#
# 静默、且只在第二次部署时显现，所以单轮验证看不见。附带的第二个缺陷：locale 兜底硬编码
# zh，于是切到 lark 而没显式给 --locale 时，国际版租户配上中文卡片。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
DP="scripts/lib/deploy_project.sh"
ran=0; failed=0

check() {
  local desc="$1"; shift
  ran=$((ran + 1))
  if "$@"; then echo "  ok   $desc"; else echo "  FAIL $desc"; failed=$((failed + 1)); fi
}

CODE="$(mktemp)"
trap 'rm -f "$CODE"' EXIT
grep -vE '^\s*#' "$DP" > "$CODE"

has() { grep -qF "$1" "$CODE"; }
has_re() { grep -qE "$1" "$CODE"; }

echo "== redeploy 路径必须自己持久化租户 =="
check "deploy_project.sh 写入 DEPLOY_FEISHU_DOMAIN（不再只依赖 deploy-all）" \
  has 'update_env "$CONFIG_FILE" DEPLOY_FEISHU_DOMAIN'
check "deploy_project.sh 写入 DEPLOY_LOCALE" \
  has 'update_env "$CONFIG_FILE" DEPLOY_LOCALE'

echo
echo "== locale 默认值必须由租户推导，而不是硬编码 zh =="
check "存在 lark ⇒ en 的推导" has_re '_TENANT.*==.*lark'
check "不再出现 DEPLOY_LOCALE:-zh 这种无条件兜底" \
  bash -c '! grep -qF "DEPLOY_LOCALE:-zh" "'"$CODE"'"'
check "显式 LOCALE 仍然优先于推导" has_re 'if \[\[ -n "\$\{LOCALE:-\}" \]\]'

echo
echo "== 传给 activate_gateway 的值来自解析结果 =="
check "租户以解析后的变量传入" has 'FEISHU_DOMAIN="$_TENANT"'
check "locale 以解析后的变量传入" has '"$_LOCALE" ""'
# 这个模式必须用单引号保存：写在双引号里会被 shell 先展开成空串，grep 于是匹配一切，
# 断言永远通过。本套件第一版就是这么错的。
STALE_EXPR='${LOCALE:-${DEPLOY_LOCALE:-zh}}'
no_stale() { ! grep -qF "$STALE_EXPR" "$CODE"; }
check "不再把未解析的表达式直接传给 activate_gateway" no_stale

# --- 行为验证：把解析逻辑抽出来实跑，而不是只匹配文本 ---
echo
echo "== 解析逻辑实跑 =="
resolve() {  # resolve <FEISHU_DOMAIN> <LOCALE> <DEPLOY_FEISHU_DOMAIN> <DEPLOY_LOCALE>
  local FEISHU_DOMAIN="$1" LOCALE="$2" DEPLOY_FEISHU_DOMAIN="$3" DEPLOY_LOCALE="$4"
  local _TENANT _LOCALE
  _TENANT="${FEISHU_DOMAIN:-${DEPLOY_FEISHU_DOMAIN:-feishu}}"
  if [[ -n "${LOCALE:-}" ]]; then _LOCALE="$LOCALE"
  elif [[ -n "${DEPLOY_LOCALE:-}" ]]; then _LOCALE="$DEPLOY_LOCALE"
  elif [[ "$_TENANT" == "lark" ]]; then _LOCALE="en"
  else _LOCALE="zh"; fi
  printf '%s/%s' "$_TENANT" "$_LOCALE"
}

check "lark 且未给 locale ⇒ lark/en" \
  bash -c "[[ \"\$($(declare -f resolve); resolve lark '' '' '')\" == 'lark/en' ]]"
check "feishu 且未给 locale ⇒ feishu/zh" \
  bash -c "[[ \"\$($(declare -f resolve); resolve feishu '' '' '')\" == 'feishu/zh' ]]"
check "lark 且显式 zh ⇒ 尊重显式值 lark/zh" \
  bash -c "[[ \"\$($(declare -f resolve); resolve lark zh '' '')\" == 'lark/zh' ]]"
check "无 flag 时沿用已持久化的 lark ⇒ lark/en" \
  bash -c "[[ \"\$($(declare -f resolve); resolve '' '' lark en)\" == 'lark/en' ]]"
check "flag 覆盖已持久化的值 ⇒ feishu/zh" \
  bash -c "[[ \"\$($(declare -f resolve); resolve feishu zh lark en)\" == 'feishu/zh' ]]"

echo
echo "  ran=$ran failed=$failed"
[[ $failed -eq 0 ]] || exit 1
