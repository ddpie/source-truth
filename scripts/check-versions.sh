#!/usr/bin/env bash
# check-versions.sh — 无网络版本钉死防漂移守卫（pre-commit / test.sh --lint 调用）。
# 校验 AGENTS.md「基础镜像 + 依赖 EXACT-pin」硬约束中可机检的部分：
#   - agent-container 基础镜像必须按 sha256 digest 钉死（非浮动 tag）；
#   - requirements.txt 每个非注释依赖必须 ==<version> 精确钉死；
#   - requirements.lock 存在，且 requirements.txt 的每个直接依赖都在 lock 里同版本出现
#     （防止改了 txt 却忘了重生成 lock → 构建装到与意图不符的版本）；
#   - Node 主版本钉死（setup_<N>.x，不是浮动 setup_lts.x）；
#   - @anthropic-ai/claude-code npm 包 EXACT-pin（@<version>）。
# 失败即非零退出，逐条打印问题。纯文本检查，无 docker / 无网络。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOCKERFILE="agent-container/Dockerfile"
REQ="agent-container/requirements.txt"
LOCK="agent-container/requirements.lock"

fail=0
err()  { printf '  ✗ %s\n' "$1" >&2; fail=1; }
ok()   { printf '  ✓ %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }  # advisory; does NOT set fail

echo "check-versions: $ROOT"

# 1. 基础镜像 digest 钉死
if [[ -f "$DOCKERFILE" ]]; then
  base="$(grep -E '^FROM ' "$DOCKERFILE" | head -1)"
  if [[ "$base" == *"@sha256:"* ]]; then ok "基础镜像按 sha256 digest 钉死"
  else err "基础镜像未按 digest 钉死（FROM 应含 @sha256:…）：$base"; fi
else err "缺少 $DOCKERFILE"; fi

# 2. requirements.txt 每个直接依赖 ==-钉死
# 先剥掉行内注释再判 ==，否则注释里出现的 == 会把未钉死依赖误判为已钉死
# （如 `requests  # see ==2.34.2` 或 `boto3>=1.43.31  # was ==…`）。与第 3 步
# lock 覆盖检查的归一化保持一致。
if [[ -f "$REQ" ]]; then
  unpinned="$(grep -vE '^\s*#' "$REQ" | sed -E 's/\s*#.*$//' | grep -vE '^\s*$' | grep -vE '==' || true)"
  if [[ -z "$unpinned" ]]; then ok "requirements.txt 全部 ==-钉死"
  else err "requirements.txt 有未钉死依赖：$(echo "$unpinned" | tr '\n' ' ')"; fi
else err "缺少 $REQ"; fi

# 3. requirements.lock 存在且覆盖 txt 的每个直接依赖（同名同版本）
if [[ -f "$LOCK" ]]; then
  ok "requirements.lock 存在"
  if [[ -f "$REQ" ]]; then
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      # dep 形如 name==ver（去掉行尾注释/空白；并剥离 pip extras [x]，
      # 因为 lock 里的 pip freeze 不含 extras：requirements 写 httpx[http2]==X，
      # lock 是 httpx==X，需归一化后再比对，否则误报）。
      pin="$(echo "$dep" | sed -E 's/\s*#.*$//; s/\s//g; s/\[[^]]*\]//')"
      [[ -z "$pin" ]] && continue
      if grep -qixF "$pin" "$LOCK"; then :
      else err "requirements.txt 的 '$pin' 未在 requirements.lock 中同版本出现（改了 txt 忘了重生成 lock？）"; fi
    done < <(grep -vE '^\s*#' "$REQ" | grep -E '==')
    [[ "$fail" -eq 0 ]] && ok "requirements.txt 直接依赖均与 lock 一致"
  fi
else err "缺少 ${LOCK}（应由 docker build + pip freeze 生成的全传递依赖锁）"; fi

# 4. Node 主版本钉死（非浮动 lts）
if [[ -f "$DOCKERFILE" ]]; then
  # 只看真正的安装行、且先剥掉注释：这条守卫曾经 grep 'setup_<N>.x'，而 Dockerfile 里唯一
  # 匹配它的是一行**注释**（解释 `curl … setup_24.x | bash -` 这个管道已被移除）。真正的钉版本
  # 在 apt 源那行 `node_24.x`。于是把 node_24.x 改成 node_lts.x 守卫照样报绿 —— 只要注释还在。
  # 这与第 5 项 claude-code 的注释「只看 npm install 行，不看注释」是同一个坑，那里防住了，这里没有。
  node_line="$(sed -E 's/#.*$//' "$DOCKERFILE" | grep -E 'deb\.nodesource\.com/node_[0-9a-z]+\.x' || true)"
  if [[ -z "$node_line" ]]; then
    err "未找到 Node 的 apt 源安装行（deb.nodesource.com/node_<N>.x）"
  elif printf '%s' "$node_line" | grep -qE 'node_lts\.x'; then
    err "Node 用了浮动 node_lts.x（应钉主版本 node_<N>.x）"
  elif printf '%s' "$node_line" | grep -qE 'node_[0-9]+\.x'; then
    ok "Node 主版本钉死（$(printf '%s' "$node_line" | grep -oE 'node_[0-9]+\.x' | head -1)）"
  else
    err "Node 安装行未钉主版本：$node_line"
  fi

  # 5. claude-code npm: EXACT-pin OR @latest (operator choice 2026-06-19 — track
  #    latest, trading reproducibility for fastest upstream fixes). A bare
  #    `claude-code` with NO @tag is still an error (ambiguous).
  #    只看 npm install 行，不看注释——注释里的 @latest 曾可能掩盖安装行漏写 tag。
  cc_install="$(grep -E 'npm install[^#]*@anthropic-ai/claude-code' "$DOCKERFILE" || true)"
  if [[ -z "$cc_install" ]]; then
    err "Dockerfile 未找到 @anthropic-ai/claude-code 的 npm install 行"
  elif grep -qE '@anthropic-ai/claude-code@[0-9]' <<< "$cc_install"; then
    ok "@anthropic-ai/claude-code 已 EXACT-pin"
  elif grep -qE '@anthropic-ai/claude-code@latest' <<< "$cc_install"; then
    warn "@anthropic-ai/claude-code 用 @latest（按运维选择跟最新；牺牲可复现，回归时改回 @<version>）"
  else err "@anthropic-ai/claude-code 未带 @tag（应 @<version> 或 @latest）"; fi
fi

# 6. index-service deps：requirements.txt 全 ==-钉死，且 bootstrap 从它装（而非手列
#    pip 清单——手列会漂移，曾漏装/错装：装了从不 import 的 standalone fastmcp、漏了 perf.py 之类）。
IDX_REQ="index-service/requirements.txt"
IDX_BOOT="index-service/bootstrap.sh"
if [[ -f "$IDX_REQ" ]]; then
  idx_unpinned="$(grep -vE '^\s*#' "$IDX_REQ" | sed -E 's/\s*#.*$//' | grep -vE '^\s*$' | grep -vE '==' || true)"
  if [[ -z "$idx_unpinned" ]]; then ok "index-service/requirements.txt 全部 ==-钉死"
  else err "index-service/requirements.txt 有未钉死依赖：$(echo "$idx_unpinned" | tr '\n' ' ')"; fi
else err "缺少 $IDX_REQ"; fi
if [[ -f "$IDX_BOOT" ]]; then
  if grep -qE 'pip3? install[^|]*-r ' "$IDX_BOOT"; then ok "bootstrap.sh 从 requirements.txt 装依赖（单一来源）"
  else err "bootstrap.sh 未用 'pip install -r requirements.txt'（手列 pip 清单会漂移，见 perf.py/fastmcp 教训）"; fi
fi

# 6b. index-service/requirements.lock 目前是一个**声明了自己不完整**的占位文件（只有四个直接
#     pin，传递闭包缺失，因为当时无法从一次可信构建中解析出来）。这种文件是个陷阱：名字叫 .lock，
#     下一个人很可能顺手把 bootstrap 指过去，于是索引主机只装四个包就上线。
#     所以：只要它还带着 INCOMPLETE 标记，就禁止任何安装路径引用它。
#     等它被真正生成（去掉标记）之后，这一条会自动失效，届时应把 bootstrap 切过去。
IDX_LOCK="index-service/requirements.lock"
if [[ -f "$IDX_LOCK" ]] && grep -q 'INCOMPLETE' "$IDX_LOCK"; then
  if [[ -f "$IDX_BOOT" ]] && grep -qE 'pip3? install[^|]*-r[^|]*requirements\.lock' "$IDX_BOOT"; then
    err "$IDX_LOCK 仍标记为 INCOMPLETE，但 bootstrap.sh 已从它安装 —— 索引主机会缺少传递依赖。先用一次可信构建生成完整 lock 并移除 INCOMPLETE 标记。"
  else
    ok "index-service/requirements.lock 标记为 INCOMPLETE 且未被安装路径引用（符合预期）"
  fi
fi

echo ""
if [[ "$fail" -eq 0 ]]; then echo "check-versions: PASS"; else echo "check-versions: FAIL" >&2; fi
exit "$fail"
