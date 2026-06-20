#!/usr/bin/env bash
# check-invariants.sh — 快速无网络结构 lint（pre-commit / test.sh --lint 调用）。
# 校验 AGENTS.md 约定中可机检的子集：单一真相源、双语配对、顶层目录存在性
# （注：只校验顶层组件目录存在，不做结构文档树逐项 diff）。
# 失败即非零退出，逐条打印问题。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
err() { printf '  ✗ %s\n' "$1" >&2; fail=1; }
ok()  { printf '  ✓ %s\n' "$1"; }

echo "check-invariants: $ROOT"

# 1. AGENTS.md 存在，CLAUDE.md 仅 import @AGENTS.md
if [[ -f AGENTS.md ]]; then ok "AGENTS.md 存在"; else err "缺少 AGENTS.md（AI 约定单一真相源）"; fi
if [[ -f CLAUDE.md ]]; then
  if grep -qx '@AGENTS.md' CLAUDE.md; then ok "CLAUDE.md import @AGENTS.md"
  else err "CLAUDE.md 应仅含一行 '@AGENTS.md'"; fi
else err "缺少 CLAUDE.md"; fi

# 2. docs/agent/architecture.md 存在且被 AGENTS.md 引用
if [[ -f docs/agent/architecture.md ]]; then ok "docs/agent/architecture.md 存在"
else err "缺少 docs/agent/architecture.md"; fi
grep -q 'docs/agent/architecture.md' AGENTS.md || err "AGENTS.md 未引用 docs/agent/architecture.md"

# 3. 双语 _en/_zh 配对：docs/ 下每个 *_en.md 必须有 *_zh.md，反之亦然
shopt -s nullglob
for f in docs/*_en.md; do
  [[ -f "${f%_en.md}_zh.md" ]] || err "双语缺配对：$f 缺少 ${f##*/} 对应的 _zh.md"
done
for f in docs/*_zh.md; do
  [[ -f "${f%_zh.md}_en.md" ]] || err "双语缺配对：$f 缺少 ${f##*/} 对应的 _en.md"
done
shopt -u nullglob
[[ $fail -eq 0 ]] && ok "docs/ 双语 _en/_zh 配对完整"

# 4. 结构文档存在
[[ -f docs/structure_zh.md && -f docs/structure_en.md ]] \
  && ok "结构文档双语齐全" || err "缺少 docs/structure_{zh,en}.md"

# 5. 顶层组件目录都在磁盘上存在（与 structure 文档对齐）
for d in agent-container bot-gateway index-service infra config scripts docs; do
  [[ -d "$d" ]] && ok "顶层目录存在: $d" || err "structure 引用的顶层目录缺失: $d"
done

# 6. 设计真相源已导入
for f in docs/design/requirements_zh.md docs/design/architecture-overview_zh.md; do
  [[ -f "$f" ]] && ok "设计真相源: $f" || err "缺少设计真相源: $f"
done

if [[ $fail -ne 0 ]]; then
  echo "check-invariants: FAILED" >&2
  exit 1
fi
echo "check-invariants: OK"
