#!/usr/bin/env bash
# test.sh — 单一分层测试入口（AGENTS.md「Testing」单一入口）。
#
# 离线默认（安全、无网络、无 Docker/AWS）：lint + unit + typecheck。
#   ./scripts/test.sh            跑离线套件
#   ./scripts/test.sh --lint     仅结构自检（check-invariants）
#   ./scripts/test.sh --unit     仅 shell 单元测试（scripts/tests/test_*.sh）
#   ./scripts/test.sh --list     列出发现的 unit 测试文件后退出
#   ./scripts/test.sh --full     离线套件 + smoke/e2e（需 Docker/AWS）
#   ./scripts/test.sh --help     本说明
#
# 退出码 0 = 全绿。pre-push 跑离线默认（见 lefthook.yml，p1）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

usage() {
  cat <<'EOF'
用法 (Usage): ./scripts/test.sh [选项]

单一分层测试入口。离线默认（安全、无网络、无 Docker/AWS）：lint + unit + typecheck。

  (无参数)     跑离线套件（lint + unit + typecheck）
  --lint       仅结构自检（check-invariants）
  --unit       仅 shell 单元测试（scripts/tests/test_*.sh）
  --list       列出发现的 unit 测试文件后退出
  --full       离线套件 + smoke/e2e（需 Docker/AWS）
  -h, --help   本说明

退出码 0 = 全绿。pre-push 跑离线默认（见 lefthook.yml，p1）。
EOF
}

# 发现 unit 测试：scripts/tests/test_*.sh，排除自递归的 test_test_sh.sh。
discover_units() {
  local f
  for f in "$ROOT"/scripts/tests/test_*.sh; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "test_test_sh.sh" ]] && continue
    printf '%s\n' "$f"
  done
}

run_lint() {
  say step "lint：结构自检 check-invariants"
  bash "$ROOT/scripts/check-invariants.sh"
}

run_unit() {
  say step "unit：shell 单元测试"
  local f rc=0 ran=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ran=$((ran + 1))
    bash "$f" || rc=1
  done < <(discover_units)
  if [[ "$ran" -eq 0 ]]; then
    say warn "未发现 unit 测试（scripts/tests/test_*.sh）"
  fi
  return "$rc"
}

# typecheck：各组件自带工具时才跑；缺工具/缺配置则 skip（离线默认不强制安装）。
run_typecheck() {
  say step "typecheck：各组件静态检查（缺工具则 skip）"
  local rc=0
  # Python（agent-container / index-service）：ruff 检查（lint+部分类型约定）。
  if have_cmd ruff; then
    for d in agent-container index-service; do
      if compgen -G "$ROOT/$d/*.py" >/dev/null 2>&1; then
        say info "ruff check $d"
        ruff check "$ROOT/$d" || rc=1
      fi
    done
  else
    say warn "skip ruff（未安装）"
  fi
  # TypeScript（bot-gateway）：有 tsconfig 才跑 tsc --noEmit。
  if [[ -f "$ROOT/bot-gateway/tsconfig.json" ]]; then
    if [[ -x "$ROOT/bot-gateway/node_modules/.bin/tsc" ]]; then
      say info "tsc --noEmit bot-gateway"
      ( cd "$ROOT/bot-gateway" && ./node_modules/.bin/tsc --noEmit ) || rc=1
    else
      say warn "skip tsc（bot-gateway 依赖未安装）"
    fi
  fi
  return "$rc"
}

run_offline() {
  local rc=0
  run_lint || rc=1
  run_unit || rc=1
  run_typecheck || rc=1
  return "$rc"
}

run_full() {
  local rc=0
  run_offline || rc=1
  say step "smoke/e2e（--full）"
  say warn "skip：smoke/e2e 占位，待组件落地（需 Docker/AWS）"
  return "$rc"
}

main() {
  local mode="offline"
  case "${1:-}" in
    "")        mode="offline" ;;
    --lint)    mode="lint" ;;
    --unit)    mode="unit" ;;
    --list)    mode="list" ;;
    --full)    mode="full" ;;
    -h|--help) usage; return 0 ;;
    *)         say err "未知参数：$1"; usage >&2; return 2 ;;
  esac

  case "$mode" in
    list)    discover_units; return 0 ;;
    lint)    run_lint ;;
    unit)    run_unit ;;
    full)    run_full ;;
    offline) run_offline ;;
  esac
  local rc=$?

  if [[ "$rc" -eq 0 ]]; then
    say ok "test.sh（$mode）：全绿"
  else
    say err "test.sh（$mode）：有失败"
  fi
  return "$rc"
}

main "$@"
