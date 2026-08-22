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
  err "无法枚举 git 跟踪文件（不是 git 仓库，或清单为空）——第 3b/7/8/9 项全部依赖它。若你是通过 GitHub「Download ZIP」或 release tarball 获得代码，请改用 git clone。 / Cannot enumerate git-tracked files (not a git repository, or an empty manifest) — checks 3b/7/8/9 all depend on it. If you obtained this tree via GitHub 'Download ZIP' or a release tarball, re-obtain it with git clone: these checks need the git manifest."
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

# 中文独有文档白名单：第 3 项（配对）与第 3b 项（枚举）共用，所以在两者之前声明。
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

# 3. 双语 _en/_zh 配对：docs/ 下每个 *_en.md 必须有 *_zh.md，反之亦然
#    必须递归。原先用的是 shell glob `docs/*_en.md`，**不跨目录**；而第 3b 项对任何以
#    `_en.md`/`_zh.md` 结尾的文件直接 continue，理由写的是"成对文件由第 3 项检查过"——这个信任
#    对子目录并不成立。于是 docs/agent/deploy_en.md 没有中文版可以完全通过，而
#    docs/agent/runbook_zh.md 没有英文版正是最初那次事故本身。
#    又一次"文件名属性即豁免"：这次豁免的是"带双语后缀且位于子目录"。
#    用 git pathspec 递归（git 的 `*` 跨 `/`），失败即硬失败（见上面的可枚举性断言）。
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # 已显式豁免为中文独有的文档不要求配对（名单在第 3b 项，声明在此之前使用）。
  _ex=0; for e in "${DOC_CHINESE_ONLY[@]}"; do [[ "$f" == "$e" ]] && { _ex=1; break; }; done
  [[ $_ex -eq 1 ]] && continue
  case "$f" in
    *_en.md) [[ -f "${f%_en.md}_zh.md" ]] || err "双语缺配对：$f 缺少对应的 _zh.md" ;;
    *_zh.md) [[ -f "${f%_zh.md}_en.md" ]] || err "双语缺配对：$f 缺少对应的 _en.md" ;;
  esac
done <<< "$(git ls-files 'docs/**_en.md' 'docs/**_zh.md' 2>/dev/null || true)"
[[ $fail -eq 0 ]] && ok "docs/ 双语 _en/_zh 配对完整（含子目录）"

# 3b. 每个 docs/ 下的 md 必须"要么成对，要么被显式豁免"。
#     旧写法只 glob docs/*_en.md ↔ docs/*_zh.md，于是**中性文件名等于自动豁免**：runbook.md
#     （整个部署 / 接入飞书 / 验证 / 运维 / 排障流程都在里面）就这样绕过了检查，structure_en.md
#     里甚至把这个豁免写成了"设计如此"。结果是：唯一能发现"英文读者无法部署"的机械检查，恰好
#     把最大的那份文档排除在外。
#     改成白名单模型：新增一份中文独有文档，必须显式写进 DOC_CHINESE_ONLY —— 那是一个在 review
#     里看得见的决定，而不是一次悄悄的默认。
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

# 9. 公开仓不得包含可识别到具体组织的内容
#    规则：不得含具体部署环境的描述、交付责任人/交付物表、真实人名或竞品对标。
#
#    历史教训（刻意不复述被清理的内容本身 —— 这个文件曾经就是唯一复述它的地方，而它按设计不扫
#    自己，于是成了唯一的盲区）：早期版本只 grep 少量写死的人名、且只扫 docs/，因此在一棵仍有
#    违规内容的树上报告全绿。写死名字只拦得住已经知道的词，拦不住下一份内部文档，所以现在扫全部
#    被 git 跟踪的文件、并按**结构性信号**判断。
#    它仍然拦不住纯叙述性的段落 —— 那需要人工过一遍 docs/design/ 与 docs/agent/*spike*，
#    这一点写在发布检查清单里，也写在下面的成功提示里。
PII_PATTERNS=(
  '客户环境' '客户侧' '客户内网' '贵司' '会上已' '会上澄清' '责任人' '交付物'
  'PoC 客户' '试点客户'   # 注：'内网地址' 曾在此，但它是通用安全术语（system.md 用它写
                        # 「绝不输出内网地址」这条规则），属于低信号高误报，已移除。
  '需求评审' '需客户'
  # 竞品对标的**类别**信号，而不是产品名：类别信号能拦住换个产品名重写的同类内容，
  # 而写死产品名只能拦住那两个。
  '对标' '竞品对比'
  # 那两个具体产品名仍然要拦，但按片段拼出来，避免这个文件本身携带字面量 ——
  # 它是唯一不被扫描的文件，不应该成为唯一复述这些名字的地方。请勿"顺手清理"成字面量。
  "$(printf 'Work%s' 'Buddy')" "$(printf 'Gen%s' 'Spark')"
)
# 逃生口。第 3b 项有 DOC_CHINESE_ONLY —— 一个在 review 里看得见、必须写理由的豁免机制；而第 9 项
# 此前**只有"改写措辞"一条路**。问题在于：'责任人' / '交付物' 是中文技术文档里的普通词（升级路径
# 表天然想要一列叫"责任人"，里程碑说明天然会写"交付物"），而裸「客户」在树里已出现于 17 个文件。
# 一旦出现第一个无法改写的合法命中（比如一个表格列头），唯一剩下的动作就是去动 PII_PATTERNS ——
# 也就是注释明令禁止的那件事。当年那个"只 grep 五个人名"的版本，很可能就是这么长出来的。
#
# 所以逃生口不是模式集的对立面，而正是**防止模式集被削弱**的东西：要豁免就写在这里，带路径、
# 带模式、带理由，让它在 review 里可见。散文能改措辞就改措辞；结构化内容改不动时走这里。
PII_EXEMPT=(
  # "路径|模式|理由" —— 三段都必填
)
_pii_exempt() {  # _pii_exempt <file> ; 0 = 已豁免
  local f="$1" e
  for e in "${PII_EXEMPT[@]}"; do
    [[ "$f" == "${e%%|*}" ]] && return 0
  done
  return 1
}
# 裸「客户」单独处理：它是最强的信号，但 '客户端'（client-side）是完全合法的技术词，
# 全仓都在用。所以先删掉 '客户端' 再匹配剩下的「客户」—— 这样 '客户调研' / '贴近客户特征'
# / '客户的' / '客户商业美术资源' / '客户接入时' 都会命中，而 '客户端引擎' 不会。
# 为什么加这条：前两版守卫都是固定词表，而真正漏掉的内容（一整节客户确认问卷、五处
# 「客户」归因、客户技术栈）没有一处用到词表里的词。词表拦得住已经知道的，拦不住下一份。
# 这个守卫本身必须排除在主扫描之外（它必然含有整套模式），但那意味着它是唯一不被检查的文件 ——
# 而它恰好曾经是唯一复述机密结构的文件。所以单独用一组**叙述性**标记检查它自己：这些词不在
# PII_PATTERNS 里，所以不会自匹配，但正是上一次真正泄漏出去的那几个词。
GUARD_NARRATIVE_MARKERS='仓库拓扑|团队规模|交付行动表|自建 Git|分支策略|会上已澄清'
# 排除这条检查自己的那几行：标记列表本身就含有这些词，不排除的话它永远自己命中
# （第一版就是这样 —— 又一次自指失效，和这个会话里反复出现的那一类完全同形）。
if grep -v 'GUARD_NARRATIVE_MARKERS' "$0" | grep -qE "$GUARD_NARRATIVE_MARKERS" 2>/dev/null; then
  err "check-invariants.sh 自身复述了机密内容的结构（命中：$GUARD_NARRATIVE_MARKERS）。"
  printf '      这个文件按设计不被第 9 项扫描，所以它是唯一的盲区 —— 只写规则与教训，不要复述被清理的内容。\n' >&2
fi

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
# 只扫**磁盘上确实存在**的被跟踪文件。git ls-files 会列出已删除但仍被跟踪的路径，于是任何
# "删掉一个文件"的提交都让 grep 报 "No such file or directory"、stderr 非空，被判成"扫描失败"
# 并指向"模式非法"——方向是 fail-closed 不漏，但这正是当初让人加上 2>/dev/null 的那种噪声，
# 而 2>/dev/null 就是上一次假绿的成因。把"文件不存在"和"模式非法"分开，噪声就没有了。
pii_scan_list="$(tracked_files | while IFS= read -r _f; do
  [[ -n "$_f" && -f "$_f" && "$_f" != "scripts/check-invariants.sh" ]] && printf '%s\n' "$_f"
done)"
pii_hits="$(printf '%s\n' "$pii_scan_list" | tr '\n' '\0' \
  | xargs -0 -r grep -IlE "$pii_re" 2>"$pii_err")"
pii_rc=$?
# 裸「客户」：逐文件把 '客户端' 抹掉后再找「客户」，避免 client-side 的误报。
pii_bare=""
while IFS= read -r _f; do
  [[ -z "$_f" ]] && continue
  if sed 's/客户端//g' "$_f" 2>/dev/null | grep -q "$PII_BARE_CUSTOMER" 2>/dev/null; then
    pii_bare="${pii_bare}${_f}"$'\n'
  fi
done <<< "$pii_scan_list"
# 应用豁免表（带理由的显式决定；见 PII_EXEMPT 上方的说明）。
_filter_exempt() { while IFS= read -r _f; do [[ -z "$_f" ]] && continue; _pii_exempt "$_f" || printf '%s\n' "$_f"; done; }
pii_hits="$(printf '%s\n' "$pii_hits" | _filter_exempt)"
pii_bare="$(printf '%s\n' "$pii_bare" | _filter_exempt)"
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
