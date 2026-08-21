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

# 枚举被 git 跟踪的文件。这是第 3b / 8 / 9 三项共用的输入，也是它们共同的失效点：
# 原先每处都写 `git ls-files … 2>/dev/null || true`，于是在**没有 .git 的树**里
# （GitHub 源码 zip、release tarball、git archive 导出、不含 .git 的 Docker build
# context）"fatal: not a git repository" 被吞掉、清单为空、`xargs -r` 什么都不跑，
# 空输出被读成"干净"——三个守卫同时报绿，而它们正是为前三次事故写的。CI 用真 checkout，
# 所以 CI 永远看不到这个失效；踩到的恰好是最需要这些守卫的外部使用者。
# 所以：枚举不出来就是硬失败，绝不静默通过。
tracked_files() {  # tracked_files [pathspec...]
  git ls-files "$@" 2>/dev/null
}

# 可枚举性必须在**父 shell** 里断言一次，不能放在 tracked_files 内部：那个函数的每个调用点都在
# 命令替换 `$(...)` 里，而命令替换是子 shell —— 在里面调 err 设置的 fail=1 根本传不回来。
# （我第一版就是这么写的，于是"修好的"守卫在无 .git 的树上依旧全绿。）
GIT_ENUMERABLE=1
if ! _probe="$(git ls-files 2>/dev/null)" || [[ -z "$_probe" ]]; then
  GIT_ENUMERABLE=0
  err "无法枚举 git 跟踪文件（不是 git 仓库，或清单为空）——第 3b/7/8/9 项全部依赖它。"
  printf '      这些检查在无 .git 的树上（GitHub 源码 zip / release tarball / git archive 导出 /
' >&2
  printf '      不含 .git 的 Docker build context）会因清单为空而静默报绿，所以此处直接判失败。
' >&2
fi
unset _probe

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

# 3b. 每个 docs/ 下的 md 必须"要么成对，要么被显式豁免"。
#     旧写法只 glob docs/*_en.md ↔ docs/*_zh.md，于是**中性文件名等于自动豁免**：runbook.md
#     （整个部署 / 接入飞书 / 验证 / 运维 / 排障流程都在里面）就这样绕过了检查，structure_en.md
#     里甚至把这个豁免写成了"设计如此"。结果是：唯一能发现"英文读者无法部署"的机械检查，恰好
#     把最大的那份文档排除在外。
#     改成白名单模型：新增一份中文独有文档，必须显式写进 DOC_CHINESE_ONLY —— 那是一个在 review
#     里看得见的决定，而不是一次悄悄的默认。
DOC_CHINESE_ONLY=(
  # 设计依据文档，已在 docs/design/README.md 自我声明为中文
  "docs/design/README.md"
  "docs/design/requirements_zh.md"
  "docs/design/architecture-overview_zh.md"
  "docs/design/agent-container_zh.md"
  "docs/design/multi-repo-isolation_zh.md"
  # 研究性笔记（spike），结论已被 architecture / README 吸收
  "docs/agent/cardkit-streaming-spike.md"
  "docs/agent/indexing-performance-spike.md"
  "docs/agent/perf-comparison.md"
  # 面向贡献者与 AI 协作者的约定，主语言中文（AGENTS.md 自身已声明）
  "docs/README.md"
  "docs/agent/architecture.md"
  "docs/agent/invariants.md"
  "docs/glossary.md"
  "docs/agent/glossary.md"
  "docs/agent/playbooks.md"
  "docs/agent/TEMPLATE-spike.md"
)
# 故意不在名单里：runbook —— 它是英文 README 六次指向的唯一部署/接入/验证/排障流程，中文独有
# 等于英文读者无法部署。所以它必须是 runbook_en.md / runbook_zh.md 一对（现已成对）。
doc_pair_ok=1
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  base="${f##*/}"
  # 成对文件由 3 已经检查过
  [[ "$base" == *_en.md || "$base" == *_zh.md ]] && continue
  exempt=0
  for e in "${DOC_CHINESE_ONLY[@]}"; do [[ "$f" == "$e" ]] && { exempt=1; break; }; done
  [[ $exempt -eq 1 ]] && continue
  err "docs/ 下的 $f 既不是 _en/_zh 配对，也未列入 DOC_CHINESE_ONLY 豁免名单（新增中文独有文档须显式声明）"
  doc_pair_ok=0
done <<< "$(tracked_files 'docs/*.md')"
[[ "$doc_pair_ok" -eq 1 ]] && ok "docs/ 下每份文档要么成对、要么已显式豁免"

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
# 改名/删除任一文件都曾让这条守卫静默通过（硬编码路径 + 2>/dev/null || true —— 正是紧邻的
# 第 8 项注释里写着"被烧过"的那个构造）。改成枚举所有写 IAM 内联策略的脚本，并断言这些文件
# 确实存在：文件不见了要报错，而不是当作没有违规。
iam_policy_files="$(tracked_files 'scripts/lib/*.sh' 'scripts/*.sh' | xargs -r grep -lE 'put-role-policy|iam:PutRolePolicy' 2>/dev/null || true)"
if [[ -z "$iam_policy_files" ]]; then
  err "找不到任何写 IAM 内联策略的脚本——第 7 项（多区域 Resource 守卫）无从检查，视为失败"
fi
guard_hits="$(printf '%s\n' "$iam_policy_files" | tr '\n' '\0' \
  | xargs -0 -r grep -nE 'arn:aws:(logs|bedrock|bedrock-agentcore|secretsmanager|s3[a-z-]*):[a-z0-9-]*\$\{REGION\}:' 2>/dev/null || true)"
if [[ -n "$guard_hits" ]]; then
  err "全局共享角色策略 Resource 钉死了 \${REGION}（多区部署会互相覆盖，改用 '*'）："
  printf '      %s\n' "$guard_hits" >&2
else
  ok "全局共享角色策略 Resource 未钉死 \${REGION}（多区域安全）"
fi

# 8. 不得出现非 aws-samples 的 GitHub slug 作为默认值
#    这条曾经修好又被回退（deploy-all.sh 的 CODEGRAPH_SERVER_REPO），所以改由机器守卫。
#    文件清单改为枚举 git 跟踪的 .sh/.md，不再写死：原先硬编码到 `docs/runbook.md`，而该文件被
#    拆成 runbook_en/_zh 之后，`2>/dev/null` 让"文件不存在"完全无声，于是这条守卫**两份 runbook
#    都不再扫**却依旧报绿 —— 与它自己要防的"修好又回退"是同一种失效。
#    也去掉了 Interkarma 豁免：正则只匹配 source-truth|sample-code-qa-on-agentcore 两个仓名，
#    Interkarma/daggerfall-unity 永远不可能命中，那个豁免是死代码，留着会让人以为它是本项目产物的
#    合法来源。
slug_files="$(tracked_files '*.sh' '*.md' | grep -v '^scripts/check-invariants\.sh$' || true)"
slug_hits="$(printf '%s\n' "$slug_files" | tr '\n' '\0' \
  | xargs -0 -r grep -IoE '(github\.com/|githubusercontent\.com/|:-)[A-Za-z0-9_.-]+/(source-truth|sample-code-qa-on-agentcore)' 2>/dev/null \
  | grep -vE 'aws-samples/' || true)"
if [[ -n "$slug_hits" ]]; then
  err "出现非 aws-samples 的 GitHub slug 默认值（外部用户会拉不到）："
  printf '      %s\n' "$slug_hits" >&2
else
  ok "GitHub slug 默认值均为 aws-samples"
fi

# 9. 公开仓不得包含真实人名 / 客户环境 / 竞品名
#    规则：公开仓不得含客户环境描述、交付责任人/交付物表、真实人名或竞品名。
#
#    这一条曾经只 grep 五个写死的人名、且只扫 docs/ —— 结果它在一棵仍然含有整节「客户环境（会上已
#    澄清）」（仓库拓扑、团队规模、自建 Git、分支策略）和一张带「责任人 / 交付物」列的交付行动表的
#    树上报告全绿。写死名字只能拦住已经知道的那几个词，拦不住"下一份"内部文档；所以改成扫全部被
#    git 跟踪的文件，并且用**结构性信号**（客户环境、责任人、内网、会上……）而不是名字来判断。
#    仍然拦不住纯叙述性的段落 —— 那需要人工过一遍 docs/design/，这一点写在发布检查清单里。
PII_PATTERNS=(
  '客户环境' '客户侧' '客户内网' '贵司' '会上已' '会上澄清' '责任人' '交付物'
  'PoC 客户' '试点客户'   # 注：'内网地址' 曾在此，但它是通用安全术语（system.md 用它写
                        # 「绝不输出内网地址」这条规则），属于低信号高误报，已移除。
  '需求评审' '需客户'
  'WorkBuddy' 'GenSpark'
)
# 裸「客户」单独处理：它是最强的信号，但 '客户端'（client-side）是完全合法的技术词，
# 全仓都在用。所以先删掉 '客户端' 再匹配剩下的「客户」—— 这样 '客户调研' / '贴近客户特征'
# / '客户的' / '客户商业美术资源' / '客户接入时' 都会命中，而 '客户端引擎' 不会。
# 为什么加这条：前两版守卫都是固定词表，而真正漏掉的内容（一整节客户确认问卷、五处
# 「客户」归因、客户技术栈）没有一处用到词表里的词。词表拦得住已经知道的，拦不住下一份。
PII_BARE_CUSTOMER='客户'
pii_re="$(IFS='|'; printf '%s' "${PII_PATTERNS[*]}")"
# 这个守卫本身必然包含上面的字面量，扫自己等于永远失败，所以排除它。
# 只看被跟踪的文本文件；.local/ 等未跟踪内容不属于发布物。
#
# stderr 不再丢弃，退出码单独判定：第一版把 grep 的 stderr 送进 /dev/null，而模式里有一个
# CJK 字符区间在本机 grep 下是非法 ERE —— grep 直接报错退出，输出为空，于是守卫报告"干净"。
# 这跟它要拦的问题是同一类：一个因为自身损坏而恒绿的检查，比没有检查更糟。
pii_err="$(mktemp)"
# set -e / pipefail 会让失败的赋值直接终止脚本，于是下面那条"扫描本身失败"的诊断永远打不出来
# （模式非法时脚本以 xargs 的 123 退出，运维只看到一个裸退出码）。这里显式关掉再取退出码。
set +e
pii_hits="$(tracked_files | tr '\n' '\0' \
  | grep -zv '^scripts/check-invariants\.sh$' \
  | xargs -0 -r grep -IlE "$pii_re" 2>"$pii_err")"
pii_rc=$?
# 裸「客户」：逐文件把 '客户端' 抹掉后再找「客户」，避免 client-side 的误报。
pii_bare=""
while IFS= read -r _f; do
  [[ -z "$_f" || "$_f" == "scripts/check-invariants.sh" ]] && continue
  if sed 's/客户端//g' "$_f" 2>/dev/null | grep -q "$PII_BARE_CUSTOMER" 2>/dev/null; then
    pii_bare="${pii_bare}${_f}"$'\n'
  fi
done <<< "$(tracked_files)"
set -e
if [[ $pii_rc -gt 1 && -s "$pii_err" ]]; then
  err "PII 扫描本身失败（模式非法或文件不可读），不能据此判定干净："
  printf '      %s\n' "$(head -3 "$pii_err")" >&2
  rm -f "$pii_err"
elif [[ -n "$pii_hits" || -n "$pii_bare" ]]; then
  rm -f "$pii_err"
  err "文件中出现客户 / 交付责任人 / 真实人名 / 竞品名信号（公开仓不可含）："
  [[ -n "$pii_hits" ]] && printf '      %s\n' "$pii_hits" >&2
  [[ -n "$pii_bare" ]] && printf '      [裸「客户」，已排除「客户端」] %s\n' "$(printf '%s' "$pii_bare" | tr '\n' ' ')" >&2
  printf '      命中的模式集见 check-invariants.sh 第 9 项；若为误报请改写措辞，不要放宽模式。\n' >&2
else
  rm -f "$pii_err"
  # 措辞刻意保守：这是一个词表 + 一个裸词，拦不住纯叙述性的段落。前三轮每一次漏掉的都是
  # 叙述而不是关键词，所以这里只能声称"未命中已知信号"，不能声称"干净"。
  ok "未命中已知客户 / 交付 / 人名 / 竞品信号（词表检查，不替代人工审阅 docs/design 与 docs/agent/*spike*）"
fi

if [[ $fail -ne 0 ]]; then
  echo "check-invariants: FAILED" >&2
  exit 1
fi
echo "check-invariants: OK"
