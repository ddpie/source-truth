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
err() { printf '  ✗ %s\n' "$1" >&2; fail=1; }
ok()  { printf '  ✓ %s\n' "$1"; }

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
else err "缺少 $LOCK（应由 docker build + pip freeze 生成的全传递依赖锁）"; fi

# 4. Node 主版本钉死（非浮动 lts）
if [[ -f "$DOCKERFILE" ]]; then
  if grep -qE 'setup_lts\.x' "$DOCKERFILE"; then
    err "Node 用了浮动 setup_lts.x（应钉主版本 setup_<N>.x）"
  elif grep -qE 'setup_[0-9]+\.x' "$DOCKERFILE"; then
    ok "Node 主版本钉死（setup_<N>.x）"
  else err "未找到 Node 安装行（setup_<N>.x）"; fi

  # 5. claude-code npm EXACT-pin
  if grep -qE '@anthropic-ai/claude-code@[0-9]' "$DOCKERFILE"; then
    ok "@anthropic-ai/claude-code 已 EXACT-pin"
  else err "@anthropic-ai/claude-code 未钉版本（应 npm install -g @anthropic-ai/claude-code@<version>）"; fi
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

echo ""
if [[ "$fail" -eq 0 ]]; then echo "check-versions: PASS"; else echo "check-versions: FAIL" >&2; fi
exit "$fail"
