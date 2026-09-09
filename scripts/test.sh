#!/usr/bin/env bash
# test.sh — 单一分层测试入口（AGENTS.md「Testing」单一入口）。
#
# 离线默认（安全、无网络、无 Docker/AWS）：lint + unit + typecheck。
#   ./scripts/test.sh            跑离线套件
#   ./scripts/test.sh --lint     仅结构自检（check-invariants）
#   ./scripts/test.sh --unit     仅 shell 单元测试（scripts/tests/test_*.sh）
#   ./scripts/test.sh --list     列出发现的 unit 测试文件后退出
#   ./scripts/test.sh --full     离线套件 + e2e（对已部署 Runtime 真实问答；缺部署自动 skip）+ smoke（占位）
#   ./scripts/test.sh --help     本说明
#
# 退出码 0 = 全绿，但"全绿"会连同被跳过的套件一起报告 —— 见 SKIPPED。
# 没有 git hook：本仓库不带 lefthook.yml / pre-commit 配置，唯一的机械闸口是 CI
# (.github/workflows/ci.yml)。本地请在推之前自行运行本脚本。
set -uo pipefail
# 被跳过的套件名；结尾的判定行会一并报告，避免"全绿"掩盖没跑的断言。
SKIPPED=()

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

退出码 0 = 全绿（被跳过的套件会在结尾列出）。机械闸口是 CI，不是 git hook。
EOF
}

# 发现 shell unit 测试：scripts/tests/test_*.sh。
# test_test_sh.sh 会再调本脚本（轻量子命令）——它调用时置 _TEST_SH_SELF=1，
# 此处据此排除自身，防递归。
discover_units() {
  local f
  for f in "$ROOT"/scripts/tests/test_*.sh; do
    [[ -e "$f" ]] || continue
    [[ "${_TEST_SH_SELF:-}" == "1" && "$(basename "$f")" == "test_test_sh.sh" ]] && continue
    printf '%s\n' "$f"
  done
}

# 发现 Python 测试目录：<component>/tests/ 含 test_*.py 的组件目录。
#
# 这个列表是硬编码的，所以新增组件必须同时改这里——否则它的测试会**静默不跑**，
# 而套件依然全绿。evaluations/citation-evaluator 就是这么加进来的。
discover_py_units() {
  local d
  for d in agent-container index-service evaluations/citation-evaluator; do
    if compgen -G "$ROOT/$d/tests/test_*.py" >/dev/null 2>&1; then
      printf '%s\n' "$ROOT/$d/tests"
    fi
  done
}

run_lint() {
  local rc=0
  say step "lint：结构自检 check-invariants / repo structure invariants"
  bash "$ROOT/scripts/check-invariants.sh" || rc=1
  say step "lint：版本钉死防漂移 check-versions / pinned-version drift"
  bash "$ROOT/scripts/check-versions.sh" || rc=1
  # IAM policy documents are strings inside shell scripts, so a malformed one is invisible until
  # a deploy fails with MalformedPolicyDocument — after the phases that cost real minutes. This
  # also blocks the two privilege-escalation shapes (unconditioned iam:PassRole,
  # iam:AttachRolePolicy without an iam:PolicyARN condition) from coming back.
  say step "lint：IAM 策略文档校验 validate_iam_policies / IAM policy documents"
  python3 "$ROOT/scripts/tests/validate_iam_policies.py" || rc=1
  # The licence manifest was verified correct by hand once, at real cost, and then nothing in the
  # repo referenced it — so the next npm install or pip freeze would have silently made it wrong.
  # Set membership and versions are decidable offline from the lock files; licence STRINGS need the
  # network and stay a release-time task.
  say step "lint：许可清单漂移校验 validate_license_manifest / licence manifest drift"
  python3 "$ROOT/scripts/tests/validate_license_manifest.py" || rc=1
  # 可观测接线：ADOT 装了但不经 opentelemetry-instrument 启动 = 零遥测，而所有其他检查都会是绿的。
  # 这个缺陷在本仓真实存在过数月，症状只是"没有数据"，没有任何断言会失败。
  say step "lint：可观测接线校验 validate_observability_wiring / observability wiring"
  python3 "$ROOT/scripts/tests/validate_observability_wiring.py" || rc=1
  return "$rc"
}

run_unit() {
  local rc=0 ran=0 f
  # 1) shell 单元测试
  say step "unit：shell 单元测试 / shell unit tests"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ran=$((ran + 1))
    bash "$f" || rc=1
  done < <(discover_units)
  # 2) Python 单元测试（pytest）；缺 pytest 则 skip。
  local py_dirs=()
  while IFS= read -r f; do [[ -n "$f" ]] && py_dirs+=("$f"); done < <(discover_py_units)
  if [[ "${#py_dirs[@]}" -gt 0 ]]; then
    say step "unit：Python 单元测试 / Python unit tests (pytest)"
    if have_cmd pytest; then
      ran=$((ran + ${#py_dirs[@]}))
      # Capture the output so FRAMEWORK-INTERNAL skips become visible. The accumulator only ever
      # tracked runner-level skips (the pytest binary being absent), so
      # `pytest.skip(..., allow_module_level=True)` was invisible — and two suites use it when
      # codegraph-server is not on PATH, which is ALWAYS true in CI (the binary is aarch64 and the
      # runner is x86_64). That silently removed the only tests that drive the bridge over a real
      # MCP session, including the singleton-writer-lock concurrency behaviour, under a fully green
      # unqualified verdict — exactly the misreport this accumulator exists to prevent.
      local _py_out _py_skipped
      _py_out="$(pytest -q -rs "${py_dirs[@]}" 2>&1)" || rc=1
      printf '%s\n' "$_py_out"
      _py_skipped="$(printf '%s' "$_py_out" | grep -oE '[0-9]+ skipped' | tail -1 | grep -oE '^[0-9]+' || true)"
      [[ -n "$_py_skipped" && "$_py_skipped" -gt 0 ]] && SKIPPED+=("pytest:${_py_skipped}-tests-skipped")
    else
      say warn "skip pytest（未安装） / not installed"; SKIPPED+=("pytest")
    fi
  fi
  # 3) TypeScript 单元测试（jest）；有 jest.config + node_modules 才跑。
  for d in bot-gateway; do
    if [[ -f "$ROOT/$d/jest.config.cjs" && -x "$ROOT/$d/node_modules/.bin/jest" ]]; then
      say step "unit：TypeScript 单元测试 / TypeScript unit tests (jest ${d})"
      ran=$((ran + 1))
      local _js_out _js_skipped
      _js_out="$( cd "$ROOT/$d" && npx jest -c jest.config.cjs --no-coverage --passWithNoTests 2>&1 )" || rc=1
      printf '%s\n' "$_js_out"
      _js_skipped="$(printf '%s' "$_js_out" | grep -oE '[0-9]+ skipped' | tail -1 | grep -oE '^[0-9]+' || true)"
      [[ -n "$_js_skipped" && "$_js_skipped" -gt 0 ]] && SKIPPED+=("jest:${_js_skipped}-tests-skipped")
    elif [[ -f "$ROOT/$d/jest.config.cjs" ]]; then
      say warn "skip jest（${d} 依赖未安装） / dependencies not installed in ${d}"; SKIPPED+=("jest")
    fi
  done
  if [[ "$ran" -eq 0 ]]; then
    say warn "未发现 unit 测试 / no unit tests found (scripts/tests/test_*.sh, <component>/tests/test_*.py)"
  fi
  return "$rc"
}

# typecheck：各组件自带工具时才跑；缺工具/缺配置则 skip（离线默认不强制安装）。
run_typecheck() {
  say step "typecheck：各组件静态检查 / static checks per component (skipped when a tool is absent)"
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
    say warn "skip ruff（未安装） / not installed"; SKIPPED+=("ruff")
  fi
  # TypeScript（bot-gateway）：有 tsconfig 才跑 tsc --noEmit。
  if [[ -f "$ROOT/bot-gateway/tsconfig.json" ]]; then
    if [[ -x "$ROOT/bot-gateway/node_modules/.bin/tsc" ]]; then
      say info "tsc --noEmit bot-gateway"
      ( cd "$ROOT/bot-gateway" && ./node_modules/.bin/tsc --noEmit ) || rc=1
    else
      say warn "skip tsc（bot-gateway 依赖未安装） / bot-gateway dependencies not installed"; SKIPPED+=("tsc")
    fi
  fi
  # ESLint（bot-gateway）：AGENTS.md 约定「ESLint 即格式化器」，纳入离线套件。
  if [[ -f "$ROOT/bot-gateway/eslint.config.mjs" ]]; then
    if [[ -x "$ROOT/bot-gateway/node_modules/.bin/eslint" ]]; then
      say info "eslint bot-gateway"
      ( cd "$ROOT/bot-gateway" && ./node_modules/.bin/eslint src/ tests/ ) || rc=1
    else
      say warn "skip eslint（bot-gateway 依赖未安装） / bot-gateway dependencies not installed"; SKIPPED+=("eslint")
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

# e2e：对已部署 Runtime 跑真实问答（scripts/e2e-probe.py）。
# 退出码约定：0 全通过；1 有探针失败（真问题，置 rc=1）；2 无法运行（缺 boto3 / 缺
# .local/deploy-config 的 ARN / 缺 projects.json）——视为 skip，不阻塞离线/无部署环境的 --full。
run_e2e() {
  say step "e2e：对已部署 Runtime 跑真实端到端问答 / real end-to-end Q&A against a deployed runtime"
  if ! have_cmd python3; then
    say warn "skip e2e（未安装 python3） / python3 not installed"; SKIPPED+=("e2e")
    return 0
  fi
  python3 "$ROOT/scripts/e2e-probe.py"
  local erc=$?
  case "$erc" in
    0) say ok "e2e：全部探针通过 / all probes passed" ; return 0 ;;
    2) say warn "skip e2e（缺依赖 / 未部署 / 无 projects.json） / missing deps, nothing deployed, or no projects.json"; SKIPPED+=("e2e") ; return 0 ;;
    *) say err "e2e：有探针失败 / a probe failed" ; return 1 ;;
  esac
}

run_full() {
  local rc=0
  run_offline || rc=1
  say step "smoke/e2e（--full） / smoke and e2e"
  say warn "skip：smoke 占位 / smoke is a placeholder pending components (needs Docker)"
  run_e2e || rc=1
  return "$rc"
}

main() {
  local mode="offline"
  case "${1:-}" in
    "")        mode="offline" ;;
    --lint)    mode="lint" ;;
    --unit)    mode="unit" ;;
    --list)    mode="list" ;;
    --list-py) mode="list-py" ;;
    --full)    mode="full" ;;
    -h|--help) usage; return 0 ;;
    *)         say err "未知参数 / unknown argument: $1"; usage >&2; return 2 ;;
  esac

  case "$mode" in
    list)    discover_units; return 0 ;;
    list-py) discover_py_units; return 0 ;;
    lint)    run_lint ;;
    unit)    run_unit ;;
    full)    run_full ;;
    offline) run_offline ;;
  esac
  local rc=$?

  if [[ "$rc" -eq 0 ]]; then
    if [[ ${#SKIPPED[@]} -gt 0 ]]; then
      # A green light over a silently-skipped suite is a misreport, not a pass: a fresh clone with
      # no `npm ci` runs zero TypeScript tests and used to print an unqualified 全绿 — ~2% of the
      # assertion count, reported as 100%. Name the gaps on the verdict line itself.
      say ok "test.sh（${mode}）：全绿 — 但已跳过 ${#SKIPPED[@]} 个套件 / SKIPPED: ${SKIPPED[*]}"
      say warn "跳过的套件未做任何断言；装齐依赖后重跑才算真正通过 / install deps and re-run for a real pass"
    else
      say ok "test.sh（${mode}）：全绿 / all green"
    fi
  else
    say err "test.sh（${mode}）：有失败 / FAILURES — see the ✗ lines above"
  fi
  return "$rc"
}

main "$@"
