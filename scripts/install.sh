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
DOMAIN_FLAG=()  # forwarded to deploy-all.sh: (--feishu-domain lark) for an international tenant
LOCALE_FLAG=()  # forwarded to deploy-all.sh: (--locale en) for English cards
GMF_FLAG=()     # forwarded to deploy-all.sh: (--glossary-max-files N) cost cap
REGION_PREFILL="" # pre-fills the region prompt instead of being silently dropped

# _imds_region / _is_index_host : is THIS machine the source-truth index host? (IMDSv2). Used to
# auto-enter single-host mode — see the LOCAL_MODE auto-detect below.
# The timeouts are load-bearing, not defensive dressing: this runs before the banner, so on a
# laptop behind a VPN, in a container, or on any network that BLACKHOLES link-local instead of
# refusing it, an untimed curl means the first thing a first-time user sees is a silent terminal
# with no output at all and no idea whether the installer is working.
_imds_get() {   # _imds_get <metadata-path>
  local tok
  tok="$(curl -fsS --connect-timeout 1 --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  curl -fsS --connect-timeout 1 --max-time 2 ${tok:+-H "X-aws-ec2-metadata-token: $tok"} "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
}
_imds_region() { _imds_get "placement/region"; }
_is_index_host() { [[ "$(_imds_get "iam/security-credentials/")" == *source-truth-index* ]]; }

# Arg parsing takes VALUES, so it cannot be a `for a in "$@"` loop. It used to be one, with no
# default case — which meant every flag this script does not itself implement was silently
# discarded. The costly one was --feishu-domain: README tells an international-Lark operator to
# pass it to the documented entry point (this script, via get.sh), the token was dropped on the
# floor, deploy-all defaulted to feishu AND PERSISTED it, and the operator got precisely the
# never-receives-events failure the README warned them about while having done as instructed.
# --region and --glossary-max-files were swallowed the same way, the latter meaning an uncapped
# (potentially hundreds of dollars) glossary build from a command that looked like it capped it.
# Flag-value validators. All four value-taking flags were added without any of this, and the gaps
# were not cosmetic:
#   * a flag as the LAST argument shifted twice and underflowed; under `set -euo pipefail` bash
#     exited 1 with NO OUTPUT AT ALL — on the documented `curl | bash -s --` entry point.
#   * `--region --local` took the next FLAG as its value, so the region became "--local" AND the
#     requested single-host topology was silently dropped.
#   * `--glossary-max-files abc` / `=` reached deploy-all unvalidated and resolved to 0 = UNCAPPED,
#     reintroducing the exact "a command that looked like it capped it" failure the flag was added
#     to prevent.
#   * the tenant was compared with a bare `== "lark"` here while every downstream layer case-folds,
#     so `--feishu-domain Lark` probed valid international credentials against open.feishu.cn and
#     told the operator their app was not in the Lark tenant — which is what they had got right.
_need_val() {  # _need_val <flag> <remaining-argc>
  [[ "$2" -ge 2 ]] || { printf 'flag %s needs a value\n' "$1" >&2; exit 2; }
}
_reject_flaglike() { case "$1" in -?*) printf 'flag %s: %s looks like another flag, not a value\n' "$2" "$1" >&2; exit 2 ;; esac; }
_norm_tenant() {
  _reject_flaglike "$1" --feishu-domain
  local v; v="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$v" in feishu|lark) printf '%s' "$v" ;;
    *) printf -- "--feishu-domain must be 'feishu' or 'lark', got '%s'\n" "$1" >&2; exit 2 ;; esac
}
_norm_locale() {
  _reject_flaglike "$1" --locale
  local v; v="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$v" in zh|en) printf '%s' "$v" ;;
    *) printf -- "--locale must be 'zh' or 'en', got '%s'\n" "$1" >&2; exit 2 ;; esac
}
_norm_region() {
  _reject_flaglike "$1" --region
  [[ "$1" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || { printf -- "--region '%s' is not an AWS region code\n" "$1" >&2; exit 2; }
  printf '%s' "$1"
}
_norm_count() {
  _reject_flaglike "$1" --glossary-max-files
  [[ "$1" =~ ^[0-9]+$ ]] || { printf -- "--glossary-max-files must be a non-negative integer (0 = uncapped), got '%s'\n" "$1" >&2; exit 2; }
  printf '%s' "$1"
}

while [[ $# -gt 0 ]]; do
  a="$1"
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    --local) LOCAL_MODE=true; LOCAL_FLAG=(--local) ;;
    --feishu-domain)       _need_val "$a" $#; DOMAIN_FLAG=(--feishu-domain "$(_norm_tenant "$2")"); shift ;;
    --feishu-domain=*)     DOMAIN_FLAG=(--feishu-domain "$(_norm_tenant "${a#*=}")") ;;
    --locale)              _need_val "$a" $#; LOCALE_FLAG=(--locale "$(_norm_locale "$2")"); shift ;;
    --locale=*)            LOCALE_FLAG=(--locale "$(_norm_locale "${a#*=}")") ;;
    --region)              _need_val "$a" $#; REGION_PREFILL="$(_norm_region "$2")"; shift ;;
    --region=*)            REGION_PREFILL="$(_norm_region "${a#*=}")" ;;
    --glossary-max-files)  _need_val "$a" $#; GMF_FLAG=(--glossary-max-files "$(_norm_count "$2")"); shift ;;
    --glossary-max-files=*) GMF_FLAG=(--glossary-max-files "$(_norm_count "${a#*=}")") ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/install.sh [--yes] [--local] [--feishu-domain <feishu|lark>]
                            [--locale <zh|en>] [--region <aws-region>]
                            [--glossary-max-files <n>]

Interactive installer. Shows an arrow-key menu: init environment / add a project /
redeploy a project / remove a project. Code repos (git or local source) live in
.local/projects.json; per-project Feishu + the shared git credential are created in
Secrets Manager. Re-runs pre-fill region/spec from .local/deploy-config.

  --yes     Accept all pre-filled/default answers without prompting (headless).
  --local   Single-host mode: deploy onto THIS EC2 (reuse its VPC/role), don't
            create a separate index host. Forwarded to deploy-all.sh. Auto-enabled
            when run ON the index host, so re-runs (add-project / redeploy) don't
            need it. Normally set for you by scripts/lib/prepare-local-host.sh /
            scripts/launch-host.sh.
  --feishu-domain <feishu|lark>
            Tenant domain. 'feishu' = 飞书 / China (open.feishu.cn), 'lark' =
            international Lark (open.larksuite.com). MUST match the console the
            app was created in — a mismatch authenticates and then never
            receives a single event. Forwarded to deploy-all.sh.
  --locale <zh|en>
            Card / message language. Defaults to 'en' when --feishu-domain is
            'lark', otherwise 'zh'. Forwarded to deploy-all.sh.
  --region <aws-region>
            Pre-fills the region prompt (still confirmable when interactive).
  --glossary-max-files <n>
            Cap the one-off glossary build. 0 = uncapped; on a very large repo
            an uncapped build can cost hundreds of dollars. Forwarded.
EOF
      exit 0 ;;
    *) printf 'unknown flag: %s (see --help)\n' "$a" >&2; exit 2 ;;
  esac
  shift
done

# Auto-enter single-host mode when running ON the index host itself, even without --local. Operators
# re-run install by hand there for add-project / redeploy; without this the base-deploy would take
# the two-machine path (create VPC/NAT, ReplaceRoute) under the instance role and fail — and it must
# reuse this box, not build a second network. A plain operator laptop isn't the index host, so the
# two-machine path is unaffected.
if [[ "$LOCAL_MODE" != true ]] && _is_index_host; then
  LOCAL_MODE=true; LOCAL_FLAG=(--local)
  say info "检测到本机即索引主机 —— 自动进入单机模式（--local）"
fi

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
    # Headless runs cannot answer a re-prompt. `ask` returns the (empty) default instantly under
    # --yes, which never matches a required pattern, so this loop spun forever printing the same
    # warning — a documented unattended path that hung instead of failing. Fail loudly instead.
    if [[ "$ASSUME_YES" == true ]]; then
      say err "--yes 模式下无法重新询问「${__prompt}」/ cannot re-prompt under --yes; supply this value non-interactively or run interactively"
      exit 1
    fi
    # A closed stdin (a pipe that ended) cannot answer either, and would spin identically.
    [[ -t 0 ]] || { say err "stdin 非交互且取值无效「${__prompt}」/ non-interactive stdin with no valid value"; exit 1; }
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
  "t4g.large     2 vCPU /  8 GiB   小中仓·默认 (small/medium repo, default)"
  "t4g.xlarge    4 vCPU / 16 GiB   中大仓 (medium/large repo)"
  "m7g.large     2 vCPU /  8 GiB   稳定性能 (steadier CPU)"
  "m7g.xlarge    4 vCPU / 16 GiB   大仓·稳定 (large repo, steadier CPU)"
  "m7g.2xlarge   8 vCPU / 32 GiB   超大仓/多仓 (very large, or several repos on one host)"
)
# Root gp3 volume: holds the repo copy + graph.db + staged tarball.
DISK_OPTIONS=(
  "30   GiB   小中仓·默认 (small/medium repo, default)"
  "50   GiB"
  "100  GiB   大仓 (large repo)"
  "200  GiB   超大仓/多仓 (very large, or several repos on one host)"
  "$MANUAL_SENTINEL"
)

# Term-glossary build file cap (per repo). cc scans this many files to build the
# 中文→英文符号 map; higher = more coverage but more $ (a full scan of a large repo
# can run into the hundreds of USD, one-time). 0 = no cap (whole repo).
GLOSSARY_OPTIONS=(
  "400    控成本·推荐首次部署 (bounded cost — recommended for a first deploy)"
  "1000   更广覆盖 (wider coverage, higher one-off cost)"
  "4000   大仓深覆盖 (deep coverage on a large repo, higher one-off cost)"
  "0      不限·全量·扫每个文件 (NO CAP — scans every file; measured ~\$372 on a 14k-file repo)"
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
# zip is OPTIONAL: only the monitoring DAU-lambda stage needs it (apply-dau-lambda.sh packages
# the function with `zip`). Its absence is non-fatal — the deploy + bot work fine, only the 日活
# widget stays empty — so WARN, don't block. (--local's prepare-local-host.sh installs it.)
have_cmd zip || say info "zip 未安装 / zip absent — fine, but the monitoring 日活 widget stays empty until you install zip (用你系统的包管理器 / your OS package manager) and re-run: ./scripts/apply-monitoring.sh --only dau"
# (No docker-daemon liveness check here: deploy-all.sh's preflight_docker runs the same
# `docker info` probe up front — before any billable resource — so this would be a duplicate.)
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

# ask_region <var> : the region menu is shared by every flow (pre-selects persisted). In single-host
# mode (LOCAL_MODE — set explicitly or auto-detected up top) region is NOT a choice: we deploy onto
# THIS EC2, whose region is fixed. Read it from IMDS; asking would just invite the wrong pick (e.g.
# a stale Tokyo default while the box is in us-east-1). Otherwise (operator laptop) show the menu.
ask_region() {
  # An explicit --region wins over everything, including the IMDS auto-detect: the operator named
  # a region on the command line, and silently deploying somewhere else is worse than being wrong
  # loudly. (Before, --region was swallowed entirely by the arg loop.)
  if [[ -n "$REGION_PREFILL" ]]; then
    printf -v "$1" '%s' "$REGION_PREFILL"
    say info "区域 / region: $REGION_PREFILL（来自 --region）"
    return
  fi
  if [[ "$LOCAL_MODE" == true ]]; then
    local imds_region; imds_region="$(_imds_region)"
    if [[ -n "$imds_region" ]]; then
      printf -v "$1" '%s' "$imds_region"
      say info "区域 / region: $imds_region（本机所在区域，自动检测）"
      return
    fi
    say warn "无法从实例元数据读取区域；回退到手动选择。"
  fi
  pick_field "$1" "AWS 区域 / region (↑/↓ 选择，回车确认)" \
    "${DEPLOY_REGION:-ap-northeast-1}" "AWS 区域代码 / region code" "${REGION_OPTIONS[@]}"
}

# project_ids : print existing projectIds from .local/projects.json, one per line (empty if none).
# FAIL-LOUD on a broken file: swallowing the parse error made remove/redeploy report the
# misleading "清单无项目 / no projects" instead of the real problem (hand-edited bad JSON).
project_ids() {
  [[ -f "$PROJECTS_CFG" ]] || return 0
  python3 -c 'import json,sys
try:
    print("\n".join(json.load(open(sys.argv[1])).get("projects",{})))
except Exception as e:
    sys.stderr.write(f"projects.json 解析失败 / failed to parse {sys.argv[1]}: {e}\n")
    sys.exit(1)' "$PROJECTS_CFG"
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
  # Glossary cap is a build-COST knob, so it is asked in both topologies. It used to be skipped
  # under --local on the reasoning that applies to machine specs (instance type, disk) — but that
  # reasoning does not transfer: nothing about a cost ceiling is machine-specific, and the advice
  # printed in its place ("re-run install without --local, or set GLOSSARY_MAX_FILES") was dead in
  # both halves — _is_index_host force-enables --local on the index host, and deploy-all.sh opens
  # by assigning GLOSSARY_MAX_FILES="" which clobbers any exported value. An uncapped build on a
  # large repo is a several-hundred-dollar one-off, so a silent default is the wrong call.
  if [[ ${#GMF_FLAG[@]} -gt 0 ]]; then
    GLOSSARY_MAX_FILES="${GMF_FLAG[1]}"
    say info "术语表构建文件上限 / glossary build cap: ${GLOSSARY_MAX_FILES}（来自 --glossary-max-files）"
  else
  # Pre-select 400, not 0. The option list is only half the decision — this argument is what the
  # cursor lands on, so leaving it at 0 kept "unbounded" as the Enter-key answer no matter how the
  # list was reordered. An operator who has already chosen a cap keeps their choice.
  pick_field GLOSSARY_MAX_FILES "术语表构建文件上限 (中文→代码符号；0=不限，可能数百美元) / glossary build cap (0 = uncapped, may cost hundreds of USD)" \
    "${DEPLOY_GLOSSARY_MAX_FILES:-400}" "文件数 (0=不限) / file cap (0 = uncapped)" "${GLOSSARY_OPTIONS[@]}"
  while ! [[ "$GLOSSARY_MAX_FILES" =~ ^[0-9]+$ ]]; do
    [[ "$ASSUME_YES" == true ]] && { say err "术语表上限无效 / invalid glossary cap '$GLOSSARY_MAX_FILES'"; exit 1; }
    say warn "需为非负整数 (0=不限) / must be a non-negative integer (0 = no cap)."
    ask GLOSSARY_MAX_FILES "文件数 (0=不限)" "0"
  done
  fi
  echo; say info "将只起共享底座（VPC/NAT/EC2/镜像），不挂任何项目。之后用「添加项目」上线机器人。"
  confirm "开始初始化环境？/ Initialize the base environment now?" || { say info "已取消"; exit 0; }
  say step "部署底座 / Deploying base host (several minutes)"
  exec "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" "${HW_FLAGS[@]}" \
    --glossary-max-files "$GLOSSARY_MAX_FILES" --skip-projects "${LOCAL_FLAG[@]}" \
    "${DOMAIN_FLAG[@]}" "${LOCALE_FLAG[@]}"
}

# ============================================================
# FLOW: 添加项目 / add a project (interactive → projects.json + secrets → deploy)
# ============================================================
flow_add_project() {
  echo; say step "添加项目 / add a project"
  local REGION; ask_region REGION
  mkdir -p "$ROOT/.local"
  [[ -f "$PROJECTS_CFG" ]] || echo '{"refreshIntervalSec":300,"projects":{}}' > "$PROJECTS_CFG"

  local PID EXISTING_PIDS
  ask PID "项目 ID（小写字母数字与连字符）/ projectId (^[a-z0-9-]+$)" ""
  [[ "$PID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say err "projectId 非法 / invalid projectId '$PID'"; exit 1; }
  # project_ids fails loud on a broken projects.json (its stderr has the reason) — abort,
  # don't fall through to "not exists" and then corrupt/overwrite the file further down.
  EXISTING_PIDS="$(project_ids)" || { say err "修复 .local/projects.json 后重试 / fix projects.json and retry"; exit 1; }
  if grep -qx "$PID" <<< "$EXISTING_PIDS"; then
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
    # The local-repo option is offered ONLY in single-host mode. In the default two-machine
    # topology the index host is launched into a PRIVATE subnet with no key pair and no public IP,
    # and push-local-repo.sh needs a real SSH host (it deliberately refuses --ssh-opts, so there is
    # no SSM ProxyCommand escape either). Offering it there produced the worst possible outcome:
    # activate_project succeeds without code present, the deploy prints "fully deployed", the
    # installer then prints a push command that CANNOT work, and the bot answers "not found"
    # forever while every health signal looks fine.
    if [[ "$LOCAL_MODE" == true ]]; then
      pick SRC_CHOICE 0 \
        "git    远程 git 仓（自动定时刷新）/ remote git repo (auto-refresh)" \
        "local  本地仓（rsync 直推 + 手动刷新）/ local repo (rsync push + manual refresh)"
      RSRC="${SRC_CHOICE%%[[:space:]]*}"
    else
      RSRC="git"
      say info "  仓库来源：git（默认拓扑的索引主机在私有子网、无密钥对、无公网 IP，无法 rsync 推送本地仓；如需本地仓请用 --local 单机拓扑）"
    fi
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
      say ok "    已加入本地仓 / local repo: $RSUB （装服务会先起好后端，之后本机跑 scripts/push-local-repo.sh 推代码即建图上线）"
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
  # 一次 python3 遍历判冲突（同上面 subdir 冲突检查的写法）。不要用 while+&& 管道：
  # 循环体末条命令对不匹配项目返回 1，会在 set -e + pipefail 下把整条管道判非零，
  # 让「已占用」误报成「空闲」——两个项目共用一个 bridge 端口，后启动的起不来。
  if ! python3 -c 'import json,sys
try: projects=json.load(open(sys.argv[1])).get("projects",{})
except Exception: projects={}
clash=[pid for pid,p in projects.items() if p.get("port")==int(sys.argv[2])]
if clash:
    sys.stderr.write("port used by: "+", ".join(clash)+"\n"); sys.exit(1)
' "$PROJECTS_CFG" "$PORT"; then
    say err "端口 $PORT 已被占用 / port already used by another project"; exit 1
  fi

  # Model for this project's runtime (stored in projects.json; empty = global default at deploy).
  local MODEL
  pick_field MODEL "回答模型 / answer model (↑/↓ 选择，回车确认)" \
    "global.anthropic.claude-opus-4-8" "Bedrock 模型 id / model id" "${MODEL_OPTIONS[@]}"

  # Feishu app credentials → source-truth/feishu-<pid> (auto secret id).
  # Validate at the prompt (re-ask the bad field only) so a typo'd App ID / secret
  # is caught here, not 10 minutes later when the bot silently fails to start.
  local FEISHU_APP_ID FEISHU_BOT_OPEN_ID SECRET_ID
  # `local +x` strips any inherited export attribute: bash keeps it when the name was already
  # exported in the caller's environment, which would hand the typed value to every child of
  # this function, including deploy-all.sh and the exec'd deploy_project.sh.
  local +x FEISHU_APP_SECRET
  # The tenant the app belongs to decides which console — and which API host — is correct.
  # Asked before the credentials because it selects the endpoint they are validated against.
  local FEISHU_DOMAIN_SEL="${DOMAIN_FLAG[1]:-${DEPLOY_FEISHU_DOMAIN:-feishu}}"
  if [[ ${#DOMAIN_FLAG[@]} -eq 0 ]]; then
    pick_field FEISHU_DOMAIN_SEL "飞书租户 / tenant (↑/↓ 选择，回车确认)" \
      "${DEPLOY_FEISHU_DOMAIN:-feishu}" "租户 / tenant" \
      "feishu:飞书 · 中国版 (open.feishu.cn)" "lark:Lark · 国际版 (open.larksuite.com)"
    DOMAIN_FLAG=(--feishu-domain "$FEISHU_DOMAIN_SEL")
  fi
  local FEISHU_API_HOST="https://open.feishu.cn"
  [[ "$FEISHU_DOMAIN_SEL" == "lark" ]] && FEISHU_API_HOST="https://open.larksuite.com"

  while true; do
    ask_valid FEISHU_APP_ID "飞书 App ID（cli_…）" '^cli_[A-Za-z0-9]+$' \
      "App ID 应形如 cli_xxxxxxxx / App ID must look like cli_..."
    while true; do
      ask_secret FEISHU_APP_SECRET "飞书 App Secret（输入以 * 回显）/ (echoed as *)"
      [[ -n "$FEISHU_APP_SECRET" ]] && break
      say warn "App Secret 必填 / App Secret is required"
      # ask_secret has no --yes branch and returns empty at EOF, so on a pipe this loop spun
      # forever. There is no non-interactive way to supply a secret here by design (it must not
      # come from argv, where it would land in the process list and shell history).
      if [[ "$ASSUME_YES" == true || ! -t 0 ]]; then
        say err "无法在非交互模式下读取 App Secret / cannot read App Secret non-interactively"
        say info "请交互运行安装器，或先手动创建密钥 source-truth/feishu-<projectId>（含 app_id / app_secret / bot_open_id）后再运行。"
        exit 1
      fi
    done
    # REAL validation, not just a shape check. The regex above only proves the App ID looks like
    # an App ID; the comment claiming a typo is "caught here, not 10 minutes later" was false
    # until this probe existed. tenant_access_token/internal needs NO scopes and NO published
    # version, so it is valid this early, costs one request, and distinguishes bad credentials
    # from a tenant mismatch — the two failures that otherwise surface as a gateway restart loop
    # in a log file on an EC2 instance the operator reaches through SSM.
    local PROBE_RC=0 PROBE_OUT
    PROBE_OUT="$(_H="$FEISHU_API_HOST" _AID="$FEISHU_APP_ID" _AS="$FEISHU_APP_SECRET" python3 - <<'PY' 2>&1
import json, os, sys, urllib.request, urllib.error
req = urllib.request.Request(
    os.environ["_H"] + "/open-apis/auth/v3/tenant_access_token/internal",
    data=json.dumps({"app_id": os.environ["_AID"], "app_secret": os.environ["_AS"]}).encode(),
    headers={"Content-Type": "application/json; charset=utf-8"})
try:
    body = json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
except urllib.error.HTTPError as e:
    try: body = json.loads(e.read().decode())
    except Exception: print("HTTP %s" % e.code); sys.exit(3)
except Exception as e:
    print("NETWORK %s" % type(e).__name__); sys.exit(4)
code = body.get("code")
if code == 0 and body.get("tenant_access_token"):
    print("OK"); sys.exit(0)
print("code=%s msg=%s" % (code, str(body.get("msg"))[:120])); sys.exit(1)
PY
)" || PROBE_RC=$?
    if [[ $PROBE_RC -eq 0 ]]; then
      say ok "飞书凭证已验证 / credentials verified against $FEISHU_API_HOST"
      break
    elif [[ $PROBE_RC -eq 4 ]]; then
      # Cannot reach Feishu at all — do not punish the operator for our network.
      say warn "无法连通 $FEISHU_API_HOST（$PROBE_OUT）——跳过凭证校验 / cannot reach Feishu, skipping validation"
      break
    else
      say err "凭证校验失败 / credentials rejected by $FEISHU_API_HOST: $PROBE_OUT"
      say info "请检查：App ID / Secret 是否抄错；以及该应用是否属于「${FEISHU_DOMAIN_SEL}」租户（中国版与国际版的应用互不相通）。"
      [[ "$ASSUME_YES" == true ]] && { say err "--yes 模式下无法重试 / cannot re-prompt under --yes"; exit 1; }
      FEISHU_APP_SECRET=""
    fi
  done
  # open_id is optional, but if given it must look like ou_… (a wrong value breaks the
  # group @-gate). Empty is allowed (FEISHU_BOT_OPEN_ID unset → 'any mention triggers').
  # The bot's own open_id gates group @-mentions. The runbook used to tell operators to "note it
  # from the bot page", but that page shows the APP identity, not an ou_-prefixed open_id — so the
  # realistic outcomes were a guess or a blank. Derive it from the API instead, using the token we
  # just proved works. Blank is still permitted, but the prompt now names what blank COSTS: the
  # gate degrades to "any mention triggers", so @-ing a colleague makes the bot answer unbidden.
  FEISHU_BOT_OPEN_ID=""
  local DERIVED_OPEN_ID
  DERIVED_OPEN_ID="$(_H="$FEISHU_API_HOST" _AID="$FEISHU_APP_ID" _AS="$FEISHU_APP_SECRET" python3 - <<'PY' 2>/dev/null || true
import json, os, urllib.request
h = os.environ["_H"]
def post(path, payload):
    req = urllib.request.Request(h + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    return json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
try:
    tok = post("/open-apis/auth/v3/tenant_access_token/internal",
               {"app_id": os.environ["_AID"], "app_secret": os.environ["_AS"]}).get("tenant_access_token")
    req = urllib.request.Request(h + "/open-apis/bot/v3/info",
                                 headers={"Authorization": "Bearer " + tok})
    info = json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
    oid = (info.get("bot") or {}).get("open_id") or ""
    if oid.startswith("ou_"):
        print(oid)
except Exception:
    pass
PY
)"
  if [[ -n "$DERIVED_OPEN_ID" ]]; then
    FEISHU_BOT_OPEN_ID="$DERIVED_OPEN_ID"
    say ok "机器人 open_id 自动获取 / bot open_id derived: $FEISHU_BOT_OPEN_ID"
  else
    say warn "无法自动获取机器人 open_id（通常是「机器人」能力未开启，或版本未发布）"
    ask_valid FEISHU_BOT_OPEN_ID "机器人 open_id（ou_…；留空则群里 @ 任何人都会触发机器人）/ blank = ANY @-mention triggers the bot" \
      '^ou_[A-Za-z0-9]+$' "open_id 应形如 ou_xxxxxxxx，或留空 / must look like ou_... or be blank" allow_empty
  fi
  SECRET_ID="source-truth/feishu-${PID}"
  local SJSON
  SJSON="$(_AID="$FEISHU_APP_ID" _AS="$FEISHU_APP_SECRET" _BO="${FEISHU_BOT_OPEN_ID:-}" python3 -c '
import os,json; print(json.dumps({"app_id":os.environ["_AID"],"app_secret":os.environ["_AS"],"bot_open_id":os.environ.get("_BO","")}))')"
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" \
      --description "source-truth Feishu app creds for project $PID" >/dev/null 2>&1 \
    || aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" >/dev/null
  FEISHU_APP_SECRET=""; unset SJSON
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
  # GLOSSARY COST GATE: when the base host doesn't exist yet, the deploy-all below auto-initializes
  # it — and the glossary build then runs with the DEFAULT cap (GLOSSARY_MAX_FILES=0 = whole repo).
  # On a large repo that one-time cc scan can cost hundreds of USD. Surface it and confirm once;
  # the "init environment" flow is where a cap can be chosen. (--local skips: init took the default
  # knowingly there; confirm() auto-accepts under --yes.)
  if [[ -z "${INDEX_SERVICE_INSTANCE:-}" && "$LOCAL_MODE" != true ]]; then
    say warn "底座尚未初始化，将自动创建 / the shared base does not exist yet and will be created."
    say warn "术语表将全量构建（GLOSSARY_MAX_FILES=0，扫全仓），大仓一次性成本可达数百美元。"
    say warn "COST WARNING: the glossary build is UNCAPPED (scans every file in the repo)."
    say warn "  This is a ONE-OFF model cost, measured at ~\$372 on a 14k-file repository."
    say warn "  To bound it: cancel now, run 'initialize environment' and pick a file cap"
    say warn "  (400 is the recommended first-deploy value), then come back and add the project."
    confirm "接受不限量的术语表构建（可能数百美元）并继续？/ proceed with an UNCAPPED glossary build (may cost hundreds of USD)?" \
      || { say info "已取消。清单已保存；先跑「初始化环境」设上限，再用「重新部署」/ cancelled — run init-env to set a cap, then redeploy"; exit 0; }
  fi
  # Ensure the shared base exists (idempotent no-op if already up), then deploy this project.
  say step "确保底座就绪 / ensuring shared base (idempotent)"
  "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" --skip-projects "${LOCAL_FLAG[@]}" \
    "${DOMAIN_FLAG[@]}" "${LOCALE_FLAG[@]}" \
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
  # Capture + check rc BEFORE splitting: `mapfile < <(project_ids)` would swallow a parse
  # failure into an empty list and mis-report it as "no projects".
  local _plist
  _plist="$(project_ids)" || { say err "修复 .local/projects.json 后重试 / fix projects.json and retry"; exit 1; }
  # bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
  local _line; PIDS=(); while IFS= read -r _line; do PIDS+=("$_line"); done \
    < <(printf '%s\n' "$_plist" | grep -v '^$' || true)
  [[ ${#PIDS[@]} -gt 0 ]] || { say err "清单无项目 / no projects in projects.json — use 'add a project' first"; exit 1; }
  local SEL; pick SEL 0 "${PIDS[@]}"
  # Forward the tenant/locale here too. deploy_project.sh already reads FEISHU_DOMAIN and
  # LOCALE from the environment; without this, `install.sh --feishu-domain lark` plus
  # "redeploy" was accepted and silently changed nothing — the same discarded-flag defect the
  # arg loop was rewritten to eliminate, still alive in one of the four flows.
  exec env ${DOMAIN_FLAG[1]:+FEISHU_DOMAIN="${DOMAIN_FLAG[1]}"} ${LOCALE_FLAG[1]:+LOCALE="${LOCALE_FLAG[1]}"} \
    bash "$SCRIPT_DIR/lib/deploy_project.sh" "$REGION" "$SEL"
}

# ============================================================
# FLOW: 删除项目 / remove a project (destructive; double-confirm; keep secrets by default)
# ============================================================
flow_remove_project() {
  echo; say step "删除项目 / remove a project"
  local REGION; ask_region REGION
  # Same fail-loud capture as flow_redeploy (a broken projects.json is NOT "no projects").
  local _plist
  _plist="$(project_ids)" || { say err "修复 .local/projects.json 后重试 / fix projects.json and retry"; exit 1; }
  # bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
  local _line; PIDS=(); while IFS= read -r _line; do PIDS+=("$_line"); done \
    < <(printf '%s\n' "$_plist" | grep -v '^$' || true)
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
  rm -f /data/repo/.\$d.reindex.lock 2>/dev/null   # per-subdir reindex flock lives at repo-root, not inside \$d
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
