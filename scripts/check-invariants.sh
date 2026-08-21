#!/usr/bin/env bash
# check-invariants.sh — 快速无网络结构 lint（pre-commit / test.sh --lint 调用）。
# 校验 AGENTS.md 约定中可机检的子集：唯一依据、双语配对、顶层目录
# 双向 diff（structure_zh.md 收录的顶层目录 ↔ 磁盘实际目录）。
# 失败即非零退出，逐条打印问题。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
err() { printf '  ✗ %s\n' "$1" >&2; fail=1; }
ok()  { printf '  ✓ %s\n' "$1"; }

echo "check-invariants: $ROOT"

# 1. AGENTS.md 存在
if [[ -f AGENTS.md ]]; then ok "AGENTS.md 存在"; else err "缺少 AGENTS.md（AI 约定的唯一依据）"; fi

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

# 5. 顶层目录 ↔ structure_zh.md 双向对齐（AGENTS.md：改顶层目录必须同步结构文档）
#    文档侧：代码块里顶格的 `xxx/` 行；磁盘侧：仓库根的实际目录（.git 与 gitignore 的
#    .local 除外——.local 在文档中有收录但不要求磁盘存在）。
if [[ -f docs/structure_zh.md ]]; then
  doc_dirs="$(grep -oE '^[A-Za-z0-9_.-]+/' docs/structure_zh.md | tr -d '/' | sort -u)"
  disk_dirs="$(find . -maxdepth 1 -mindepth 1 -type d ! -name '.git' ! -name '.local' \
    -printf '%f\n' 2>/dev/null | sort -u || ls -d */ 2>/dev/null | tr -d '/' | sort -u)"
  struct_ok=1
  while IFS= read -r d; do
    [[ -z "$d" || "$d" == ".local" ]] && continue
    [[ -d "$d" ]] || { err "structure_zh.md 收录的顶层目录磁盘上缺失: $d"; struct_ok=0; }
  done <<< "$doc_dirs"
  while IFS= read -r d; do
    [[ -z "$d" || "$d" == .* ]] && continue
    # Skip anything git already ignores. The dot-prefix skip above covers .local/ and friends, but
    # NOT non-dotted generated dirs — venv/, coverage/, dist/, reports/, cdk.out/. A developer who
    # follows the README and creates a virtualenv in the repo root would fail this lint, and an
    # unexplained red in the lint layer is how people learn to stop running the suite.
    git check-ignore -q "$d" 2>/dev/null && continue
    grep -qE "^${d}/" docs/structure_zh.md \
      || { err "顶层目录未收录进 structure_zh.md: $d（改顶层目录须同步结构文档）"; struct_ok=0; }
  done <<< "$disk_dirs"
  [[ "$struct_ok" -eq 1 ]] && ok "顶层目录与 structure_zh.md 双向一致"
fi

# 6. 设计权威依据已导入（structure_*.md 收录的 design/ 权威依据；改名/删除须同步两处）
for f in docs/design/requirements_zh.md docs/design/architecture-overview_zh.md \
         docs/design/agent-container_zh.md docs/design/multi-repo-isolation_zh.md; do
  [[ -f "$f" ]] && ok "设计权威依据: $f" || err "缺少设计权威依据: $f"
done

# 7. 全局共享 IAM 角色的策略 Resource 不得钉死 ${REGION}
#    source-truth-index-role / source-truth-dau-lambda-role 是账号级全局角色，被多区域共用，
#    而 put-role-policy 是覆盖写：策略 Resource ARN 若钉单区 ${REGION}，第二区域部署会改写它、
#    静默撤销第一区域的权限（2026-06-29 新加坡部署据此打挂东京）。这些资源型 ARN 的 region 段
#    必须用 '*'，靠 account + 资源名前缀兜底。只查易越权的服务面（lambda/events 的 ARN 是按区
#    构造的合法用法，不在此列）。
guard_hits="$(grep -nE 'arn:aws:(logs|bedrock|bedrock-agentcore|secretsmanager|s3[a-z-]*):[a-z0-9-]*\$\{REGION\}:' \
  scripts/lib/provision_iam.sh scripts/lib/apply-dau-lambda.sh 2>/dev/null || true)"
if [[ -n "$guard_hits" ]]; then
  err "全局共享角色策略 Resource 钉死了 \${REGION}（多区部署会互相覆盖，改用 '*'）："
  printf '      %s\n' "$guard_hits" >&2
else
  ok "全局共享角色策略 Resource 未钉死 \${REGION}（多区域安全）"
fi

# 8. 不得出现非 aws-samples 的 GitHub slug 作为默认值
#    发布仓的克隆、二进制下载都从默认 slug 取；默认值若指向个人账号，外部用户一执行就失败，
#    或静默依赖一个私人仓库。这条曾经修好又被回退（deploy-all.sh 的 CODEGRAPH_SERVER_REPO），
#    所以改由机器守卫，而不是靠人记得。
slug_hits="$(grep -nE '(github\.com/|githubusercontent\.com/|:-)[A-Za-z0-9_.-]+/(source-truth|sample-code-qa-on-agentcore)' \
  scripts/*.sh scripts/lib/*.sh README.md README_zh.md docs/runbook.md 2>/dev/null \
  | grep -vE '(aws-samples|Interkarma)/' || true)"
if [[ -n "$slug_hits" ]]; then
  err "出现非 aws-samples 的 GitHub slug 默认值（外部用户会拉不到）："
  printf '      %s\n' "$slug_hits" >&2
else
  ok "GitHub slug 默认值均为 aws-samples"
fi

# 9. 公开仓不得包含真实人名 / 客户环境 / 竞品名
#    docs/design/ 由内部交付物导入，曾带负责人姓名、客户内网环境描述和竞品对比。这类内容进公开
#    仓是隐私与保密问题，且一旦被翻译/引用就难以收回，所以在提交前拦下。
pii_hits="$(grep -rlnE '曹豹|晨哥|老白|WorkBuddy|GenSpark' docs/ 2>/dev/null || true)"
if [[ -n "$pii_hits" ]]; then
  err "文档中残留真实人名 / 竞品名（公开仓不可含）："
  printf '      %s\n' "$pii_hits" >&2
else
  ok "文档无真实人名 / 竞品名残留"
fi

if [[ $fail -ne 0 ]]; then
  echo "check-invariants: FAILED" >&2
  exit 1
fi
echo "check-invariants: OK"
