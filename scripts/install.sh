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
# Code repos are git-only (R1) and live in .local/projects.json — never on the CLI. The single
# read-only git credential (R-cred-1) is shared across projects. Re-runs pre-fill region/spec
# from .local/deploy-config.
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
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/install.sh [--yes]

Interactive installer. Shows an arrow-key menu: init environment / add a project /
redeploy a project / remove a project. Code repos are git-only and live in
.local/projects.json; per-project Feishu + the shared git credential are created in
Secrets Manager. Re-runs pre-fill region/spec from .local/deploy-config.

  --yes   Accept all pre-filled/default answers without prompting (headless).
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

# ask_secret <var> <prompt> : read WITHOUT echo (credentials never on screen).
ask_secret() {
  local __var="$1" __prompt="$2" __reply
  read -rsp "$(printf '%s: ' "$__prompt")" __reply || true
  echo >&2
  printf -v "$__var" '%s' "$__reply"
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
        printf '\033[36m  ❯ %s\033[0m\n' "${__it[$i]}" >/dev/tty
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
# (Model is a per-project concern — set per project in .local/projects.json; the deploy uses the
# global default otherwise. So install.sh no longer prompts for it, and there's no MODEL menu.)
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
ask_region() {
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
  local REGION INSTANCE_TYPE ROOT_VOLUME_GB
  ask_region REGION
  pick_field INSTANCE_TYPE "索引主机机型 (ARM·决定 CPU/内存) / index host type" \
    "${DEPLOY_INSTANCE_TYPE:-t4g.large}" "EC2 机型 (ARM)" "${INSTANCE_OPTIONS[@]}"
  pick_field ROOT_VOLUME_GB "索引主机磁盘 / index host disk GiB" \
    "${DEPLOY_ROOT_VOLUME_GB:-30}" "磁盘大小 GiB" "${DISK_OPTIONS[@]}"
  while ! [[ "$ROOT_VOLUME_GB" =~ ^[0-9]+$ ]] || (( ROOT_VOLUME_GB < 8 )); do
    [[ "$ASSUME_YES" == true ]] && { say err "磁盘大小无效 / invalid disk size '$ROOT_VOLUME_GB'"; exit 1; }
    say warn "磁盘大小需为 ≥8 的整数 GiB / disk must be an integer GiB ≥ 8."
    ask ROOT_VOLUME_GB "磁盘大小 GiB" "30"
  done
  echo; say info "将只起共享底座（VPC/NAT/EC2/镜像），不挂任何项目。之后用「添加项目」上线机器人。"
  confirm "开始初始化环境？/ Initialize the base environment now?" || { say info "已取消"; exit 0; }
  say step "部署底座 / Deploying base host (several minutes)"
  exec "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" \
    --instance-type "$INSTANCE_TYPE" --root-volume-gb "$ROOT_VOLUME_GB" --skip-projects
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

  # repos: loop git URL + subdir + ref until blank.
  local REPOS_JSON="[]" RGIT RSUB RREF
  say info "逐个添加该项目的代码仓库（git 地址留空结束）/ add repos (blank git URL = done):"
  while true; do
    ask RGIT "  仓库 git 地址 / repo git URL (blank=done)" ""
    [[ -z "$RGIT" ]] && break
    ask RSUB "    on-host 子目录名 / subdir (^[a-z0-9-]+$)" ""
    [[ "$RSUB" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { say warn "subdir 非法，跳过该仓 / invalid subdir, skipped"; continue; }
    ask RREF "    分支/标签（留空=默认分支）/ ref (blank=default)" ""
    REPOS_JSON="$(RGIT="$RGIT" RSUB="$RSUB" RREF="$RREF" python3 -c '
import json,os,sys
a=json.loads(sys.argv[1]); a.append({"subdir":os.environ["RSUB"],"git":os.environ["RGIT"],"ref":os.environ["RREF"]}); print(json.dumps(a))' "$REPOS_JSON")"
  done
  [[ "$REPOS_JSON" != "[]" ]] || { say err "至少要一个仓库 / need at least one repo"; exit 1; }

  # port: suggest max-existing+1 (base 8080).
  local SUGGEST_PORT PORT
  SUGGEST_PORT="$(python3 -c 'import json,sys
try: ps=[p.get("port",0) for p in json.load(open(sys.argv[1])).get("projects",{}).values()]
except Exception: ps=[]
print((max(ps)+1) if ps else 8080)' "$PROJECTS_CFG")"
  ask PORT "bridge 端口（建议未用值）/ bridge port" "$SUGGEST_PORT"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
    say err "端口非法 / invalid port '$PORT' (1024-65535)"; exit 1
  fi
  if project_ids | while read -r p; do python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["projects"]; sys.exit(0 if d.get(sys.argv[2],{}).get("port")==int(sys.argv[3]) else 1)' "$PROJECTS_CFG" "$p" "$PORT" && echo "$p"; done | grep -q .; then
    say err "端口 $PORT 已被占用 / port already used by another project"; exit 1
  fi

  # Feishu app credentials → source-truth/feishu-<pid> (auto secret id).
  local FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_BOT_OPEN_ID SECRET_ID
  ask        FEISHU_APP_ID      "飞书 App ID" ""
  ask_secret FEISHU_APP_SECRET  "飞书 App Secret（输入不回显）/ (hidden)"
  ask        FEISHU_BOT_OPEN_ID "机器人 open_id（可留空）/ bot open_id (optional)" ""
  [[ -n "$FEISHU_APP_ID" && -n "$FEISHU_APP_SECRET" ]] || { say err "App ID 和 App Secret 必填"; exit 1; }
  SECRET_ID="source-truth/feishu-${PID}"
  local SJSON
  SJSON="$(_AID="$FEISHU_APP_ID" _AS="$FEISHU_APP_SECRET" _BO="${FEISHU_BOT_OPEN_ID:-}" python3 -c '
import os,json; print(json.dumps({"app_id":os.environ["_AID"],"app_secret":os.environ["_AS"],"bot_open_id":os.environ.get("_BO","")}))')"
  aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" \
      --description "source-truth Feishu app creds for project $PID" >/dev/null 2>&1 \
    || aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$SJSON" --region "$REGION" >/dev/null
  unset FEISHU_APP_SECRET SJSON
  say ok "飞书凭证已写入 / stored: $SECRET_ID"

  # first-run git read-only credential (R-cred-1, global, reused by later projects).
  if ! aws secretsmanager describe-secret --secret-id source-truth/git-credentials --region "$REGION" >/dev/null 2>&1; then
    local GIT_TOKEN
    ask_secret GIT_TOKEN "git 只读凭证（PAT/token，首次配置，后续项目复用；公开仓可留空）/ git read-only token (blank for public repos)"
    if [[ -n "$GIT_TOKEN" ]]; then
      aws secretsmanager create-secret --name source-truth/git-credentials --secret-string "$GIT_TOKEN" --region "$REGION" \
        --description "source-truth read-only git credential (R-cred-1)" >/dev/null \
        && say ok "git 凭证已写入 / stored: source-truth/git-credentials"
      unset GIT_TOKEN
    fi
  fi

  # Write the project entry into projects.json.
  PID="$PID" PORT="$PORT" SECRET_ID="$SECRET_ID" REPOS_JSON="$REPOS_JSON" python3 -c '
import json,os,sys
cfg=json.load(open(sys.argv[1]))
cfg.setdefault("projects",{})[os.environ["PID"]]={"port":int(os.environ["PORT"]),"feishuSecretId":os.environ["SECRET_ID"],"repos":json.loads(os.environ["REPOS_JSON"])}
json.dump(cfg,open(sys.argv[1],"w"),ensure_ascii=False,indent=2)' "$PROJECTS_CFG"
  say ok "已写入清单 / wrote projects.json: $PID (port=$PORT, secret=$SECRET_ID)"

  echo; confirm "现在部署项目 $PID？/ Deploy project $PID now?" || { say info "清单已保存，稍后可用「重新部署」/ saved; deploy later via redeploy"; exit 0; }
  # Ensure the shared base exists (idempotent no-op if already up), then deploy this project.
  say step "确保底座就绪 / ensuring shared base (idempotent)"
  "$SCRIPT_DIR/deploy-all.sh" --region "$REGION" --skip-projects \
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
  if [[ -n "$IID" ]]; then
    say info "停用主机上的 bridge/gateway/refresh 单元并清理代码副本 / cleaning host units + repo copies"
    # IMPORTANT ordering: read this project's subdirs from its manifest FIRST (into SUBS), then
    # disable each repo's refresh timer + build unit and drop its repo copy, and only AFTER that
    # rm the manifest. (Deleting the manifest before reading it would leave the refresh timers
    # git-pull-ing deleted repos forever and leak /data/repo copies.) The bridge is a CONCRETE
    # unit index-bridge-<projectId> (already disabled above) — NOT a per-subdir template.
    local RM_CMD="set +e
systemctl disable --now bot-gateway@${SEL}.service 2>/dev/null
systemctl disable --now index-bridge-${SEL}.service 2>/dev/null
SUBS=\$(python3 -c \"import json;print(' '.join(r['subdir'] for r in json.load(open('/etc/index-projects/${SEL}.json'))['repos']))\" 2>/dev/null)
for d in \$SUBS; do
  systemctl disable --now index-refresh-\$d.timer index-refresh-\$d.service index-build@\$d.service 2>/dev/null
  rm -f /etc/systemd/system/index-refresh-\$d.service /etc/systemd/system/index-refresh-\$d.timer
  rm -rf /data/repo/\$d
done
rm -f /etc/bot-gateway-${SEL}.env /etc/index-projects/${SEL}.json /etc/systemd/system/index-bridge-${SEL}.service
systemctl daemon-reload
echo removed-${SEL}"
    local PF; PF="$(mktemp /tmp/rm-ssm.XXXX.json)"
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
  if confirm "同时删除该项目飞书密钥 source-truth/feishu-$SEL？(默认否) / also delete its Feishu secret? (default no)"; then
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
