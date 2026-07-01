#!/usr/bin/env bash
# install.sh — interactive installer for source-truth (customer AWS account, multi-project).
#
# A friendly front-end over deploy-all.sh / deploy_project.sh. After a dependency + AWS-identity
# check it shows an arrow-key MENU of four flows:
#   • 初始化环境 / init environment only — provision the shared base host, no project
#       (deploy-all.sh --skip-projects). Lets you stand up AWS first, configure git later.
#   • 添加项目 / add a project — collect projectId + git repos + bridge port + a Feishu app,
#       auto-create its Secrets Manager secrets (feishu-<id>, and the global git credential on
#       first run), write the .local/projects.json entry, then deploy that project.
#   • 重新部署现有项目 / redeploy — pick a declared project and re-run deploy_project.sh.
#   • 删除项目 / remove a project — destructive, double-confirmed; tears down its units/runtime/
#       repo copies + removes it from projects.json (keeps secrets by default; never the global
#       git credential).
#
# Code repos live in .local/projects.json — never on the CLI. Each repo is either a git source
# (cloned + auto-pulled) or a local source (pushed via push-local-repo.sh); add-project asks which.
# The single read-only git credential (R-cred-1) is shared across git-source repos. Re-runs pre-fill
# region/spec from .local/deploy-config.
#
# Non-interactive: --yes accepts pre-filled/default answers; flows needing human-only input
# (first Feishu/git secret) still hard-stop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env-utils.sh"

CONFIG_FILE="$ROOT/.local/deploy-config"
ASSUME_YES=false
LOCAL_MODE=false
LOCAL_FLAG=()   # forwarded to deploy-all.sh: (--local) in single-host mode, else empty
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    --local) LOCAL_MODE=true; LOCAL_FLAG=(--local) ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/install.sh [--yes] [--local]

Interactive installer. Shows an arrow-key menu: init environment / add a project /
redeploy a project / remove a project. Code repos (git or local source) live in
.local/projects.json; per-project Feishu + the shared git credential are created in
Secrets Manager. Re-runs pre-fill region/spec from .local/deploy-config.

  --yes     Accept all pre-filled/default answers without prompting (headless).
  --local   Single-host mode: deploy onto THIS EC2 (reuse its VPC/role), don't
            create a separate index host. Forwarded to deploy-all.sh. Normally
            set for you by prepare-local-host.sh / launch-host.sh.
EOF
      exit 0 ;;
  esac
done

# ---- tiny prompt helpers -------------------------------------------------------
# ask <var> <prompt> <default> : read a value, showing the default in [brackets];
# empty input keeps the default. In --yes mode, takes the default with no prompt.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ "$ASSUME_YES" == true ]]; then
    printf -v "$__var" '%s' "$__default"; return
  fi
  if [[ -n "$__default" ]]; then
    read -rp "$(printf '%s [%s]: ' "$__prompt" "$__default")" __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    read -rp "$(printf '%s: ' "$__prompt")" __reply || true
    printf -v "$__var" '%s' "$__reply"
  fi
}

# ask_secret <var> <prompt> : read a secret, echoing one '*' per char (the real
# value never appears on screen, but the operator gets typed feedback + length).
# Handles backspace/DEL. Falls back to silent read where there's no TTY (CI).
ask_secret() {
  local __var="$1" __prompt="$2" __reply="" __ch
  printf '%s: ' "$__prompt" >&2
  if [[ ! -t 0 ]]; then           # no interactive stdin (CI / piped): silent read
    read -r __reply || true
    printf -v "$__var" '%s' "$__reply"; return
  fi
  # Read char-by-char; mask with '*'. IFS= + -N1 keeps spaces; -r keeps backslashes.
  while IFS= read -rsN1 __ch; do
    [[ -z "$__ch" || "$__ch" == $'\n' || "$__ch" == $'\r' ]] && break
    if [[ "$__ch" == $'\177' || "$__ch" == $'\b' ]]; then   # backspace / DEL
      if [[ -n "$__reply" ]]; then __reply="${__reply%?}"; printf '\b \b' >&2; fi
      continue
    fi
    __reply+="$__ch"; printf '*' >&2
  done
  printf '\n' >&2
  printf -v "$__var" '%s' "$__reply"
}

# ask_valid <var> <prompt> <regex> <errmsg> [allow_empty] : ask until the reply
# matches <regex> (or is empty when allow_empty=1). Keeps the value the operator
# already typed in scope — re-prompts only this field, not the whole flow.
ask_valid() {
  local __var="$1" __prompt="$2" __re="$3" __err="$4" __empty="${5:-}" __val
  while true; do
    ask __val "$__prompt" ""
    if [[ -z "$__val" && -n "$__empty" ]]; then printf -v "$__var" '%s' ""; return; fi
    if [[ "$__val" =~ $__re ]]; then printf -v "$__var" '%s' "$__val"; return; fi
    say warn "$__err"
  done
}

# confirm <prompt> : y/N. --yes mode auto-confirms.
confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local __reply
  read -rp "$(printf '%s [y/N]: ' "$1")" __reply || true
  [[ "$__reply" =~ ^[Yy] ]]
}

# Sentinel for the last menu entry: fall through to a free-text prompt for a value
# not in the list (region/model can be anything; the menu just covers common ones).
MANUAL_SENTINEL="↳ 手动输入其他 / enter manually"

# pick <var> <default_index> <item...> : arrow-key menu (mirrors the reference
# installer's picker). ↑/↓ move, Enter selects; sets <var> to the chosen LABEL line.
# Falls back to the default item with no UI when headless (--yes) or no controlling
# TTY, so CI never blocks on a key read.
pick() {
  local __var="$1" __def="${2:-0}"; shift 2
  local -a __it=("$@")
  local __n=${#__it[@]} __sel="$__def" __key __rest i
  if [[ "$ASSUME_YES" == true || ! -e /dev/tty || ! -t 1 ]]; then
    printf -v "$__var" '%s' "${__it[$__def]}"; return
  fi
  # Clamp via `if` (NOT `(( … )) && …`): under `set -e` a false (( )) as the last
  # command of a branch aborts the whole script — the exact trap documented in
  # deploy-all.sh's preflight_quota.
  if (( __sel < 0 || __sel >= __n )); then __sel=0; fi
  _pick_draw() {
    for ((i = 0; i < __n; i++)); do
      if (( i == __sel )); then
        # highlight via common.sh's bg-aware cyan (bright on dark bg, standard on light) so the
        # selected row stays readable on both themes; _C_CYAN is '' under NO_COLOR / non-TTY.
        printf '%s  ❯ %s%s\n' "$_C_CYAN" "${__it[$i]}" "$_C_RESET" >/dev/tty
      else
        printf '    %s\n'               "${__it[$i]}" >/dev/tty
      fi
    done
  }
  printf '\033[?25l' >/dev/tty            # hide cursor
  # Restore the cursor on Ctrl-C and bail with the conventional 130, so an aborted
  # install never leaves the terminal with a hidden cursor.
  trap 'printf "\033[?25h" >/dev/tty; exit 130' INT
  _pick_draw
  while IFS= read -rsn1 __key </dev/tty; do
    if [[ "$__key" == $'\x1b' ]]; then
      read -rsn2 __rest </dev/tty || true
      case "$__rest" in
        '[A') __sel=$(( (__sel - 1 + __n) % __n )) ;;   # assignment form always
        '[B') __sel=$(( (__sel + 1) % __n )) ;;          # returns 0 — set -e safe
        *) continue ;;
      esac
    elif [[ -z "$__key" || "$__key" == $'\n' ]]; then
      break
    else
      continue
    fi
    printf '\033[%dA' "$__n" >/dev/tty    # cursor back up to redraw in place
    _pick_draw
  done
  printf '\033[?25h' >/dev/tty            # show cursor
  trap - INT
  printf -v "$__var" '%s' "${__it[$__sel]}"
}

# index_of_token <token> <item...> : 0-based index of the first item whose leading
# whitespace-delimited token == <token>, else -1. Used to pre-select the persisted
# value when re-running (so an upgrade keeps the prior choice highlighted).
index_of_token() {
  local want="$1"; shift
  local i=0 it
  for it in "$@"; do
    if [[ "${it%%[[:space:]]*}" == "$want" ]]; then echo "$i"; return; fi
    i=$((i + 1))
  done
  echo -1
}

# pick_field <outvar> <header> <persisted> <manual-prompt> <item...>
# Show <header>, then an arrow-key menu whose LAST item is MANUAL_SENTINEL. Sets
# <outvar> to the chosen line's leading token (e.g. region code / instance type),
# or to free text if the manual entry is chosen. Honors the --yes "keep persisted"
# contract: headless with a persisted value takes it verbatim (even if off-menu).
pick_field() {
  local __out="$1" __header="$2" __persist="$3" __manual="$4"; shift 4
  local -a __items=("$@")
  if [[ "$ASSUME_YES" == true && -n "$__persist" ]]; then
    printf -v "$__out" '%s' "$__persist"; return
  fi
  echo "  $__header"
  local __def
  __def="$(index_of_token "$__persist" "${__items[@]}")"
  if (( __def < 0 )); then __def=0; fi
  local __chosen
  pick __chosen "$__def" "${__items[@]}"
  if [[ "$__chosen" == "$MANUAL_SENTINEL" ]]; then
    ask "$__out" "$__manual" "$__persist"
  else
    printf -v "$__out" '%s' "${__chosen%%[[:space:]]*}"
  fi
}

# --- menu option lists (label = leading token IS the value; trailing text is help) ---
REGION_OPTIONS=(
  "ap-northeast-1   Tokyo 东京"
  "ap-southeast-1   Singapore 新加坡"
  "us-east-1        Virginia 弗吉尼亚"
  "us-west-2        Oregon 俄勒冈"
  "$MANUAL_SENTINEL"
)
# Bedrock model per project (written to projects.json's `model`; deploy_project resolves it to the
# region's actual inference profile, so a region-agnostic `global.…` id is the right thing to store
# — see resolve_model_for_region). Leading token IS the value; trailing text is help.
MODEL_OPTIONS=(
  "global.anthropic.claude-opus-4-8     Opus 4.8 · 默认"
  "global.anthropic.claude-opus-4-6     Opus 4.6"
  "global.anthropic.claude-sonnet-4-6   Sonnet 4.6"
  "$MANUAL_SENTINEL"
)
# index-service host (ARM Graviton). codegraph indexing is memory-bound and scales
# with repo size; t4g = burstable/cheap, m7g = sustained memory-optimized for big repos.
INSTANCE_OPTIONS=(
  "t4g.large     2 vCPU /  8 GiB   小中仓·默认"
  "t4g.xlarge    4 vCPU / 16 GiB   中大仓"
  "m7g.large     2 vCPU /  8 GiB   稳定性能"
  "m7g.xlarge    4 vCPU / 16 GiB   大仓·稳定"
  "m7g.2xlarge   8 vCPU / 32 GiB   超大仓/多仓"
)
# Root gp3 volume: holds the repo copy + graph.db + staged tarball.
DISK_OPTIONS=(
  "30   GiB   小中仓·默认"
  "50   GiB"
  "100  GiB   大仓"
  "200  GiB   超大仓/多仓"
  "$MANUAL_SENTINEL"
)

# Term-glossary build file cap (per repo). cc scans this many files to build the
# 中文→英文符号 map; higher = more coverage but more $ (a full scan of a large repo
# can run into the hundreds of USD, one-time). 0 = no cap (whole repo).
GLOSSARY_OPTIONS=(
  "400    控成本·默认 (cap cost)"
  "1000   更广覆盖 (more coverage)"
  "4000   大仓深覆盖 (deep, larger \$)"
  "0      不限·全量 (no cap, highest \$)"
  "$MANUAL_SENTINEL"
)

echo
say step "source-truth installer"
echo "  把项目最新主分支的真实代码，变成飞书里能问的 AI 助手。"
echo "  This installer deploys the full backend + Feishu gateway into your AWS account."
echo

# ---- 1. dependency check -------------------------------------------------------
say step "1/5 检查依赖 / Checking dependencies"
DEPS_OK=true
for c in aws python3 docker git; do
  if have_cmd "$c"; then
    say ok "$c"
  else
    say err "$c 缺失 / missing"
    DEPS_OK=false
  fi
done
if [[ "$DEPS_OK" != true ]]; then
  say err "请先安装缺失的依赖再重试 / install the missing tools and re-run."
  say info "  aws CLI v2, python3, docker (ARM64-capable buildx), git"
  exit 1
fi
# docker EXISTS isn't enough — the daemon must be RUNNING, or the build phase (after
# VPC/NAT/EC2 are already created) fails with a docker.sock connect error. Catch it
# here so the operator isn't billed for half a deploy before hitting it. `docker info`
# is the standard daemon-liveness check; run_timeout guards a hung daemon.
# In --local prepare-local-host.sh just started docker + runs us under `sg docker`, and deploy-all's
# own preflight_docker re-checks right after — so this check is redundant there; skip it.
if [[ "$LOCAL_MODE" != true ]] && have_cmd docker && ! run_timeout 20 docker info >/dev/null 2>&1; then
  say err "Docker 已安装但守护进程未运行 / docker is installed but its daemon isn't running."
  say info "  启动 Docker Desktop（或 dockerd），等它就绪后重试。验证：docker info"
  say info "  start Docker Desktop (or dockerd), wait until ready, then re-run. Verify with: docker info"
  exit 1
fi
# gh is OPTIONAL — only needed to auto-download codegraph-server from a PRIVATE repo's Release (gh
# carries auth). In --local the index host fetches the binary itself (S3 → Release) and prepare has
# already run `gh auth login`, so this hint is just noise there — skip it. Otherwise warn, don't block.
if [[ "$LOCAL_MODE" != true ]]; then
  if have_cmd gh && gh auth status >/dev/null 2>&1; then
    say ok "gh (authenticated — can fetch codegraph-server from a private Release)"
  else
    say info "gh 未安装或未登录 / gh absent or not logged in — fine if the repo is public or"
    say info "  codegraph-server is already local. For a PRIVATE repo's auto-download, run"
    say info "  'gh auth login', or set CODEGRAPH_SERVER_BIN=/path/to/codegraph-server."
  fi
fi
# AWS identity (also proves credentials work before we collect anything).
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  say err "AWS 凭证无效 / AWS credentials not working — run 'aws configure' or set AWS_PROFILE."
  exit 1
fi
say ok "AWS account: $ACCOUNT"

# Pre-fill defaults from the last run, if any.
safe_source_env "$CONFIG_FILE"

PROJECTS_CFG="$ROOT/.local/projects.json"

# ask_region <var> : the region menu is shared by every flow (pre-selects persisted).
# On the SINGLE-HOST box, region is NOT a choice — we deploy onto THIS EC2, whose region is fixed;
# asking just invites the wrong pick (e.g. a stale Tokyo default while the box is in us-east-1).
# Auto-detect from IMDS whenever this machine IS the source-truth index host — i.e. --local was
# passed, OR IMDS answers AND this instance carries source-truth-index-profile (so a plain operator
# laptop, or an unrelated EC2, still gets the menu). This covers bare `install.sh` re-runs on the
# host (add-project / redeploy), not just the first --local run.
_imds_region() {
  local tok
  tok="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  curl -fsS ${tok:+-H "X-aws-ec2-metadata-token: $tok"} "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null || true
}
_is_index_host() {
  # true if this EC2's attached instance profile is source-truth-index-profile
  local tok prof
  tok="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  prof="$(curl -fsS ${tok:+-H "X-aws-ec2-metadata-token: $tok"} "http://169.254.169.254/latest/meta-data/iam/security-credentials/" 2>/dev/null || true)"
  [[ "$prof" == *source-truth-index* ]]
}
ask_region() {
  local imds_region=""
  if [[ "$LOCAL_MODE" == true ]] || _is_index_host; then
    imds_region="$(_imds_region)"
  fi
  if [[ -n "$imds_region" ]]; then
    printf -v "$1" '%s' "$imds_region"
    say info "区域 / region: $imds_region（本机所在区域，自动检测）"
    return
  fi
  [[ "$LOCAL_MODE" == true ]] && say warn "无法从实例元数据读取区域（--local）；回退到手动选择。"
  pick_field "$1" "AWS 区域 / region (↑/↓ 选择，回车确认)" \
    "${DEPLOY_REGION:-ap-northeast-1}" "AWS 区域代码 / region code" "${REGION_OPTIONS[@]}"
}

# project_ids : print existing projectIds from .local/projects.json, one per line (empty if none).
project_ids() {
  [[ -f "$PROJECTS_CFG" ]] || return 0
  python3 -c 'import json,sys
try: print("\n".join(json.load(open(sys.argv[1])).get("projects",{})))
except Exception: pass' "$PROJECTS_CFG"
}

# ============================================================
# FLOW: 初始化环境 / init environment only (shared base host, no project)
# ============================================================
flow_init_env() {
  echo; say step "初始化环境（不挂项目）/ init environment only"
  local REGION INSTANCE_TYPE ROOT_VOLUME_GB GLOSSARY_MAX_FILES
  local HW_FLAGS=()   # --instance-type/--root-volume-gb — only meaningful when WE create the host
  ask_region REGION
  if [[ "$LOCAL_MODE" == true ]]; then
    # --local deploys onto THIS existing EC2; its type/disk were fixed at launch (launch-host.sh),
    # and deploy-all --local reuses the box in place — asking would just mislead. Skip, show actual.
    say info "机型/磁盘 / type & disk: 沿用本机（$( (curl -fsS -H "X-aws-ec2-metadata-token: $(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null) || echo '本机机型' ) ）—— 由 launch-host 起机时决定，如需变更请换机"
  else
    pick_field INSTANCE_TYPE "索引主机机型 (ARM·决定 CPU/内存) / index host type" \
      "${DEPLOY_INSTANCE_TYPE:-t4g.large}" "EC2 机型 (ARM)" "${INSTANCE_OPTIONS[@]}"
    pick_field ROOT_VOLUME_GB "索引主机磁盘 / index host disk GiB" \
      "${DEPLOY_ROOT_VOLUME_GB:-30}" "磁盘大小 GiB" "${DISK_OPTIONS[@]}"
    while ! [[ "$ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] || (( ROOT_VOLUME_GB < 8 )); do
      [[ "$ASSUME_YES" == true ]] && { say err "磁盘大小无效 / invalid disk size '$ROOT_VOLUME_GB'"; exit 1; }
      say warn "磁盘大小需为 ≥8 的整数 GiB / disk must be an integer GiB ≥ 8."
      ask ROOT_VOLUME_GB "磁盘大小 GiB" "30"
    done
    HW_FLAGS=(--instance-type "$INSTANCE_TYPE" --root-volume-gb "$ROOT_VOLUME_GB")
  fi
  # Glossary cap is a build-cost knob (not machine-specific). In --local, don't make the operator
  # stop and choose on first run — take the safe default (400, cost-controlled) and just show it.
  # To change it later: re-run install without --local, or set GLOSSARY_MAX_FILES / edit the env.
  if [[ "$LOCAL_MODE" == true ]]; then
    GLOSSARY_MAX_FILES="${DEPLOY_GLOSSARY_MAX_FILES:-400}"
    say info "术语表构建文件上限 / glossary build cap: ${GLOSSARY_MAX_FILES}（默认，控成本；改需重设 GLOSSARY_MAX_FILES）"
  else
  pick_field GLOSSARY_MAX_FILES "术语表构建文件上限 (中文→代码符号·控成本) / glossary build cap" \
    "${DEPLOY_GLOSSARY_MAX_FILES:-400}" "文件数 (0=不限)" "${GLOSSARY_OPTIONS[@]}"
  while ! [[ "$GLOSSARY_MAX_FILES" =~ ^[0-9]+$ ]]; do
    [[ "$ASSUME_YES" == true ]] && { say err "术语表上限无效 / invalid glossary cap '$GLOSSARY_MAX_FILES'"; exit 1; }
    say warn "需为非负整数 (0=不限) / must be a non-negative integer (0 = no cap)."
    ask GLOSSARY_MAX_FILES "文件数 (0=不限)" "400"
  done
  fi
  echo; say info "将只起共享底座（VPC/NAT/EC2/镜像），不挂任何项目。之后用「添加项目」上线机器人。"
  confirm "开始初始化环境？/ Initialize the base environment now?" || { say info "已取消"; exit 0; }
  say step "部署底座 / Deploying base host (several minutes)"
  exec "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" "${HW_FLAGS[@]}" \
    --glossary-max-files "$GLOSSARY_MAX_FILES" --skip-projects "${LOCAL_FLAG[@]}"
}

# ============================================================
# FLOW: 添加项目 / add a project (interactive → projects.json + secrets → deploy)
# ============================================================
flow_add_project() {
  echo; say step "添加项目 / add a project"
  local REGION; ask_region REGION
  mkdir -p "$ROOT/.local"
  [[ -f "$PROJECTS_CFG" ]] || echo '{"refreshIntervalSec":300,"projects":{}}' > "$PROJECTS_CFG"

  local PID
  ask PID "项目 ID（小写字母数字与连字符）/ projectId (^[a-z0-9-]+$)" ""
  [[ "$PID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say err "projectId 非法 / invalid projectId '$PID'"; exit 1; }
  if project_ids | grep -qx "$PID"; then
    say err "项目 '$PID' 已存在 / already exists — use 'redeploy' to update it."; exit 1
  fi

  # repos: loop git URL + subdir + ref until blank. N counts repos ALREADY added, so the
  # prompt announces which repo you're entering ("第 1 个仓库" first, then 2, 3, …) — without
  # it a multi-repo project gives no signal of how many are in or which one you're on.
  local REPOS_JSON="[]" RGIT RSUB RREF RSRC SRC_CHOICE N=0
  say info "逐个添加该项目的代码仓库（仓库名留空结束）/ add repos (blank subdir = done):"
  while true; do
    ask RSUB "  第 $((N + 1)) 个仓库 · on-host 子目录名 / repo #$((N + 1)) subdir (^[a-z0-9-]+$, blank=done)" ""
    [[ -z "$RSUB" ]] && break
    [[ "$RSUB" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say warn "subdir 非法，跳过 / invalid subdir, skipped"; continue; }
    pick SRC_CHOICE 0 \
      "git    远程 git 仓（自动定时刷新）/ remote git repo (auto-refresh)" \
      "local  本地仓（rsync 直推 + 手动刷新）/ local repo (rsync push + manual refresh)"
    RSRC="${SRC_CHOICE%%[[:space:]]*}"
    if [[ "$RSRC" == "git" ]]; then
      ask RGIT "    git 地址 / repo git URL" ""
      [[ -n "$RGIT" ]] || { say warn "git 仓必须有地址，跳过 / git repo needs a URL, skipped"; continue; }
      ask RREF "    分支/标签（留空=默认分支）/ ref (blank=default)" ""
      REPOS_JSON="$(RGIT="$RGIT" RSUB="$RSUB" RREF="$RREF" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"source":"git","git":os.environ["RGIT"],"ref":os.environ["RREF"]}); print(json.dumps(a))' "$REPOS_JSON")"
      say ok "    已加入 git 仓 / git repo: $RSUB ← $RGIT${RREF:+ @$RREF}"
    else
      REPOS_JSON="$(RSUB="$RSUB" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"source":"local"}); print(json.dumps(a))' "$REPOS_JSON")"
      say ok "    已加入本地仓 / local repo: $RSUB （部署后用 scripts/push-local-repo.sh 推送代码）"
    fi
    N=$((N + 1))
  done
  [[ "$REPOS_JSON" != "[]" ]] || { say err "至少要一个仓库 / need at least one repo"; exit 1; }

  # subdir 是全局键（决定 /data/repo/<subdir>、graph.db、systemd 单元名）。两个项目用同名
  # subdir 会共享同一份 graph.db（违反单写者，索引会损坏），删一个项目还会误删另一个的副本。
  # 所以这里既查本项目内部重复，也查与已有项目的冲突，命中即 fail-loud。
  if ! REPOS_JSON="$REPOS_JSON" python3 -c '
import json, os, sys
new = [r["subdir"] for r in json.loads(os.environ["REPOS_JSON"])]
if len(new) != len(set(new)):
    sys.stderr.write("本项目内 subdir 重复 / duplicate subdir within this project\n"); sys.exit(1)
try:
    projects = json.load(open(sys.argv[1])).get("projects", {})
except Exception:
    projects = {}
used = {r["subdir"]: pid for pid, p in projects.items() for r in p.get("repos", [])}
clash = [(s, used[s]) for s in new if s in used]
if clash:
    sys.stderr.write("subdir 已被其他项目占用 / subdir already used by another project: "
                     + ", ".join(f"{s} (项目 {pid})" for s, pid in clash) + "\n"); sys.exit(1)
' "$PROJECTS_CFG"; then
    say err "subdir 冲突——换个不重名的子目录名 / subdir clash; pick unique subdir names"; exit 1
  fi

  # port: 在 8080-8099（安全组放行段）里挑第一个没被占用的；占满则报错（最多 20 个项目）。
  local SUGGEST_PORT PORT
  SUGGEST_PORT="$(python3 -c 'import json,sys
try: used={p.get("port") for p in json.load(open(sys.argv[1])).get("projects",{}).values()}
except Exception: used=set()
free=[p for p in range(8080,8100) if p not in used]
print(free[0] if free else "")' "$PROJECTS_CFG")"
  [[ -n "$SUGGEST_PORT" ]] || { say err "8080-8099 端口已占满（最多 20 个项目）/ no free port in 8080-8099 (max 20 projects)"; exit 1; }
  ask PORT "bridge 端口（建议未用值）/ bridge port" "$SUGGEST_PORT"
  # 必须落在安全组放行的 8080-8099 内——否则 runtime 连不上 bridge，会静默退化成「无证据」回答。
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 8080 || PORT > 8099 )); then
    say err "端口必须在 8080-8099（安全组只放行这一段）/ port must be 8080-8099 (only this range is open in the SG); got '$PORT'"; exit 1
  fi
  if project_ids | while read -r p; do python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["projects"]; sys.exit(0 if d.get(sys.argv[2],{}).get("port")==int(sys.argv[3]) else 1)' "$PROJECTS_CFG" "$p" "$PORT" && echo "$p"; done | grep -q .; then
    say err "端口 $PORT 已被占用 / port already used by another project"; exit 1
  fi

  # Model for this project's runtime (stored in projects.json; empty = global default at deploy).
  local MODEL
  pick_field MODEL "回答模型 / answer model (↑/↓ 选择，回车确认)" \
    "global.anthropic.claude-opus-4-8" "Bedrock 模型 id / model id" "${MODEL_OPTIONS[@]}"

  # Feishu app credentials → source-truth/feishu-<pid> (auto secret id).
  # Validate at the prompt (re-ask the bad field only) so a typo'd App ID / secret
  # is caught here, not 10 minutes later when the bot silently fails to start.
  local FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_BOT_OPEN_ID SECRET_ID
  ask_valid FEISHU_APP_ID "飞书 App ID（cli_…）" '^cli_[A-Za-z0-9]+$' \
    "App ID 应形如 cli_xxxxxxxx / App ID must look like cli_..."
  while true; do
    ask_secret FEISHU_APP_SECRET "飞书 App Secret（输入以 * 回显）/ (echoed as *)"
    [[ -n "$FEISHU_APP_SECRET" ]] && break
    say warn "App Secret 必填 / App Secret is required"
  done
  # open_id is optional, but if given it must look like ou_… (a wrong value breaks the
  # group @-gate). Empty is allowed (FEISHU_BOT_OPEN_ID unset → 'any mention triggers').
  ask_valid FEISHU_BOT_OPEN_ID "机器人 open_id（ou_…，可留空）/ bot open_id (optional)" \
    '^ou_[A-Za-z0-9]+$' "open_id 应形如 ou_xxxxxxxx，或留空 / must look like ou_... or be blank" allow_empty
  SECRET_ID="source-truth/feishu-${PID}"
  local SJSON
  SJSON="$(_AID="$FEISHU_APP_ID" _AS="$FEISHU_APP_SECRET" _BO="${FEISHU_BOT_OPEN_ID:-}" python3 -c '
import os,json; print(json.dumps({"app_id":os.environ["_AID"],"app_secret":os.environ["_AS"],"bot_open_id":os.environ.get("_BO","")}))')"
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" \
      --description "source-truth Feishu app creds for project $PID" >/dev/null 2>&1 \
    || aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" >/dev/null
  unset FEISHU_APP_SECRET SJSON
  say ok "飞书凭证已写入 / stored: $SECRET_ID"

  # git read-only credential (R-cred-1, global, reused by later projects).
  # EARLY VALIDATION: a private https repo with no credential fails 10 minutes later, host-side,
  # with an opaque "could not read Username for 'https://github.com'". Instead, probe each https
  # repo for ANONYMOUS access right here (git ls-remote, prompts disabled): a public repo answers
  # instantly, a private one fails — telling us a token is needed BEFORE we write the manifest and
  # kick off the deploy. ssh remotes (git@…) use host keys, not this token, so they're skipped.
  local HAVE_CRED=false
  if aws secretsmanager describe-secret --secret-id source-truth/git-credentials --region "$REGION" >/dev/null 2>&1; then
    HAVE_CRED=true
  fi
  if [[ "$HAVE_CRED" == false ]] && have_cmd git; then
    local NEED_AUTH=false RURL
    while IFS= read -r RURL; do
      [[ -n "$RURL" ]] || continue
      is_https_git_url "$RURL" || continue
      # Anonymous probe: public repo → rc 0; private/needs-auth (or unreachable) → non-zero
      # (GIT_TERMINAL_PROMPT=0 + `-c credential.helper=` so neither git's own prompt nor a global
      # credential helper — e.g. macOS osxkeychain / Git Credential Manager — can pop a GUI and
      # hang; the probe stays purely anonymous). 15s wall-clock cap (run_timeout). A non-zero here
      # could also be a transient network/DNS failure, not truly private — the wording stays soft
      # and the remedy (asking for a token) is harmless for a public repo (the token goes unused).
      if ! GIT_TERMINAL_PROMPT=0 run_timeout 15 git -c credential.helper= ls-remote "$RURL" >/dev/null 2>&1; then
        say warn "  无法匿名访问（可能是私有仓，或网络不通）/ no anonymous access (private repo, or network issue): $RURL"
        NEED_AUTH=true
      fi
    done < <(printf '%s' "$REPOS_JSON" | python3 -c 'import json,sys
for r in json.load(sys.stdin): print(r.get("git",""))' 2>/dev/null)

    if [[ "$NEED_AUTH" == true ]]; then
      say warn "上面的仓库需要只读 git 令牌，否则部署会在克隆阶段失败 / repos above need a read-only git token, or deploy fails at clone"
      local GIT_TOKEN
      while true; do
        ask_secret GIT_TOKEN "git 只读凭证（PAT/token，后续项目复用）/ git read-only token"
        [[ -n "$GIT_TOKEN" ]] && break
        say warn "检测到私有仓，令牌必填（公开仓才能留空）/ private repo detected — token required (only public repos may be blank)"
      done
      aws secretsmanager create-secret --name source-truth/git-credentials --secret-string "$GIT_TOKEN" --region "$REGION" \
        --description "source-truth read-only git credential (R-cred-1)" >/dev/null \
        && { say ok "git 凭证已写入 / stored: source-truth/git-credentials"; HAVE_CRED=true; }
      unset GIT_TOKEN
    else
      say ok "所有仓库可匿名克隆，无需 git 令牌 / all repos clone anonymously — no git token needed"
    fi
  fi

  # Write the project entry into projects.json. `model` is recorded so the choice persists
  # (deploy_project resolves it per region); a redeploy without re-running install keeps it.
  PID="$PID" PORT="$PORT" SECRET_ID="$SECRET_ID" REPOS_JSON="$REPOS_JSON" MODEL="$MODEL" python3 -c '
import json,os,sys
cfg=json.load(open(sys.argv[1]))
entry={"port":int(os.environ["PORT"]),"feishuSecretId":os.environ["SECRET_ID"],"repos":json.loads(os.environ["REPOS_JSON"])}
if os.environ.get("MODEL"): entry["model"]=os.environ["MODEL"]
cfg.setdefault("projects",{})[os.environ["PID"]]=entry
json.dump(cfg,open(sys.argv[1],"w"),ensure_ascii=False,indent=2)' "$PROJECTS_CFG"
  say ok "已写入清单 / wrote projects.json: $PID (port=$PORT, secret=$SECRET_ID, model=${MODEL:-默认/default})"

  echo; confirm "现在部署项目 ${PID}？/ Deploy project $PID now?" || { say info "清单已保存，稍后可用「重新部署」/ saved; deploy later via redeploy"; exit 0; }
  # Ensure the shared base exists (idempotent no-op if already up), then deploy this project.
  say step "确保底座就绪 / ensuring shared base (idempotent)"
  "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" --skip-projects "${LOCAL_FLAG[@]}" \
    || { say err "底座部署失败 / base deploy failed — fix and re-run"; exit 1; }
  say step "部署项目 / deploying project $PID"
  exec bash "$SCRIPT_DIR/lib/deploy_project.sh" "$REGION" "$PID"
}

# ============================================================
# FLOW: 重新部署现有项目 / redeploy an existing project
# ============================================================
flow_redeploy() {
  echo; say step "重新部署现有项目 / redeploy an existing project"
  local REGION; ask_region REGION
  mapfile -t PIDS < <(project_ids)
  [[ ${#PIDS[@]} -gt 0 ]] || { say err "清单无项目 / no projects in projects.json — use 'add a project' first"; exit 1; }
  local SEL; pick SEL 0 "${PIDS[@]}"
  exec bash "$SCRIPT_DIR/lib/deploy_project.sh" "$REGION" "$SEL"
}

# ============================================================
# FLOW: 删除项目 / remove a project (destructive; double-confirm; keep secrets by default)
# ============================================================
flow_remove_project() {
  echo; say step "删除项目 / remove a project"
  local REGION; ask_region REGION
  mapfile -t PIDS < <(project_ids)
  [[ ${#PIDS[@]} -gt 0 ]] || { say err "清单无项目 / no projects to remove"; exit 1; }
  local SEL; pick SEL 0 "${PIDS[@]}"
  say warn "删除项目 '$SEL' 是破坏性操作：停 bridge@/gateway@、删 runtime、删其代码副本、从清单移除。"
  local CONFIRM
  ask CONFIRM "请输入项目 ID 以确认 / type the projectId to confirm" ""
  [[ "$CONFIRM" == "$SEL" ]] || { say info "未匹配，已取消 / cancelled"; exit 0; }
  safe_source_env "$CONFIG_FILE"
  local IID="${INDEX_SERVICE_INSTANCE:-}"
  # Stop + disable this project's host units and drop its repo copies (best-effort, via SSM).
  # Fallback subdir list from THIS host's view is the manifest; but if the manifest is already
  # gone (a half-finished prior removal, or it was never written), the host-side `SUBS` query
  # returns empty and the whole repo/unit cleanup loop silently no-ops — leaking /data/repo copies
  # and zombie refresh units. So compute the subdirs from the CLIENT-side projects.json too and
  # pass them as a fallback; the host uses its manifest when present, else this list.
  local FALLBACK_SUBS
  FALLBACK_SUBS="$(SEL="$SEL" python3 -c 'import json,os,sys
try:
    cfg=json.load(open(sys.argv[1]))
    p=cfg.get("projects",{}).get(os.environ["SEL"],{})
    print(" ".join(r.get("subdir","") for r in p.get("repos",[]) if r.get("subdir")))
except Exception:
    pass' "$PROJECTS_CFG" 2>/dev/null || true)"
  if [[ -n "$IID" ]]; then
    say info "停用主机上的 bridge/gateway/refresh 单元并清理代码副本 / cleaning host units + repo copies"
    # IMPORTANT ordering: read this project's subdirs from its manifest FIRST (into SUBS), then
    # disable each repo's refresh timer + build unit and drop its repo copy, and only AFTER that
    # rm the manifest. (Deleting the manifest before reading it would leave the refresh timers
    # git-pull-ing deleted repos forever and leak /data/repo copies.) The bridge is a CONCRETE
    # unit index-bridge-<projectId> (already disabled above) — NOT a per-subdir template.
    # SUBS falls back to the client-supplied list when the manifest is missing (see above).
    # Every disable is followed by reset-failed: a unit left in `failed` state is NOT removed
    # from `systemctl --all` by disable+rm+daemon-reload alone — it lingers as a not-found/failed
    # zombie until reset-failed clears it. Repo cleanup also drops the sibling
    # /data/repo/<subdir>.bridge.lock (http_bridge's singleton lock lives NEXT to the repo dir,
    # not inside it) and the per-project glossary dir /data/glossary/<projectId> (the slices +
    # build lock), which the old loop never touched → leaked glossary copies on every removal.
    local RM_CMD="set +e
systemctl disable --now bot-gateway@${SEL}.service index-bridge-${SEL}.service 2>/dev/null
systemctl reset-failed bot-gateway@${SEL}.service index-bridge-${SEL}.service 2>/dev/null
SUBS=\$(python3 -c \"import json;print(' '.join(r['subdir'] for r in json.load(open('/etc/index-projects/${SEL}.json'))['repos']))\" 2>/dev/null)
[ -z \"\$SUBS\" ] && SUBS='${FALLBACK_SUBS}'
for d in \$SUBS; do
  systemctl disable --now index-refresh-\$d.timer index-refresh-\$d.service index-build@\$d.service 2>/dev/null
  systemctl reset-failed index-refresh-\$d.timer index-refresh-\$d.service index-build@\$d.service 2>/dev/null
  rm -f /etc/systemd/system/index-refresh-\$d.service /etc/systemd/system/index-refresh-\$d.timer
  rm -rf /data/repo/\$d /data/repo/\$d.incoming /data/repo/\$d.bridge.lock
done
rm -rf /data/glossary/${SEL}
rm -f /etc/bot-gateway-${SEL}.env /etc/index-projects/${SEL}.json /etc/systemd/system/index-bridge-${SEL}.service
systemctl daemon-reload
echo removed-${SEL}"
    local PF; PF="$(mktemp /tmp/rm-ssm.XXXXXX)"  # X's at end (BSD/macOS-safe); .json cosmetic (passed as file://)
    printf '%s' "$RM_CMD" | python3 -c 'import sys,json; print(json.dumps({"commands": sys.stdin.read().split("\n")}))' > "$PF"
    aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
      --parameters "file://$PF" >/dev/null 2>&1 || say warn "  SSM cleanup command failed (host units may remain; clean manually)"
    rm -f "$PF"
  fi
  # Delete this project's runtime (best-effort).
  local RT_VAR="RUNTIME_ARN_${SEL//-/_}" RT
  RT="$(safe_source_env "$CONFIG_FILE"; echo "${!RT_VAR:-}")" 2>/dev/null || RT=""
  if [[ -n "$RT" ]] && [[ -f "$SCRIPT_DIR/lib/delete_runtime.py" ]]; then
    python3 "$SCRIPT_DIR/lib/delete_runtime.py" --region "$REGION" --arn "$RT" 2>/dev/null \
      && say ok "runtime 已删除 / deleted: $RT" || say warn "  runtime 删除失败，可手动删 / delete manually: $RT"
  fi
  # Remove from projects.json + clear the per-project config key.
  SEL="$SEL" python3 -c 'import json,os,sys
cfg=json.load(open(sys.argv[1])); cfg.get("projects",{}).pop(os.environ["SEL"],None)
json.dump(cfg,open(sys.argv[1],"w"),ensure_ascii=False,indent=2)' "$PROJECTS_CFG"
  update_env "$CONFIG_FILE" "RUNTIME_ARN_${SEL//-/_}" ""
  say ok "项目 '$SEL' 已从清单移除 / removed from projects.json"
  # Feishu secret: keep by default; offer to delete. git credential is GLOBAL — never touched.
  if confirm "同时删除该项目飞书密钥 source-truth/feishu-${SEL}？(默认否) / also delete its Feishu secret? (default no)"; then
    aws secretsmanager delete-secret --secret-id "source-truth/feishu-$SEL" --region "$REGION" \
      --force-delete-without-recovery >/dev/null 2>&1 \
      && say ok "飞书密钥已删除 / Feishu secret deleted" || say warn "  飞书密钥删除失败 / delete failed"
  fi
  say ok "完成 / done (git 全局凭证保留；其余项目不受影响)"
}

# ---- main menu (arrow-key) -----------------------------------------------------
echo
MENU_OPTIONS=(
  "初始化环境（不挂项目）/ init environment only"
  "添加项目      / add a project"
  "重新部署现有项目 / redeploy an existing project"
  "删除项目      / remove a project"
)
# Default the cursor to "add a project" once a base host exists, else "init environment".
MENU_DEFAULT=0
[[ -n "${INDEX_SERVICE_INSTANCE:-}" ]] && MENU_DEFAULT=1
say step "选择操作 / choose an action (↑/↓，回车)"
pick MENU_CHOICE "$MENU_DEFAULT" "${MENU_OPTIONS[@]}"
case "$MENU_CHOICE" in
  初始化环境*)   flow_init_env ;;
  添加项目*)     flow_add_project ;;
  重新部署*)     flow_redeploy ;;
  删除项目*)     flow_remove_project ;;
  *) say err "未知选项 / unknown choice"; exit 2 ;;
esac
