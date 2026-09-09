#!/usr/bin/env bash
# deploy-all.sh — one-click, idempotent, region/account-agnostic deploy of the
# full source-truth backend: S3 artifacts → VPC/index-service EC2 →
# AgentCore runtime (VPC + CodeGraph MCP).
#
# Everything is parameterized — no hardcoded account/region/resource IDs — so a
# fresh AWS account in any region works:
#
#   ./scripts/deploy-all.sh --region ap-northeast-1
#
# Idempotent: every resource is "describe-or-create". Re-running reconciles.
# State persists to .local/deploy-config (gitignored); later runs read it back.
#
# Phases (numbers match the operator-visible `say step "Phase N"` labels; --skip <name>):
#   1  artifacts  : build/stage codegraph-server bin + index-service code + repo → S3
#   1b iam        : execution + index-service instance roles/policies (describe-or-create)
#   2  network    : VPC, public+private subnet, IGW, NAT, route tables (or reuse), a restrictive
#                   NACL, and VPC endpoints for ECR (ecr.api + ecr.dkr, interface) and S3
#                   (gateway) so container image pulls never leave the VPC
#   3  index-svc  : security groups + ARM EC2 (Ubuntu 24.04) running bootstrap.sh
#   4  image      : build the agent container (ARM64) and push to ECR
#   5  projects   : per-project deploy, looped over .local/projects.json — each project
#                   gets its bridge (activate_project.sh), AgentCore runtime, and
#                   bot-gateway unit (co-located on the index host, via SSM)
#   7  monitoring : apply-monitoring.sh — CloudWatch metric-filters + dashboards +
#                   alarms + DAU lambda (opt-in via --with-monitoring; best-effort)
#
# NO EFS: the agent microVM mounts no filesystem; it reads all source code over
# the index-service HTTP bridge (read_file/glob_files/search_files/codegraph_*).
# The index-service keeps the only repo copy, on its local disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/env-utils.sh
source "$SCRIPT_DIR/lib/env-utils.sh"
# shellcheck source=lib/resolve_model.sh
source "$SCRIPT_DIR/lib/resolve_model.sh"

CONFIG_DIR="$ROOT/.local"
CONFIG_FILE="$CONFIG_DIR/deploy-config"
PROJECTS_CFG="$CONFIG_DIR/projects.json"
# Deliberately pre-scan "$@" instead of testing $DRY_RUN: the arg loop runs ~90 lines below, so at
# this point DRY_RUN is still unset and any gate on it passes unconditionally — which is why
# --dry-run still created this directory after being "fixed" once. --help promises "make no
# changes", and an empty .local/ is exactly the promise a cautious first-time user checks.
case " $* " in
  *" --dry-run "*) ;;
  *) mkdir -p "$CONFIG_DIR" ;;
esac

# --- defaults / flags ---
REGION=""
SKIP_PROJECTS=false      # --skip-projects: provision the shared BASE host only, attach no project
                         # (init-env). Code repos + projects come from .local/projects.json (git).
# These honor a persist-and-read-back contract (flag > persisted > default)
# so a flagless reconcile re-run does NOT silently revert an operator's earlier
# choice (deploy_runtime.py updates the runtime IN PLACE, so a reverted MODEL would
# actually flip the live runtime). Empty here = "not given on the CLI"; resolved
# against the persisted config + defaults after safe_source_env below.
INSTANCE_TYPE=""
MAX_FILES=""
GLOSSARY_MAX_FILES=""    # term-glossary build file cap (cc scan); separate from codegraph MAX_FILES
MODEL=""
ROOT_VOLUME_GB=""
IDLE_TIMEOUT=""          # AgentCore session idle timeout (s); gateway session TTL is aligned to this
MAX_LIFETIME=""          # AgentCore microVM hard max age (s) before forced recycle
DEFAULT_INSTANCE_TYPE="t4g.large"
DEFAULT_MAX_FILES="10000"
DEFAULT_GLOSSARY_MAX_FILES="400" # bounded first-deploy cost; 0 (= uncapped, whole repo) only when passed explicitly
# Opt-in extras. Empty = "not given on the CLI"; resolved flag > persisted > default (false) below,
# so a later flagless run keeps the operator's earlier choice (same contract as the knobs above).
WITH_MONITORING=""       # --with-monitoring: Phase 7 (CloudWatch dashboards/alarms/DAU lambda)
WITH_GLOSSARY=""         # --with-glossary: build-time 中文→symbol glossary (cc engine on the host, model cost)
NO_PROBE="${NO_PROBE:-false}"  # --no-probe (or inherited NO_PROBE=1): skip deploy_project.sh's real-question smoke
DEFAULT_MODEL="global.anthropic.claude-opus-4-8"
DEFAULT_ROOT_VOLUME_GB="30"
# Idle timeout default = AWS's own default (900s/15min). The gateway derives its
# session-reuse TTL from this exact value (persisted to deploy-config), so "warm
# enough to reuse" on the gateway and "still alive" on AgentCore mean the same
# thing. Cost: AgentCore bills idle MEMORY (not idle CPU), so raising this trades
# follow-up warm-hit rate for idle-memory spend — tune per workload.
DEFAULT_IDLE_TIMEOUT="900"
DEFAULT_MAX_LIFETIME="28800"
# Where to fetch codegraph-server when it's neither local nor already in S3 (the fresh-machine /
# one-line-installer path). This sample does NOT redistribute the engine: the default source is the
# engine's OWN upstream release. CodeGraph is a public Apache-2.0 Rust workspace
# (github.com/codegraph-ai/CodeGraph) that publishes a linux-arm64 build plus a .sha256 for each
# release, so pointing here is both lawful and one fewer thing for us to keep in sync.
#
# Version note: this used to pin 0.18.5, which has NO upstream tag — nobody outside could obtain or
# build it, so a first deploy could only ever work off a binary we attached to our own release.
# 0.20.1 is protocol-verified against the pinned mcp==1.23.3 client (MCP 2024-11-05; the three
# tools index-service exposes — symbol_search / get_callers / analyze_impact — are present under
# the same names). Override any of these to use a build of your own; see index-service/README.md
# for building from source, which is the route to take for a different arch or an audited build.
CODEGRAPH_SERVER_REPO="${CODEGRAPH_SERVER_REPO:-codegraph-ai/CodeGraph}"
CODEGRAPH_SERVER_TAG="${CODEGRAPH_SERVER_TAG:-v0.20.1}"
# Upstream ships per-platform asset names; the index host and the session microVM are both ARM.
CODEGRAPH_SERVER_ASSET="${CODEGRAPH_SERVER_ASSET:-codegraph-server-linux-arm64}"
CODEGRAPH_SERVER_URL_DEFAULT="https://github.com/${CODEGRAPH_SERVER_REPO}/releases/download/${CODEGRAPH_SERVER_TAG}/${CODEGRAPH_SERVER_ASSET}"
LOCAL_MODE=false          # --local: this EC2 IS the index host; bootstrap in place, reuse its VPC/subnet
# --print-engine-source: echo the engine source values BASH ACTUALLY RESOLVED, then exit.
# check-invariants 8b consumes this instead of grepping for an assignment line. Grepping source
# could not see three real reversions: repointing CODEGRAPH_SERVER_URL_DEFAULT rather than _REPO,
# a second INDENTED re-assignment further down (bash takes the last one, a `^`-anchored grep sees
# the first), and the project repository itself, which needs a separate engine-source check.
# Reading the resolved value makes the guard and the runtime agree by definition.
if [[ "${1:-}" == "--print-engine-source" ]]; then
  printf 'CODEGRAPH_SERVER_REPO=%s\n' "$CODEGRAPH_SERVER_REPO"
  printf 'CODEGRAPH_SERVER_TAG=%s\n' "$CODEGRAPH_SERVER_TAG"
  printf 'CODEGRAPH_SERVER_ASSET=%s\n' "$CODEGRAPH_SERVER_ASSET"
  printf 'CODEGRAPH_SERVER_EFFECTIVE_URL=%s\n' "${CODEGRAPH_SERVER_URL:-$CODEGRAPH_SERVER_URL_DEFAULT}"
  exit 0
fi

# bash 3.2 (stock macOS) has no `declare -A` — model the skip set as a space-delimited
# string ("iam network …") and test membership with a case glob (see skip() below).
SKIP_PHASES=""

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-all.sh --region <r> [options]

Provisions the shared BASE host + every project declared in .local/projects.json. Code repos and
projects are NOT passed on the CLI — they live in .local/projects.json (each project: a port, a
Feishu secret id, and git repos). Use ./scripts/install.sh to create that file interactively.

Required:
  --region <r>        AWS region (e.g. ap-northeast-1)

Options:
  --skip-projects     Provision the shared BASE host only (network/IAM/EC2/image), attach NO
                      project (init-env). Add projects later via ./scripts/install.sh.
  --instance-type <t> index host EC2 type, ARM (default: t4g.large)
  --max-files <n>     codegraph max files to index per repo (default: 10000)
  --with-glossary[=true|false]
                      Build the 中文→code-symbol glossary on the index host (default: OFF). Costs
                      model calls (one full scan + incremental refreshes); persisted for later runs.
                      --with-glossary=false turns it off explicitly (also persisted). Flipping the
                      switch re-bootstraps an existing host in place (minutes of bot downtime).
  --glossary-max-files <n>  glossary build file cap per repo when --with-glossary (default: 400;
                      0 = no cap, whole repo — can cost hundreds of USD on a large repo)
  --with-monitoring[=true|false]
                      Run Phase 7 (CloudWatch metric-filters + dashboards + alarms + DAU lambda;
                      default: OFF). Persisted, so later runs without the flag keep it on;
                      --with-monitoring=false turns it off explicitly (also persisted).
                      Standalone: ./scripts/apply-monitoring.sh --region <r>
                      A deploy-config with a host but WITHOUT the DEPLOY_WITH_* keys predates these
                      switches: both default to ON there (warned once) — pass =false to turn off.
  --no-probe          Skip the post-deploy smoke (1 code question through the runtime;
                      model cost). Also: E2E_PROBE=0.
  --root-volume-gb <n> index host root EBS size in GiB (default: 30). Grow for large repos:
                      it holds every project's repo clones + graph.db.
  --model <id>        default Bedrock model id (a project may override it in projects.json)
  --idle-timeout <s>  AgentCore session idle timeout, seconds (60..28800; default 900/15min).
                      The gateway's session-reuse TTL is aligned to this.
  --max-lifetime <s>  AgentCore microVM hard max age before forced recycle (60..28800; default 28800/8h)
  --skip <phase>      Skip a phase: artifacts|iam|network|index-svc|image|projects|monitoring (repeatable)
  --local             This EC2 IS the index host: bootstrap in place, reuse its VPC/subnet, attach
                      a dedicated SG. No second EC2 is created. ARM64 host only; needs an instance
                      role with the index-host policies (see runbook) + passwordless sudo.
  --dry-run           Print the plan and resolved IDs, make no changes
  --force             Bypass hard-block preflight checks (e.g. vCPU quota) with explicit acknowledgment
  -h, --help

ENVIRONMENT:
  DEPLOY_VPC_ENDPOINTS=false   Skip the ECR/S3 VPC endpoints in Phase 2. The two ECR interface
                      endpoints bill per hour per AZ whether or not anything is running, so an
                      evaluation that only needs the sample for an afternoon can opt out. The cost
                      of opting out is that every container start pulls the image from ECR across
                      the public internet via the NAT gateway — a path that has been observed to
                      fail intermittently, surfacing as "HTTP 424 Runtime health check failed" with
                      no other symptom (the runbook's image-pull section covers the diagnosis).

PREREQUISITES (not auto-provisioned — the deploy hard-fails / WARNs if missing):
  • codegraph-server binary (ARM aarch64, glibc>=2.38, pinned 0.20.1) on PATH or via
    CODEGRAPH_SERVER_BIN. If absent locally and not yet in S3, it is downloaded from
    CODEGRAPH_SERVER_URL (default: the engine's OWN upstream release asset, checksum-verified;
    this repo never redistributes it) — so a fresh machine works. Build it yourself instead:
    see index-service/README.md "Obtaining codegraph-server".
  • A host that can build linux/arm64 images (arm64 host, or x86 + binfmt).
  • Bedrock Converse access for the selected project models (invalid model/profile hard-fails
    unless --force; deployment-role AccessDenied is advisory). Runtime access is verified after deploy.
  • session-manager-plugin for interactive `aws ssm start-session` (optional for automated deploy).
  • A read-only git credential in Secrets Manager (source-truth/git-credentials) for cloning
    private repos — install.sh's "add a project" creates it; or create it by hand.
  • Per-project Feishu app secrets (source-truth/feishu-<projectId>) — install.sh creates these.
EOF
}

DRY_RUN=false
FORCE=false
# Flag-value guards. Every value-taking flag below was a bare `VAR="$2"; shift 2`, which means a
# flag given no value silently consumed the NEXT FLAG as its value. That is not a cosmetic gap:
# `--root-volume-gb --dry-run` swallowed --dry-run and performed a real deploy, so the one command
# a cautious operator runs first is the one that could spend money. Values are also validated at
# parse time, because the alternative is failing in Phase 3 AFTER the NAT gateway is billing.
_need_val() {  # _need_val <flag> <remaining-argc>
  [[ "$2" -ge 2 ]] || { say err "flag $1 needs a value"; exit 2; }
}
_reject_flaglike() {  # _reject_flaglike <value> <flag>
  case "$1" in -?*) say err "flag $2: '$1' looks like another flag, not a value"; exit 2 ;; esac
}
_val() {  # _val <flag> <value> <argc>  -> echo the value after both guards
  _need_val "$1" "$3"; _reject_flaglike "$2" "$1"; printf '%s' "$2"
}
_val_region() {
  local v; v="$(_val "$1" "$2" "$3")"
  [[ "$v" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || { say err "--region '$v' is not an AWS region code"; exit 2; }
  printf '%s' "$v"
}
_val_int() {  # _val_int <flag> <value> <argc> [min] [max]
  local v; v="$(_val "$1" "$2" "$3")"
  [[ "$v" =~ ^[0-9]+$ ]] || { say err "$1 must be a non-negative integer, got '$v'"; exit 2; }
  if [[ -n "${4:-}" ]] && (( v < $4 )); then say err "$1 must be >= $4, got $v"; exit 2; fi
  if [[ -n "${5:-}" ]] && (( v > $5 )); then say err "$1 must be <= $5, got $v"; exit 2; fi
  printf '%s' "$v"
}
_val_bool() {  # _val_bool <flag> <value>  -> true|false (the =value form of an opt-in switch)
  case "$2" in
    true|yes|on|1) printf 'true' ;;
    false|no|off|0) printf 'false' ;;
    *) say err "$1 must be true or false, got '$2'"; exit 2 ;;
  esac
}
_val_arm_instance() {
  local v; v="$(_val "$1" "$2" "$3")"
  # The index host image is ARM64-only (Ubuntu 24.04 arm64; the agent image is built
  # --platform linux/arm64). An x86 type was accepted here and then failed in Phase 3, AFTER the
  # NAT gateway had started billing. Graviton families are the a1/*g* ones.
  [[ "$v" =~ ^[a-z]+[0-9]+g[a-z]*\.[a-z0-9]+$ || "$v" =~ ^a1\. ]] \
    || { say err "--instance-type '$v' is not an ARM64/Graviton type (the index host image is arm64-only; try t4g.large or m7g.large)"; exit 2; }
  printf '%s' "$v"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$(_val_region --region "${2:-}" $#)"; shift 2 ;;
    --skip-projects) SKIP_PROJECTS=true; shift ;;
    --instance-type) INSTANCE_TYPE="$(_val_arm_instance --instance-type "${2:-}" $#)"; shift 2 ;;
    --max-files) MAX_FILES="$(_val_int --max-files "${2:-}" $#)"; shift 2 ;;
    --glossary-max-files) GLOSSARY_MAX_FILES="$(_val_int --glossary-max-files "${2:-}" $#)"; shift 2 ;;
    --root-volume-gb) ROOT_VOLUME_GB="$(_val_int --root-volume-gb "${2:-}" $# 8 16384)"; shift 2 ;;
    --model) MODEL="$(_val --model "${2:-}" $#)"; shift 2 ;;
    # Tenant domain: feishu (China) or lark (international). Drives BOTH the gateway's event
    # long-connection and its REST base — they must not be set independently.
    --feishu-domain)
      _need_val --feishu-domain $#; _reject_flaglike "${2:-}" --feishu-domain
      case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
        feishu|lark) FEISHU_DOMAIN="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ;;
        *) say err "--feishu-domain must be 'feishu' (China) or 'lark' (international), got '$2'"; exit 2 ;;
      esac
      shift 2 ;;
    # Card / message language. Separate from the tenant domain because they are genuinely
    # independent (a China tenant may want English cards), but the DEFAULT is derived from the
    # domain below, since an international tenant getting Chinese cards is never intentional.
    --locale)
      _need_val --locale $#; _reject_flaglike "${2:-}" --locale
      case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
        zh|en) LOCALE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ;;
        *) say err "--locale must be 'zh' or 'en', got '$2'"; exit 2 ;;
      esac
      shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$(_val_int --idle-timeout "${2:-}" $# 60 28800)"; shift 2 ;;
    --max-lifetime) MAX_LIFETIME="$(_val_int --max-lifetime "${2:-}" $# 60 28800)"; shift 2 ;;
    --skip)
      case "${2:-}" in
        # 'runtime'/'gateway' used to be separate phases; they merged into the per-project
        # phase, and skipping only one of them never worked (both were required to skip
        # Phase 5). One canonical name now: projects.
        runtime|gateway) say err "--skip $2 is gone (runtime+gateway merged into the per-project phase): use --skip projects"; exit 2 ;;
        artifacts|iam|network|index-svc|image|projects|monitoring) SKIP_PHASES="$SKIP_PHASES $2" ;;
        *) say err "unknown --skip phase: '${2:-}' (want artifacts|iam|network|index-svc|image|projects|monitoring)"; exit 2 ;;
      esac
      shift 2 ;;
    --local) LOCAL_MODE=true; shift ;;
    --with-monitoring) WITH_MONITORING=true; shift ;;
    --with-monitoring=*) WITH_MONITORING="$(_val_bool --with-monitoring "${1#*=}")"; shift ;;
    --with-glossary) WITH_GLOSSARY=true; shift ;;
    --with-glossary=*) WITH_GLOSSARY="$(_val_bool --with-glossary "${1#*=}")"; shift ;;
    --no-probe) NO_PROBE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "Unknown flag: $1"; usage >&2; exit 2 ;;
  esac
done

# --local requires an ARM64 host: the agent image + codegraph-server are aarch64-only, and the
# image is built on THIS host. An x86 host would push a wrong-arch image that AgentCore can't run —
# and that failure only surfaces at runtime. Fail loud up front instead.
if [[ "$LOCAL_MODE" == true && "$(uname -m)" != "aarch64" ]]; then
  say err "--local requires an ARM64 (aarch64) host (the agent image + codegraph-server are ARM64-only); this host is $(uname -m)."
  exit 1
fi

# skip <phase> : true if --skip <phase> was given. Defined HERE (before preflight) because
# preflight_docker consults `skip image` — it used to be defined further down, after the preflight
# call, so `skip` was "command not found" at preflight time (harmless-looking but it silently made
# preflight_docker's early-return misfire).
skip() { case " $SKIP_PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- preflight ---
say step "Phase 0: preflight"
require_cmd aws || exit 1
require_cmd python3 || exit 1
safe_source_env "$CONFIG_FILE"
REGION="${REGION:-${DEPLOY_REGION:-}}"
[[ -n "$REGION" ]] || { say err "--region required"; exit 2; }
# One .local/deploy-config describes ONE region's deployment (instance ids, subnets, image URIs are
# all regional). Re-pointing it at another region would "reuse" resources that do not exist there
# and wire the new project to the old region's image and index host.
if [[ -n "${DEPLOY_REGION:-}" && "$DEPLOY_REGION" != "$REGION" ]]; then
  say err ".local/deploy-config 记录的是 ${DEPLOY_REGION} 的部署，与 --region ${REGION} 不一致 / deploy-config belongs to ${DEPLOY_REGION}, not ${REGION}."
  say err "  → 另一个区域请用另一份检出（或先把 .local/ 移走）；同一区域请去掉 --region 或改回 ${DEPLOY_REGION}。"
  say err "    use a separate checkout per region (or move .local/ aside); for this region drop --region or pass ${DEPLOY_REGION}."
  exit 2
fi
# Does this region actually exist and is it enabled for the account? A well-formed but non-existent
# code (xx-bogus-9) passes any regex and used to surface as an opaque endpoint error mid-deploy.
# --output text separates with TABS. Normalise BEFORE matching, not only for the message —
# matching on spaces against tab-separated data rejected every legitimate region, which is the
# dangerous direction for a guard: it would have blocked every deploy rather than letting one slip.
_known_regions="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t\n' '  ' || echo "")"
if [[ -n "$_known_regions" ]]; then
  case " $_known_regions " in
    *" $REGION "*) ;;
    *) say err "region '$REGION' is not an enabled region for this account."
       say err "  enabled: $_known_regions"
       exit 2 ;;
  esac
else
  # Could not enumerate (no permission / throttled). Do NOT fail the deploy on that — but say so,
  # because it means the region was accepted on its shape alone.
  say warn "could not enumerate regions (ec2:DescribeRegions denied?) — '$REGION' accepted on format only"
fi
# Resolve flag > persisted > default for the operator-tunable knobs, so a flagless
# reconcile re-run keeps the earlier choice instead of reverting to the default
# (which would flip the live runtime's model via the in-place update).
MODEL="${MODEL:-${DEPLOY_MODEL:-$DEFAULT_MODEL}}"
# Tenant domain, same flag > persisted > default chain as the settings above. Persisted so a
# per-project deploy (deploy_project.sh) and every later re-run inherit it without the flag.
# Re-validated here because this chain also accepts an inherited ENVIRONMENT value, which never
# passed through the flag's case statement — the strict gate was on the path least likely to be
# wrong, while the unvalidated one was the path whose value gets persisted.
FEISHU_DOMAIN="$(printf '%s' "${FEISHU_DOMAIN:-${DEPLOY_FEISHU_DOMAIN:-feishu}}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$FEISHU_DOMAIN" in
  feishu|lark) ;;
  *) say err "FEISHU_DOMAIN must be 'feishu' or 'lark', got '$FEISHU_DOMAIN'"; exit 2 ;;
esac
export FEISHU_DOMAIN
# Locale default is DERIVED from the tenant: an international Lark deploy with Chinese cards is a
# plumbing accident, not a choice. config/i18n.json ships a complete 'en' bundle and the gateway
# honours it; until now nothing set LOCALE at all, so ${LOCALE:-zh} always resolved to zh and
# activate_gateway.sh rewrote LOCALE='zh' on every activation, reverting any hand-edit.
if [[ -z "${LOCALE:-}" ]]; then
  if [[ -n "${DEPLOY_LOCALE:-}" ]]; then LOCALE="$DEPLOY_LOCALE"
  elif [[ "$FEISHU_DOMAIN" == "lark" ]]; then LOCALE="en"
  else LOCALE="zh"; fi
fi
case "$LOCALE" in
  zh|en) ;;
  *) say err "LOCALE must be 'zh' or 'en', got '$LOCALE'"; exit 2 ;;
esac
export LOCALE
# Keep the operator's declared choice for persistence (DEPLOY_MODEL should record what
# they asked for, not a per-region derivative), but the RUNTIME needs a profile that
# actually exists in THIS region. The default is a global.* profile; many regions
# (e.g. ap-southeast-1) don't carry a geo profile and some don't carry global the same
# way, and the geo prefixes are us./eu./jp./au. (NOT apac.) — too fiddly to hardcode.
# resolve_model_for_region asks Bedrock what's offered here and picks the best match
# (geo > global), or returns MODEL unchanged if it can't tell (the invoke-probe below
# then WARNs). Skipped in dry-run (it makes an AWS call). See lib/resolve_model.sh.
MODEL_DECLARED="$MODEL"
if [[ "$DRY_RUN" != true ]]; then
  _MODEL_RC=0
  MODEL="$(resolve_model_for_region "$MODEL" "$REGION")" || _MODEL_RC=$?
  [[ "$_MODEL_RC" == 0 ]] || say warn "default model profile remains unverified: $MODEL"
  [[ "$MODEL" == "$MODEL_DECLARED" ]] || say info "resolved model for $REGION: $MODEL_DECLARED → $MODEL"
fi
INSTANCE_TYPE="${INSTANCE_TYPE:-${DEPLOY_INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}}"
# Export so provision_network.sh can pick an AZ that actually offers this type
# (Graviton isn't in every AZ of every region) instead of a blind AvailabilityZones[0].
export DEPLOY_INSTANCE_TYPE="$INSTANCE_TYPE"
MAX_FILES="${MAX_FILES:-${DEPLOY_MAX_FILES:-$DEFAULT_MAX_FILES}}"
GLOSSARY_MAX_FILES="${GLOSSARY_MAX_FILES:-${DEPLOY_GLOSSARY_MAX_FILES:-$DEFAULT_GLOSSARY_MAX_FILES}}"
# Upgrade path: a deploy-config that already has a host but NO DEPLOY_WITH_* key predates the
# opt-in switches, when glossary + monitoring were always on. Defaulting to false there would turn
# a working feature OFF on the next flagless run (and re-bootstrap the host to do it). Keep ON,
# warn once, and persist below; --with-<x>=false is the explicit way to turn it off.
resolve_optin() {  # resolve_optin <flag-value> <persisted-value> <name> -> true|false
  if [[ -n "$1" ]]; then printf '%s' "$1"; return; fi
  if [[ -n "$2" ]]; then printf '%s' "$2"; return; fi
  if [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    say warn "现有部署早于开关 / existing deployment predates the opt-in switches — keeping $3 ON;"
    say warn "  pass --with-$3=false (or edit .local/deploy-config DEPLOY_WITH_$(printf '%s' "$3" | tr '[:lower:]' '[:upper:]')=false) to turn it off"
    printf 'true'; return
  fi
  printf 'false'
}
WITH_MONITORING="$(resolve_optin "$WITH_MONITORING" "${DEPLOY_WITH_MONITORING:-}" monitoring)"
WITH_GLOSSARY="$(resolve_optin "$WITH_GLOSSARY" "${DEPLOY_WITH_GLOSSARY:-}" glossary)"
GLOSSARY_SETTINGS_CHANGED=false
if [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]] && \
   [[ "$WITH_GLOSSARY" != "${DEPLOY_WITH_GLOSSARY:-true}" || \
      "$GLOSSARY_MAX_FILES" != "${DEPLOY_GLOSSARY_MAX_FILES:-400}" ]]; then
  GLOSSARY_SETTINGS_CHANGED=true
  if skip index-svc; then
    say err "glossary switch/cap changed: cannot use --skip index-svc; the host must apply these settings first"
    exit 2
  fi
fi
# Glossary OFF ⇒ the host gets an EMPTY glossary model: activate_project.sh treats "MODEL empty"
# as "engine disabled" (no initial build), the refresh timer becomes pull-only, and bootstrap.sh
# skips the claude CLI install (GLOSSARY_ENABLED=false in /etc/index-service.env).
GLOSSARY_MODEL=""
[[ "$WITH_GLOSSARY" == true ]] && GLOSSARY_MODEL="$MODEL"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-${DEPLOY_ROOT_VOLUME_GB:-$DEFAULT_ROOT_VOLUME_GB}}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-${DEPLOY_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}}"
MAX_LIFETIME="${MAX_LIFETIME:-${DEPLOY_MAX_LIFETIME:-$DEFAULT_MAX_LIFETIME}}"
# Persisted options need the same validation as explicit CLI values.
IDLE_TIMEOUT="$(_val_int --idle-timeout "$IDLE_TIMEOUT" 2 60 28800)"
MAX_LIFETIME="$(_val_int --max-lifetime "$MAX_LIFETIME" 2 60 28800)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# Repos are NOT a CLI concern any more — they live in .local/projects.json and are git-cloned on
# the index host by activate_project.sh (Phase 5). The deploy stages only the codegraph binary +
# index-service/bot-gateway code to S3 (Phase 1); no repo tarballs.
BUCKET="source-truth-repo-${ACCOUNT}-$(echo "$REGION" | tr -d '-')"
say info "account=$ACCOUNT region=$REGION bucket=$BUCKET model=$MODEL skip_projects=$SKIP_PROJECTS glossary=$WITH_GLOSSARY monitoring=$WITH_MONITORING"

# Converse accepts both supported model families. A deploy identity may have
# different permissions from the runtime role, so its AccessDenied is advisory;
# the post-deploy smoke verifies the actual runtime identity and code tools.
preflight_model_access() {
  command -v aws >/dev/null || return 0
  local probe_model="${1:?model required}" err rc
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] Bedrock Converse model probe: $probe_model (no inference)"
    return 0
  fi
  if err="$(run_timeout 30 aws bedrock-runtime converse --region "$REGION" --model-id "$probe_model" \
        --cli-connect-timeout 8 --cli-read-timeout 20 \
        --messages '[{"role":"user","content":[{"text":"Reply OK."}]}]' \
        --inference-config '{"maxTokens":16}' 2>&1)"; then
    say ok "Bedrock Converse model access OK ($probe_model)"
  else
    rc=$?
    # AWS CLI errors start with a blank line. Keep the first useful line in the
    # diagnostic instead of printing an empty reason.
    while [[ "$err" == $'\n'* || "$err" == $'\r'* ]]; do err="${err:1}"; done
    case "$err" in
      *AccessDenied*|*"don't have access"*|*"not authorized"*)
        say warn "部署身份无法调用 / deploy identity cannot invoke $probe_model in $REGION."
        say warn "  Runtime 角色权限可能不同；部署后真实问答验收会核对 / the runtime role is checked by post-deploy smoke." ;;
      *ValidationException*|*ResourceNotFoundException*|*not\ enabled*)
        say err "模型/区域配置无效 / invalid model or region for $probe_model: ${err%%$'\n'*}"
        if [[ "$FORCE" == true ]]; then
          say warn "  --force: continuing despite the failed model probe."
        else
          say err "  → fix the model/profile in projects.json, or re-run with --force."
          exit 1
        fi ;;
      *)
        if [[ "$rc" == 124 ]]; then
          say info "model-access probe timed out (>30s); skipping check and continuing"
        else
          say info "model-access probe inconclusive (non-access error: ${err%%$'\n'*}); continuing"
        fi ;;
    esac
  fi
}

preflight_project_models() {
  local models declared resolved resolve_rc
  models="$(PYTHONPATH="$ROOT/agent-container" python3 - "$PROJECTS_CFG" "$MODEL_DECLARED" "$WITH_GLOSSARY" <<'PY'
import json
from pathlib import Path
import sys
from agent_settings import deployment_models
path = Path(sys.argv[1])
config = json.loads(path.read_text()) if path.exists() else {}
print("\n".join(deployment_models(config, legacy_model=sys.argv[2], glossary=sys.argv[3] == "true")))
PY
)" || { say err "invalid project model configuration"; exit 2; }
  if [[ -z "$models" ]]; then
    say info "No project model selected yet; model checks run when adding a project."
    return 0
  fi
  while IFS= read -r declared; do
    [[ -n "$declared" ]] || continue
    resolved="$declared"
    if [[ "$DRY_RUN" != true ]]; then
      resolve_rc=0
      resolved="$(resolve_model_for_region "$declared" "$REGION")" || resolve_rc=$?
      [[ "$resolve_rc" == 0 ]] || say warn "model profile remains unverified: $resolved"
    fi
    preflight_model_access "$resolved"
  done <<< "$models"
}

# Validate the complete declaration before any infrastructure is changed. The
# per-project builder catches malformed repos, but only a global pass can catch
# two projects sharing the same bridge port or on-host repo/writer lock.
preflight_project_config() {
  [[ -f "$PROJECTS_CFG" ]] || return 0
  validate_projects_config "$PROJECTS_CFG" "$SCRIPT_DIR/lib"
}
# AgentCore is a newer service available only in a SUBSET of regions, and on a
# fresh account first use can need a service-linked role / activation. If it isn't
# reachable in this region, Phase 5 would later abort with a raw boto3 traceback.
# Probe it up-front and WARN actionably (non-blocking, like the model-access probe)
# so the operator learns the region/enablement gap before the long index/build phases.
preflight_agentcore() {
  command -v aws >/dev/null || return 0
  if run_timeout 20 aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" --max-results 1 >/dev/null 2>&1; then
    say ok "AgentCore reachable in $REGION"
  else
    say warn "AgentCore (bedrock-agentcore-control) not reachable in $REGION via this identity."
    say warn "  → On a NEW account/region, confirm AgentCore is available in $REGION and enabled"
    say warn "    for the account (first use may auto-create a service-linked role). If the region"
    say warn "    doesn't support AgentCore, pick a supported one. Phase 5 will fail until then."
  fi
}

# Phase 4 builds the agent image, which needs a RUNNING docker daemon (not just the
# `docker` binary). Checking it in preflight — before any VPC/EC2/NAT is created —
# means a stopped Docker Desktop fails the deploy in seconds instead of after billable
# resources are provisioned. HARD-FAIL (unlike the WARN-only AWS probes): the build
# cannot proceed without it. Skipped when the image phase is skipped (docker not needed).
preflight_docker() {
  skip image && return 0
  # Runs in --dry-run TOO (see the call site): every check below is local, free and touches no AWS
  # resource, and a dry run is exactly where an x86 operator most wants to hear that their machine
  # cannot build the ARM64 image. A dry run creates nothing, so there is nothing to abort — the same
  # findings are reported at warn level and the run continues. $lvl carries that distinction.
  local lvl=err
  [[ "$DRY_RUN" == true ]] && lvl=warn
  # A MISSING docker binary used to return 0 here and be caught by Phase 4's require_cmd — but
  # Phase 2 creates the NAT gateway (billing starts at creation) and Phase 3 launches and
  # bootstraps the EC2 first, so the operator paid for ~10 minutes of infrastructure to be told
  # their machine cannot build the image. Same class as the arm64 check this function now owns.
  if ! command -v docker >/dev/null; then
    say "$lvl" "docker not found — Phase 4 builds the ARM64 agent image and cannot proceed without it."
    say "$lvl" "  → install Docker (with buildx and arm64 emulation), or pass --skip image if the image is already in ECR."
    [[ "$DRY_RUN" == true ]] || exit 1
    return 0
  fi
  if ! run_timeout 20 docker info >/dev/null 2>&1; then
    say "$lvl" "docker is installed but its daemon isn't running — Phase 4 (image build) needs it."
    say "$lvl" "  → start Docker Desktop (or dockerd), wait until ready, then re-run. Verify: docker info"
    [[ "$DRY_RUN" == true ]] || exit 1
    return 0
  fi
  # ARM64 BUILD CAPABILITY — checked HERE, in preflight, not at Phase 4 where it used to live.
  # The agent container is ARM64-only, and most laptops are x86. Failing at Phase 4 meant the
  # operator had already paid for Phase 2's NAT gateway (billing starts at creation) and waited
  # through Phase 3's EC2 launch + bootstrap — roughly ten minutes and real money before being
  # told their machine cannot build the image at all.
  if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
    # NON-MUTATING probe. `buildx inspect --bootstrap` STARTS (and when absent CREATES) the buildkit
    # builder, pulling moby/buildkit on a cold machine — a side effect every deploy-all run would pay
    # for, including reconcile runs that never rebuild, and one a preflight must not have at all.
    # Plain `inspect` reports the selected builder's platforms without starting anything; `buildx ls`
    # is the fallback when the selected builder can't be inspected (it still lists the `default`
    # docker-driver builder, whose platform list is what Phase 4's classic `docker build` actually
    # uses). Both are wrapped in run_timeout so a wedged docker CLI can't hang Phase 0, and `|| true`
    # keeps a non-zero probe from tripping set -e inside the assignment.
    local bx=""
    bx="$(run_timeout 20 docker buildx inspect 2>/dev/null || true)"
    [[ "$bx" == *linux/arm64* ]] || bx="$(run_timeout 20 docker buildx ls 2>/dev/null || true)"
    if [[ "$bx" != *linux/arm64* ]]; then
      say "$lvl" "host is $(uname -m) and cannot build linux/arm64. Set up emulation first:"
      say "$lvl" "  docker run --privileged --rm tonistiigi/binfmt --install arm64"
      say "$lvl" "  (or run the deploy from an arm64 host). The agent container is ARM64-only."
      [[ "$DRY_RUN" == true ]] || exit 1
    fi
  fi
}
# Phase 5 configures the AgentCore Runtime via boto3 (lib/deploy_runtime.py), NOT the
# aws CLI — so the CLI-based preflight_agentcore above does NOT cover it. A fresh box
# can have a recent aws CLI (green above) but a stale pip boto3 that lacks the
# bedrock-agentcore-control service → create_agent_runtime raises UnknownServiceError
# only AFTER Phases 1-4 (~10+ min of upload/bootstrap/build) already ran. Assert the
# boto3 service is present up front and FAIL FAST with the fix. HARD blocker (not WARN):
# without it Phase 5 cannot succeed at all.
preflight_boto3() {
  python3 - <<'PY' 2>/dev/null && return 0
import boto3, sys
sys.exit(0 if "bedrock-agentcore-control" in boto3.Session().get_available_services() else 1)
PY
  say err "boto3/botocore is too old (no 'bedrock-agentcore-control' service) — Phase 5 would fail"
  say err "  ~10 min in, after the build. Fix now:  python3 -m pip install -U boto3 botocore"
  exit 1
}
# Fresh accounts default to low EIP(5)/VPC(5) per-region quotas. provision_network's
# allocate-address/create-vpc run under set -e and would abort mid-Phase-2 with a raw
# AddressLimitExceeded/VpcLimitExceeded if the account already sits at the cap. WARN up
# front (non-blocking — a deploy reuses its own tagged EIP/VPC, so a clean account is fine).
preflight_quota() {
  command -v aws >/dev/null || return 0
  local eips vpcs fail=0
  eips="$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text 2>/dev/null || echo "")"
  vpcs="$(aws ec2 describe-vpcs --region "$REGION" --query 'length(Vpcs)' --output text 2>/dev/null || echo "")"
  # NB: use `if`, NOT `[[ … ]] && say` — under `set -e`, a `[[ … ]] && cmd` whose
  # test is FALSE returns non-zero, and as the LAST statement of the function that
  # non-zero return aborts the whole script (this exact trap silently killed a
  # deploy at Phase 0 when the account had <4 EIPs — the common fresh-account case).
  if [[ "$eips" =~ ^[0-9]+$ && "$eips" -ge 4 ]]; then
    say warn "已有 $eips 个 EIP（默认配额 5）——若 NAT 的 allocate-address 失败，先去 Service Quotas 提额或释放闲置 EIP / $eips EIPs already allocated (default quota is 5) — if the NAT's allocate-address fails, raise the quota in Service Quotas or release an idle EIP first."
  fi
  if [[ "$vpcs" =~ ^[0-9]+$ && "$vpcs" -ge 4 ]]; then
    say warn "已有 $vpcs 个 VPC（默认配额 5）——若 create-vpc 失败，先提额或清理 / $vpcs VPCs already exist (default quota is 5) — if create-vpc fails, raise the quota or clean up unused VPCs first."
  fi
  # vCPU (On-Demand Standard family, quota L-1216C47A): a BRAND-NEW account often caps
  # standard On-Demand vCPUs low (historically as low as 5, sometimes 0 until raised). The
  # index instance is a Standard-family Graviton (t4g.large = 2 vCPU). Without this, a fresh
  # account fails LATE in Phase 3 with a raw VcpuLimitExceeded instead of an early block.
  # HARD BLOCK (not WARN): a quota this low makes Phase 3 certain to fail — abort early with
  # the fix. Pass --force to bypass if you know the quota is being raised or the check is stale.
  local vcpu_quota
  vcpu_quota="$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null || echo "")"
  # Value comes back like "5.0"; compare the integer part.
  if [[ "$vcpu_quota" =~ ^([0-9]+) ]]; then
    local vcpu_int="${BASH_REMATCH[1]}"
    if [[ "$vcpu_int" -lt 4 ]]; then
      say err "On-Demand Standard vCPU 配额仅 ${vcpu_int}（quota L-1216C47A）——index 实例本身需 2 vCPU（t4g.large），但本检查要求 ≥4：同一账号内并存的构建/临时实例会占用同一配额，配额恰好为 2 时run-instances 仍会报 VcpuLimitExceeded / On-Demand Standard vCPU quota is only ${vcpu_int} (quota L-1216C47A). The index instance needs 2 vCPU (t4g.large); this check requires >=4 because build and transient instances draw on the same quota, so a quota of exactly 2 still fails run-instances with VcpuLimitExceeded."
      say err "  → 去 Service Quotas 提额（至少 4 vCPU），或用 --force 强制跳过此检查 / raise the quota in Service Quotas (to at least 4 vCPU), or re-run with --force to skip this check."
      if [[ "$FORCE" != true ]]; then
        fail=1
      else
        say warn "  --force: 跳过 vCPU 配额硬阻断（操作者已确认）/ --force given, skipping the vCPU-quota hard block (operator confirmed)."
      fi
    fi
  fi
  if [[ "$fail" -ne 0 ]]; then
    say err "preflight quota check failed — fix the above or re-run with --force"
    exit 1
  fi
  return 0
}
# preflight_docker runs in --dry-run as well: docker present / daemon up / arm64 build capability are
# LOCAL, free, non-AWS and non-mutating checks, and "your machine cannot build the ARM64 image" is
# precisely what a dry run should tell you. Under --dry-run it reports at warn level and never exits.
# The AWS-touching probes stay off in dry-run. Order for real runs is unchanged (boto3 → docker → …).
[[ "$DRY_RUN" == true ]] || preflight_boto3
preflight_docker
# GNU tar, checked HERE in Phase 0 rather than where det_tar first runs. README lists GNU tar under
# "hard-fail", and defines hard-fail as "Phase 0 aborts BEFORE creating anything billable" — but the
# only check lived inside det_tar, first reached in the artifacts phase, after the S3 bucket had
# already been created. A stock-macOS reader (BSD tar) did get a real hard-fail, just not where the
# README promised and not before the first billable resource. Same class as the arm64 buildx check,
# which was moved into Phase 0 for exactly this reason. Local, free, non-mutating, so it runs under
# --dry-run too.
preflight_gnu_tar() {
  if tar --version 2>/dev/null | grep -qi 'gnu tar' || command -v gtar >/dev/null 2>&1; then
    return 0
  fi
  local msg="未找到 GNU tar（BSD tar 不支持 --sort/--mtime/--owner，产出的 tarball 每次字节不同，"
  msg+="会让每次部署都判定 ArtifactSig 过期并触发原地重引导——即整机网关停数分钟）。macOS 用 "
  msg+="brew install gnu-tar。 / GNU tar not found. BSD tar lacks --sort/--mtime/--owner, so the "
  msg+="tarball differs byte-wise on every run, every deploy judges ArtifactSig stale and triggers "
  msg+="an in-place re-bootstrap that stops every gateway on the host for minutes. On macOS: "
  msg+="brew install gnu-tar."
  if [[ "$DRY_RUN" == true ]]; then
    say warn "$msg"
  else
    say err "$msg"
    exit 1
  fi
}
preflight_gnu_tar
# Interactive SSM sessions need this plugin; deployment uses SendCommand and
# GetCommandInvocation, which work without it.
preflight_ssm_plugin() {
  command -v session-manager-plugin >/dev/null 2>&1 && return 0
  say warn "缺少 session-manager-plugin；自动部署可继续，交互登录主机前需安装。"
  say warn "  Interactive SSM sessions need: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  return 0
}
preflight_ssm_plugin
# These are READ-ONLY probes (Bedrock model listing, AgentCore reachability), so they run in
# --dry-run as well. Withholding them made `--dry-run` answer "what would be built" while staying
# silent on "can this machine and account actually do it" — which is the question the operator was
# asking by running a plan first.
# Observability reachability. The agent is launched through `opentelemetry-instrument`, so it EMITS
# spans; whether they are queryable depends on CloudWatch Transaction Search, which is an
# account+region switch this deploy does not own. Without it the spans go nowhere and the symptom is
# indistinguishable from having no instrumentation at all — the exact shape of the defect this
# wiring just fixed. Advisory, never fatal: answering questions does not depend on it.
preflight_observability() {
  local dest
  dest="$(aws xray get-trace-segment-destination --region "$REGION" \
    --query 'Destination' --output text 2>/dev/null || echo "")"
  if [[ "$dest" == "CloudWatchLogs" ]]; then
    say ok "CloudWatch Transaction Search 已开（span 可查询）"
  else
    say warn "CloudWatch Transaction Search 未开（region $REGION）——agent 会产出 span，但无处可查。"
    say warn "  开启（一次性，按区域；Transaction Search + 每个 runtime 的 span 投递，Evaluations 依赖它）："
    say warn "    ./scripts/apply-monitoring.sh --region $REGION --only observability"
    say warn "  详见 docs/runbook_en.md \"Observability\"。"
    say warn "  不影响本次部署，也不影响机器人回答问题。"
  fi
}

preflight_project_config || exit 2
preflight_project_models; preflight_agentcore; preflight_observability
if [[ "$DRY_RUN" != true ]]; then
  # preflight_quota checks EIP/VPC/vCPU headroom — all for resources we're about to CREATE. --local
  # creates none of them (reuses this host's VPC/subnet, doesn't run-instances or allocate an EIP),
  # so the checks are irrelevant and their warnings just mislead. Skip in --local.
  [[ "$LOCAL_MODE" == true ]] || preflight_quota
fi

# Persist resolved config — but NOT on --dry-run (dry-run must make no changes,
# including no writes to deploy-config).
if [[ "$DRY_RUN" != true ]]; then
  update_env "$CONFIG_FILE" DEPLOY_REGION "$REGION"
  update_env "$CONFIG_FILE" ARTIFACT_BUCKET "$BUCKET"
  # Persist the resolved knobs so the next flagless run reads them back. For the model
  # we persist the operator's DECLARED choice, not the region-resolved profile — so a
  # re-run (possibly in a different region) re-resolves from intent rather than from a
  # prior region's derivative. resolve_model_for_region runs again on every deploy.
  update_env "$CONFIG_FILE" DEPLOY_MODEL "$MODEL_DECLARED"
  update_env "$CONFIG_FILE" DEPLOY_INSTANCE_TYPE "$INSTANCE_TYPE"
  update_env "$CONFIG_FILE" DEPLOY_MAX_FILES "$MAX_FILES"
  # Monitoring controls Phase 7; it has no index-host configuration to apply.
  # Persist the choice even when --skip index-svc leaves the host unchanged.
  update_env "$CONFIG_FILE" DEPLOY_WITH_MONITORING "$WITH_MONITORING"
  # DEPLOY_WITH_GLOSSARY / DEPLOY_GLOSSARY_MAX_FILES: on a FIRST deploy
  # (no host yet, no key yet) persist them now, otherwise a Phase 3 failure leaves "host exists,
  # key missing" behind and the next run's legacy default flips an explicitly disabled switch back
  # on. On an EXISTING host they are persisted only after Phase 3 succeeds (see below), because
  # install.sh's redeploy decides whether the host needs a re-bootstrap by comparing the flag with
  # the persisted value, so a failed run must not record the new value.
  if [[ -z "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    [[ -n "${DEPLOY_WITH_GLOSSARY:-}" ]]   || update_env "$CONFIG_FILE" DEPLOY_WITH_GLOSSARY "$WITH_GLOSSARY"
    [[ -n "${DEPLOY_GLOSSARY_MAX_FILES:-}" ]] || update_env "$CONFIG_FILE" DEPLOY_GLOSSARY_MAX_FILES "$GLOSSARY_MAX_FILES"
  fi
  update_env "$CONFIG_FILE" DEPLOY_FEISHU_DOMAIN "$FEISHU_DOMAIN"
  update_env "$CONFIG_FILE" DEPLOY_LOCALE "$LOCALE"
  update_env "$CONFIG_FILE" DEPLOY_ROOT_VOLUME_GB "$ROOT_VOLUME_GB"
  # idle-timeout / max-lifetime are consumed by deploy_project.sh (which reads DEPLOY_IDLE_TIMEOUT /
  # DEPLOY_MAX_LIFETIME). They MUST be persisted and exported, or --idle-timeout is parsed and then
  # silently ignored (a dead flag).
  update_env "$CONFIG_FILE" DEPLOY_IDLE_TIMEOUT "$IDLE_TIMEOUT"
  update_env "$CONFIG_FILE" DEPLOY_MAX_LIFETIME "$MAX_LIFETIME"
fi
export DEPLOY_IDLE_TIMEOUT="$IDLE_TIMEOUT" DEPLOY_MAX_LIFETIME="$MAX_LIFETIME"
# deploy_project.sh reads these: glossary on/off decides the model it hands activate_project.sh;
# NO_PROBE=1 skips its post-deploy smoke.
export DEPLOY_WITH_GLOSSARY="$WITH_GLOSSARY"
case "$NO_PROBE" in true|1) export NO_PROBE=1 ;; *) unset NO_PROBE ;; esac

run() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] $*"; else "$@"; fi; }

# det_tar — archive the given paths to stdout, DETERMINISTICALLY. GNU tar (or `gtar`) supports
# --sort/--mtime/--owner, which pin byte order so the gzipped tarball (hence its S3 ETag) is
# identical across runs with identical content — that is what keeps the index-host ArtifactSig
# comparison from reporting "stale" on every deploy.
#
# THIS IS NOW A CORRECTNESS REQUIREMENT, NOT AN OPTIMIZATION. It used to be fine to fall back to
# BSD tar: a byte-different-but-content-identical tarball merely caused an extra upload and a
# stale WARN. Since blue-green replacement was removed, a stale signature triggers an IN-PLACE
# re-bootstrap, which stops every bot-gateway@* and index-bridge-* on the host for minutes. So on
# a BSD-tar box (stock macOS) the old fallback meant EVERY deploy caused an outage. Fail loudly
# instead, with the one-line fix.
det_tar() {  # caller sets cwd; args = files/dirs to include
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - "$@"
  elif command -v gtar >/dev/null 2>&1; then
    gtar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - "$@"
  else
    say err "GNU tar is required to build reproducible artifacts, and this box has only BSD tar."
    say err "  Without --sort/--mtime the tarball bytes differ every run, so the index host reads"
    say err "  the artifacts as CHANGED on every deploy and re-bootstraps in place — stopping every"
    say err "  gateway and bridge for minutes, each time, for no reason."
    say err "  Fix: brew install gnu-tar   (provides gtar, which this script picks up automatically)"
    exit 1
  fi
}

# ============================================================
# Phase 1: artifacts → S3
# ============================================================
if skip artifacts; then say warn "skip artifacts"; elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 1: artifacts → S3"
  say info "[dry-run] ensure bucket $BUCKET; upload codegraph-server bin + index-service.tar.gz (incl. *.sh) + bot-gateway.tar.gz"
else
  say step "Phase 1: artifacts → S3"
  # Create the bucket if absent. us-east-1 is special: the S3 API REJECTS a
  # LocationConstraint of us-east-1, so it must be omitted there; every other
  # region requires it. (head-bucket succeeds → already exists, skip create.)
  if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    if [[ "$REGION" == "us-east-1" ]]; then
      run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    else
      run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
    fi
  fi

  # codegraph-server binary (ARM aarch64, needs glibc>=2.38 — see index-service/
  # README.md "取得 codegraph-server / Obtaining codegraph-server" for the canonical download). Resolve
  # order: explicit $CODEGRAPH_SERVER_BIN → on PATH → ~/.local/bin. If none is
  # found locally AND the S3 object isn't already staged from a prior run, HARD-
  # FAIL here with an actionable message — do NOT warn-green and let the missing
  # binary surface minutes later as an opaque Phase-4 health timeout (bootstrap
  # `aws s3 cp` of the missing key dies under set -e → index never builds).
  # Resolve order: explicit $CODEGRAPH_SERVER_BIN → on PATH → ~/.local/bin → already
  # in S3 (prior run) → download from $CODEGRAPH_SERVER_URL (the published Release asset,
  # so a fresh machine with no local binary still works — this is what the one-line
  # installer relies on). Only the URL tier is new; the local/S3 tiers are unchanged.
  # --- codegraph-acquire:begin --- (scripts/tests/test_codegraph_checksum.sh extracts
  # everything between these sentinels and runs it against stubs. Keep them around the WHOLE
  # resolve+verify+stage block: the checksum step here was once unreachable dead code that a
  # text-matching guard reported as present, so this block is behaviour-tested, not grepped.)
  CG_BIN="${CODEGRAPH_SERVER_BIN:-$(command -v codegraph-server || echo "$HOME/.local/bin/codegraph-server")}"
  # An EXPLICIT path that is not usable is a configuration error. Falling through to S3 or a
  # download means the operator asked for their own audited binary and silently got other bytes —
  # and both documented routes end in a manual `chmod +x`, so a forgotten chmod is the common case.
  if [[ -n "${CODEGRAPH_SERVER_BIN:-}" && ! -x "$CODEGRAPH_SERVER_BIN" ]]; then
    say err "CODEGRAPH_SERVER_BIN is set but not an executable file: $CODEGRAPH_SERVER_BIN"
    if [[ -e "$CODEGRAPH_SERVER_BIN" ]]; then
      say err "  it exists — missing the executable bit? run: chmod +x \"$CODEGRAPH_SERVER_BIN\""
    else
      say err "  no such file. Fix the path, or unset it to use the download path."
    fi
    exit 1
  fi
  if [[ -x "$CG_BIN" ]]; then
    run aws s3 cp "$CG_BIN" "s3://$BUCKET/bin/codegraph-server" --region "$REGION"
  elif aws s3api head-object --bucket "$BUCKET" --key bin/codegraph-server --region "$REGION" >/dev/null 2>&1; then
    # The reuse tier used to trust whatever a prior run staged, indefinitely, with no record of
    # whether it had ever been verified — so bytes staged before verification existed, or by a run
    # that failed open, were re-adopted by every later deploy. head-object also succeeds on a
    # zero-byte object. The verified digest is stamped as object metadata when staging, so read it
    # back here: its ABSENCE means "staged by something that did not verify", which the operator
    # should know even though the object cannot be re-hashed without downloading it.
    cg_meta="$(aws s3api head-object --bucket "$BUCKET" --key bin/codegraph-server \
      --region "$REGION" --query 'Metadata.sha256' --output text 2>/dev/null || echo "")"
    if [[ -n "$cg_meta" && "$cg_meta" != "None" ]]; then
      say info "codegraph-server reused from s3://$BUCKET/bin/codegraph-server (verified ${cg_meta:0:16}…)"
      if [[ -n "${CODEGRAPH_SERVER_SHA256:-}" ]]; then
        cg_pin="$(printf '%s' "$CODEGRAPH_SERVER_SHA256" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
        if [[ "$cg_pin" != "$cg_meta" ]]; then
          say err "the staged codegraph-server was verified as $cg_meta but CODEGRAPH_SERVER_SHA256"
          say err "  pins $cg_pin — the staged object is not the build you asked for."
          say err "  Remove s3://$BUCKET/bin/codegraph-server and re-run to re-stage."
          exit 1
        fi
      fi
    else
      say warn "codegraph-server reused from S3 but carries NO recorded digest — staged before"
      say warn "  verification existed, or by a run that did not verify. To re-stage verified"
      say warn "  bytes, remove s3://$BUCKET/bin/codegraph-server and re-run."
    fi
  else
    # Download once to a temp file, then stage to S3 (same path the local-binary tier uses).
    # The asset must be the ARM aarch64 / glibc>=2.38 build — the host can't run a mismatched
    # arch. Two ways, tried in order (gh also covers a rate-limited/anonymous curl):
    #   1) `gh release download` — uses the operator's authenticated gh token, so it reaches a
    #      private repo's Release asset. Preferred whenever gh is installed + logged in.
    #   2) plain `curl` from $CODEGRAPH_SERVER_URL — works once the repo (or mirror) is public.
    # Either way the bytes land in $CG_TMP, then go to S3. set -e + the -s check catch a
    # failed/partial download.
    CG_TMP="$(mktemp /tmp/codegraph-server.XXXX)"
    # Clean the temp binary on ANY exit from here on (set -e could kill us mid-chmod/cp
    # before the explicit rm below). The trap is cleared right after the rm so it doesn't
    # outlive this block.
    trap 'rm -f "$CG_TMP"' EXIT
    cg_got=false
    cg_via_gh=false
    # An explicit CODEGRAPH_SERVER_URL must be honoured. The gh tier used to run first and never
    # looked at it, so an operator pointing at their own audited build got upstream's asset staged
    # instead — while the digest was still fetched from THEIR url, which then either 404s (staging
    # unverified bytes) or mismatches (a failure blaming the wrong thing).
    if [[ -z "${CODEGRAPH_SERVER_URL:-}" ]] \
       && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      say info "codegraph-server not local or in S3 — downloading via gh from $CODEGRAPH_SERVER_REPO ($CODEGRAPH_SERVER_TAG)"
      if run gh release download "$CODEGRAPH_SERVER_TAG" --repo "$CODEGRAPH_SERVER_REPO" \
           --pattern "$CODEGRAPH_SERVER_ASSET" --output "$CG_TMP" --clobber && [[ -s "$CG_TMP" ]]; then
        cg_got=true; cg_via_gh=true
      fi
    fi
    if [[ "$cg_got" != true ]]; then
      local_url="${CODEGRAPH_SERVER_URL:-$CODEGRAPH_SERVER_URL_DEFAULT}"
      say info "codegraph-server not local or in S3 — downloading from $local_url"
      if run curl -fsSL "$local_url" -o "$CG_TMP" && [[ -s "$CG_TMP" ]]; then
        cg_got=true
      fi
    fi
    if [[ "$cg_got" == true ]]; then
      # VERIFY THE BYTES. This step did not exist: a 128 MB executable was fetched over the network
      # and then run as root on the index host with nothing checking what arrived. Upstream
      # publishes "<asset>.sha256" beside each asset, so there is no excuse for trusting the
      # transfer. CODEGRAPH_SERVER_SHA256 lets an operator pin the digest of their OWN build.
      # NOTE: no `is_set` here. It is defined in teardown.sh only, so the first version of this
      # block called a command that does not exist; 127 in an `if` condition does not trip set -e,
      # the else branch ran every time, and sha256sum was never executed on any path.
      cg_want=""; cg_src=""
      if [[ -n "${CODEGRAPH_SERVER_SHA256:-}" ]]; then
        # An explicitly pinned digest is the most trustworthy input there is, so a malformed one is
        # a configuration error — never a reason to downgrade to "no digest". `None` in particular
        # is what a templating layer renders for a null, and treating it as absent turned the
        # operator's own pin into silence.
        cg_want="$(printf '%s' "$CODEGRAPH_SERVER_SHA256" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
        if [[ ! "$cg_want" =~ ^[0-9a-f]{64}$ ]]; then
          rm -f "$CG_TMP"; trap - EXIT
          say err "CODEGRAPH_SERVER_SHA256 is not a 64-hex sha256 digest: '$CODEGRAPH_SERVER_SHA256'"
          exit 1
        fi
        cg_src="CODEGRAPH_SERVER_SHA256"
      else
        cg_raw=""
        if [[ "$cg_via_gh" == true ]]; then
          # Take the digest from the SAME source as the bytes. Fetching it with anonymous curl
          # could never work on the private/rate-limited repos this tier exists for.
          cg_sum_tmp="$(mktemp /tmp/codegraph-server.sha256.XXXX)"
          if gh release download "$CODEGRAPH_SERVER_TAG" --repo "$CODEGRAPH_SERVER_REPO" \
               --pattern "${CODEGRAPH_SERVER_ASSET}.sha256" --output "$cg_sum_tmp" --clobber \
               >/dev/null 2>&1; then
            cg_raw="$(cat "$cg_sum_tmp")"
          fi
          rm -f "$cg_sum_tmp"
          cg_src="gh ${CODEGRAPH_SERVER_ASSET}.sha256"
        else
          cg_asset_url="${CODEGRAPH_SERVER_URL:-$CODEGRAPH_SERVER_URL_DEFAULT}"
          case "$cg_asset_url" in
            *\?*)
              # Appending .sha256 to a signed URL lands after the signature: wrong path AND a
              # broken signature. A presigned URL cannot have a sibling digest.
              say warn "CODEGRAPH_SERVER_URL carries a query string (presigned?) — a sibling"
              say warn "  .sha256 cannot be derived. Pin CODEGRAPH_SERVER_SHA256 instead." ;;
            *)
              cg_sum_url="${cg_asset_url}.sha256"; cg_src="$cg_sum_url"
              cg_raw="$(curl -fsSL --max-time 60 "$cg_sum_url" 2>/dev/null || true)" ;;
          esac
        fi
        # Normalise: drop CR (a CRLF digest produced a MISMATCH whose two printed lines were
        # character-identical), and EXTRACT the 64-hex token instead of taking field 1 — that way
        # `SHA256 (asset) = <digest>`, a reversed field order, and an HTML error page served with
        # 200 are distinguishable from a genuine mismatch.
        cg_want="$(printf '%s' "$cg_raw" | tr -d '\r' | grep -oiE '[0-9a-fA-F]{64}' \
                   | head -n 1 | tr 'A-F' 'a-f' || true)"
        if [[ -n "$cg_raw" && -z "$cg_want" ]]; then
          rm -f "$CG_TMP"; trap - EXIT
          say err "fetched $cg_src but could not parse a sha256 digest out of it."
          say err "  An HTML error page or an unexpected format — refusing to stage."
          exit 1
        fi
      fi
      if [[ -n "$cg_want" ]]; then
        cg_have="$(sha256sum "$CG_TMP" | awk '{print $1}')"
        if [[ "$cg_have" != "$cg_want" ]]; then
          rm -f "$CG_TMP"; trap - EXIT
          say err "codegraph-server checksum MISMATCH — refusing to stage it."
          say err "  expected $cg_want   (source: $cg_src)"
          say err "  got      $cg_have"
          say err "  The binary runs as root on the index host, so a bad or tampered download must"
          say err "  not proceed. Re-run to retry, or set CODEGRAPH_SERVER_SHA256 for your own build."
          exit 1
        fi
        say ok "codegraph-server checksum verified (sha256 ${cg_have:0:16}…, via $cg_src)"
      elif [[ "${CODEGRAPH_SERVER_ALLOW_UNVERIFIED:-0}" == "1" ]]; then
        say warn "CODEGRAPH_SERVER_ALLOW_UNVERIFIED=1 — staging UNVERIFIED bytes at your own risk."
      else
        # FAIL CLOSED. Upstream publishes a .sha256 beside every asset, so "could not obtain the
        # digest" means a network fault or someone interfering; a downgrade-to-unverified path is
        # exactly what an attacker who can drop one request would use.
        rm -f "$CG_TMP"; trap - EXIT
        say err "could not obtain a sha256 for codegraph-server (${cg_src:-no source}) —"
        say err "  refusing to stage unverified bytes. It runs as root on the index host."
        say err "  Set CODEGRAPH_SERVER_SHA256=<digest>, or if your mirror genuinely publishes no"
        say err "  digest, re-run with CODEGRAPH_SERVER_ALLOW_UNVERIFIED=1 to accept the risk."
        exit 1
      fi
      chmod +x "$CG_TMP"
      # Stamp what was verified, so the reuse tier can tell verified bytes from unverified ones.
      if [[ -n "${cg_want:-}" ]]; then
        run aws s3 cp "$CG_TMP" "s3://$BUCKET/bin/codegraph-server" --region "$REGION" \
          --metadata "sha256=$cg_want"
      else
        run aws s3 cp "$CG_TMP" "s3://$BUCKET/bin/codegraph-server" --region "$REGION"
      fi
      rm -f "$CG_TMP"; trap - EXIT
    else
      rm -f "$CG_TMP"; trap - EXIT
      say err "codegraph-server not found locally / in S3, and the download failed (gh + curl)."
      say err "  This sample does not redistribute the engine. Two ways forward:"
      say err "  1) Download the published build for this arch:"
      # Deliberately one line: split across two `say err` calls each gets the ✗ prefix, so a
      # copy-paste yields a backslash immediately followed by ✗ and bash rejects it.
      say err "       gh release download $CODEGRAPH_SERVER_TAG --repo $CODEGRAPH_SERVER_REPO --pattern $CODEGRAPH_SERVER_ASSET"
      say err "     then: chmod +x $CODEGRAPH_SERVER_ASSET && export CODEGRAPH_SERVER_BIN=\$PWD/$CODEGRAPH_SERVER_ASSET"
      say err "  2) Build it from source (Apache-2.0, needs Rust stable):"
      say err "       git clone https://github.com/$CODEGRAPH_SERVER_REPO && cd \"\$(basename $CODEGRAPH_SERVER_REPO)\""
      say err "       cargo build --release -p codegraph-server"
      say err "       export CODEGRAPH_SERVER_BIN=\$PWD/target/release/codegraph-server"
      say err "     Build on ARM aarch64 (or cross-compile to it) — the index host cannot run x86_64."
      say err "  See index-service/README.md \"Obtaining codegraph-server\" for the full notes."
      # Unconditional: --dry-run never reaches this block (the dry-run elif returns earlier), so the
      # old `[[ "$DRY_RUN" == true ]] ||` was dead and implied a dry-run path that does not exist.
      exit 1
    fi
  fi
  # --- codegraph-acquire:end ---

  # index-service code (bridge + persistent session + path align + perf, etc).
  # Package ALL top-level *.py + requirements.txt — NOT a hand-maintained file
  # list. codegraph_session.py imports perf.py at module load, so an omitted
  # module would crash the bridge on import on a fresh instance (health gate then
  # times out). Globbing every .py makes new modules ship automatically; tests/
  # live in a subdir and are excluded by the top-level-only glob.
  # mktemp template: the X's must be at the END (BSD/macOS mktemp rejects a suffix
  # after them — GNU tolerates it). The local temp name is cosmetic (content goes to a
  # fixed S3 key), so no .tar.gz suffix is needed on it.
  TMP_IDX="$(mktemp /tmp/index-service.XXXXXX)"
  # Stage the index-service top-level .py + requirements.txt PLUS the shared manifest
  # parser (scripts/lib/render_manifest.py) into one dir, so bootstrap.sh on the instance
  # can validate + iterate REPO_MANIFEST_JSON with the SAME parser the deploy/tests use
  # (no duplicated validation logic on the host). tests/ live in a subdir and are excluded
  # by the top-level-only copy.
  # DETERMINISTIC archive: pin sort order, mtime, and owner, and `gzip -n` (no name/
  # timestamp in the gzip header). Otherwise the tarball's bytes — hence its S3 ETag —
  # change on every run even when content is identical, which makes the index-host
  # ArtifactSig staleness check (provision_index_service.sh) ALWAYS report stale and
  # makes the index host look out-of-date every run for no reason (cross-review HIGH).
  IDX_STAGE="$(mktemp -d /tmp/idx-stage.XXXX)"
  # Ship the top-level *.py AND *.sh (git_fetch.sh + activate_project.sh — the host runs them to
  # clone repos + attach projects) + requirements.txt + the shared manifest parser. tests/ live in
  # a subdir and are excluded by the top-level-only copy.
  cp "$ROOT"/index-service/*.py "$ROOT"/index-service/*.sh "$ROOT"/index-service/requirements.txt "$IDX_STAGE"/
  cp "$ROOT"/scripts/lib/render_manifest.py "$IDX_STAGE"/
  cp "$ROOT"/agent-container/openai_backend.py "$ROOT"/agent-container/bedrock_converse.py "$ROOT"/index-service/glossary-requirements.lock "$IDX_STAGE"/
  ( cd "$IDX_STAGE" && det_tar ./*.py ./*.sh requirements.txt glossary-requirements.lock | gzip -n > "$TMP_IDX" )
  rm -rf "$IDX_STAGE"
  run aws s3 cp "$TMP_IDX" "s3://$BUCKET/index-service.tar.gz" --region "$REGION"

  # NO repo staging: repos are git-cloned on the index host (R1) by activate_project.sh, not
  # tarred from the deploy machine. The deploy stages only the codegraph binary + index-service
  # code (above) + bot-gateway source (below).

  # bot-gateway source (built ON the index host, not here): ship src + the
  # package manifests + tsconfig, NOT node_modules/dist (the host runs
  # `npm ci --omit=dev` then `npm run build`). package-lock.json is REQUIRED for
  # `npm ci` (it hard-fails without a lockfile), so a missing lock is a hard
  # error here rather than a confusing bootstrap failure minutes later.
  if [[ ! -f "$ROOT/bot-gateway/package-lock.json" ]]; then
    say err "bot-gateway/package-lock.json missing — required for reproducible 'npm ci' on the index host."
    [[ "$DRY_RUN" == true ]] || exit 1
  fi
  TMP_GW="$(mktemp /tmp/bot-gateway.XXXXXX)"  # X's at end (BSD-safe); name is cosmetic
  # Deterministic (see above): keeps the gateway tarball's ETag stable across reruns
  # when its source is unchanged, so the ArtifactSig staleness check is meaningful.
  # Bundle the repo's config/ INTO the tarball under a top-level `config/`: the gateway
  # resolves card copy at __dirname/../../config/i18n.json = /opt/config on the host, so
  # bootstrap extracts this config/ to /opt/config. Staged from a temp dir that holds both
  # bot-gateway/* and config/ so the archive has the right top-level layout.
  GW_STAGE="$(mktemp -d /tmp/gw-stage.XXXX)"
  cp -r "$ROOT/bot-gateway/src" "$ROOT/bot-gateway/tsconfig.json" "$ROOT/bot-gateway/package.json" \
        "$ROOT/bot-gateway/package-lock.json" "$ROOT/bot-gateway/run.sh" "$GW_STAGE"/
  cp -r "$ROOT/config" "$GW_STAGE/config"
  ( cd "$GW_STAGE" && det_tar src tsconfig.json package.json package-lock.json run.sh config | gzip -n > "$TMP_GW" )
  rm -rf "$GW_STAGE"
  run aws s3 cp "$TMP_GW" "s3://$BUCKET/bot-gateway.tar.gz" --region "$REGION"
  say ok "artifacts staged"
fi

# ============================================================
# Phase 1b: IAM (instance profile + runtime role) — fresh-account safe
# ============================================================
if skip iam; then say warn "skip iam"; else
  # --local note: the EC2's instance role (pre-created via scripts/lib/create-iam.sh) carries
  # IAM-write perms, so this phase runs the same as the default path — provision_iam.sh creates the
  # AgentCore runtime role and (re)asserts the index role's runtime policies (idempotent).
  say step "Phase 1b: IAM"
  run "$SCRIPT_DIR/lib/provision_iam.sh" "$REGION" "$CONFIG_FILE" "$BUCKET"
  safe_source_env "$CONFIG_FILE"
fi

# ============================================================
# Phase 2: network (VPC/subnets/IGW/NAT — fully idempotent, reconciles by tag)
# ============================================================
if [[ "$LOCAL_MODE" == true ]]; then
  say step "Phase 2: network (local mode — reuse this host's VPC/subnet, no VPC/NAT created)"
  # In local mode we don't create a VPC/NAT. VPC_ID/PRIVATE_SUBNET are derived inside the index-svc
  # phase (provision_index_service.sh reads them from this instance via describe-instances) and
  # written to deploy-config; Phase 5 picks them up after the safe_source_env below the Phase 3 call.
  say info "local mode: VPC/subnet derived from this instance in the index-svc phase"
elif skip network; then say warn "skip network"; else
  say step "Phase 2: network"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] provision_network.sh (VPC/subnets/IGW/NAT/NACL + ECR & S3 VPC endpoints) — discovers + reconciles by tag"
    if [[ "${DEPLOY_VPC_ENDPOINTS:-true}" == "true" ]]; then
      say info "[dry-run]   ecr.api + ecr.dkr interface endpoints and an s3 gateway endpoint (image pulls stay inside the VPC)"
      say info "[dry-run]   the two interface endpoints bill per hour per AZ — set DEPLOY_VPC_ENDPOINTS=false to skip them"
    else
      say warn "[dry-run]   DEPLOY_VPC_ENDPOINTS=false — image pulls will cross the NAT to the public internet"
    fi
  else
    # ALWAYS run the provisioner — never short-circuit on a non-empty VPC_ID. A prior
    # run that died MID-network (e.g. NAT wait timed out, EIP quota) writes VPC_ID
    # early but leaves PRIVATE_SUBNET/NAT_GATEWAY unset; skipping on VPC_ID alone left
    # the network half-built forever and Phase 5 then failed on `PRIVATE_SUBNET:?`
    # (cross-review CONFIRMED). provision_network.sh discovers every resource by tag
    # and reconciles (describe-or-create per resource), so re-running is cheap and
    # completes a partial network instead of defeating that inner idempotency.
    "$SCRIPT_DIR/lib/provision_network.sh" "$REGION" "$CONFIG_FILE"
    safe_source_env "$CONFIG_FILE"
  fi
fi

# ============================================================
# Phase 3: index-service EC2 (ARM, Ubuntu 24.04, bootstrap.sh)
# ============================================================
if skip index-svc; then say warn "skip index-svc"; elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 3: index-service EC2"
  say info "[dry-run]   instance_type=$INSTANCE_TYPE  AMI=Ubuntu 24.04 ARM64 (resolved at provision time)"
  say info "[dry-run]   subnet=${PRIVATE_SUBNET:-<from Phase 2>}  region=$REGION"
  say info "[dry-run]   root_volume=${ROOT_VOLUME_GB}GiB  max_files=$MAX_FILES  model=$MODEL"
  # The host is never replaced any more, so spell out what "reuse" now MUTATES. The old line
  # ("reuse if running") predates in-place updates and understated the blast radius: on a
  # signature mismatch this phase re-runs bootstrap.sh on a LIVE host.
  if [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    say info "[dry-run] REUSE base host ${INDEX_SERVICE_INSTANCE} — updated IN PLACE, never replaced:"
    say info "[dry-run]   • if the staged S3 artifacts differ from the host's ArtifactSig tag →"
    say info "[dry-run]     re-run bootstrap.sh on it over SSM: rewrites /etc/index-service.env,"
    say info "[dry-run]     /opt/idx/app and /opt/bot-gateway on a RUNNING host (mutating)"
    say info "[dry-run]   • if they match → no host-side change at all"
    say info "[dry-run]   a re-bootstrap stops and restarts active gateways and bridges (minutes of downtime)"
  else
    say info "[dry-run] LAUNCH a new base host (no INDEX_SERVICE_INSTANCE recorded yet) + bootstrap"
    say info "[dry-run]   via user-data, then wait for the BOOTSTRAP_DONE marker over SSM"
  fi
  # CONTRACT NOTE for provision_index_service.sh (owned elsewhere — not edited from here): to print
  # the EXACT verdict ("will re-bootstrap in place on <iid>" vs "no change") this phase needs that
  # script to expose its ArtifactSig comparison side-effect-free — e.g. honour ST_DRY_RUN=true by
  # computing the signature, printing `PLAN=rebootstrap|noop <iid>` on stdout and exiting 0 before
  # any mutating call. Until it does, dry-run enumerates the two possible actions rather than
  # guessing. Recomputing the signature here is deliberately NOT done: it would drift the moment
  # the signature gains a component (e.g. bootstrap.sh's own ETag).
else
  say step "Phase 3: index-service EC2 (BASE host — no project bound)"
  if [[ "$GLOSSARY_SETTINGS_CHANGED" == true && -f "$PROJECTS_CFG" ]]; then
    _pending_projects="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["projects"]))' "$PROJECTS_CFG")"
    update_env "$CONFIG_FILE" DEPLOY_GLOSSARY_PENDING_PROJECTS "$_pending_projects"
  fi
  # Remember whether a base host already existed BEFORE this run: the provisioner reuses and updates
  # it in place, and only writes a different INDEX_SERVICE_INSTANCE when it genuinely launched one.
  # That comparison is the only signal deploy-all needs, and it needs no cooperation from
  # provision_index_service.sh (whose stdout stays the IP alone).
  INDEX_IID_BEFORE="${INDEX_SERVICE_INSTANCE:-}"
  INDEX_IP="$(ST_LOCAL_MODE="$LOCAL_MODE" ST_GLOSSARY_ENABLED="$WITH_GLOSSARY" "$SCRIPT_DIR/lib/provision_index_service.sh" \
    "$REGION" "$CONFIG_FILE" "$BUCKET" "$MAX_FILES" "$INSTANCE_TYPE" "$ROOT_VOLUME_GB" "$GLOSSARY_MODEL" "$GLOSSARY_MAX_FILES")"
  update_env "$CONFIG_FILE" INDEX_SERVICE_IP "$INDEX_IP"
  safe_source_env "$CONFIG_FILE"
  REUSED_INDEX_HOST=false
  if [[ -n "$INDEX_IID_BEFORE" && "$INDEX_IID_BEFORE" == "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    REUSED_INDEX_HOST=true
  fi
  # STABLE ENDPOINT: the agent reaches the index host through a Route53 private DNS name, never the
  # raw IP, so the runtime's CODEGRAPH_MCP_URL survives a hand-replacement of the host (AgentCore's
  # warm microVMs cache the env for 30+ min and would otherwise hold a stale IP).
  #
  # On the REUSED path the record already points at this IP and cannot change, so write it BEFORE the
  # bootstrap gate. Waiting first was a blue-green leftover — the record had to move to a NEW
  # instance only once it was healthy. Kept that way, a first-deploy gate failure aborted before the
  # A record was ever written, leaving an instance with no index.<region>.source-truth.internal, and
  # the re-run had to clear the same gate before DNS existed. For a genuinely FRESH launch the wait
  # still comes first: that IP is new and must be healthy before it is published.
  INDEX_DNS_DONE=false
  if [[ "$REUSED_INDEX_HOST" == true && -n "${VPC_ID:-}" ]]; then
    "$SCRIPT_DIR/lib/provision_index_dns.sh" "$REGION" "$CONFIG_FILE" "$VPC_ID" "$INDEX_IP" >/dev/null
    safe_source_env "$CONFIG_FILE"
    INDEX_DNS_DONE=true
  fi
  # Wait for the BASE host bootstrap to finish before attaching any project. The base host
  # has NO bridge yet (projects attach later via deploy_project.sh), so we wait for SSM-online
  # + the BOOTSTRAP_DONE marker, NOT a bridge /health (per-project bridge health is gated inside
  # deploy_project.sh after activation). The instance is private, so we poll via SSM.
  if [[ "$LOCAL_MODE" == true ]]; then
    # bootstrap ran synchronously inside the provisioner (local mode); just confirm its done-marker.
    # The log is written by root via sudo, so read it with sudo.
    sudo grep -q BOOTSTRAP_DONE /var/log/index-svc-bootstrap.log 2>/dev/null \
      || { say err "local-mode bootstrap did not finish (no BOOTSTRAP_DONE) — sudo tail /var/log/index-svc-bootstrap.log"; exit 1; }
    say ok "local-mode base host bootstrap confirmed"
  elif [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    say info "waiting for base-host bootstrap (apt + codegraph bin + gateway build, ~3-8 min) ..."
    # Hard-fail: never attach a project to an unconfirmed base host. Re-run after fixing.
    "$SCRIPT_DIR/lib/wait_base_host.sh" "$REGION" "$INDEX_SERVICE_INSTANCE" || {
      say err "index base host never finished bootstrap — aborting before attaching projects."
      say err "  inspect: aws ssm start-session --target $INDEX_SERVICE_INSTANCE ; tail /var/log/index-svc-bootstrap.log"
      exit 1
    }
  fi
  # STABLE ENDPOINT (fresh-launch path): publish the record only now that the new host is healthy.
  # Already done above for a reused host, so this is skipped there rather than repeated.
  if [[ "$INDEX_DNS_DONE" != true ]]; then
    "$SCRIPT_DIR/lib/provision_index_dns.sh" "$REGION" "$CONFIG_FILE" "$VPC_ID" "$INDEX_IP" >/dev/null
    safe_source_env "$CONFIG_FILE"
  fi
  say ok "index-service at $INDEX_IP:8080 (stable name: ${INDEX_DNS_NAME:-pending})"
fi
# The host now carries the glossary state these switches describe — persist them here,
# not before provisioning, so a failed Phase 3 leaves the previous values in deploy-config. Not when
# Phase 3 was skipped either: the host did not change, and recording the new value would make
# install.sh's redeploy think no re-bootstrap is needed.
if [[ "$DRY_RUN" != true ]] && ! skip index-svc; then
  update_env "$CONFIG_FILE" DEPLOY_GLOSSARY_MAX_FILES "$GLOSSARY_MAX_FILES"
  update_env "$CONFIG_FILE" DEPLOY_WITH_GLOSSARY "$WITH_GLOSSARY"
fi

# ============================================================
# Phase 4: build + push the agent-container image (ARM64) to ECR
# ============================================================
# Phase 5 references the image by URI; on a FRESH account that image doesn't
# exist yet, so the one-click deploy must build+push it here (was missing →
# Phase 5 would fail with an image-not-found). Idempotent: ECR repo create-if-
# absent; image tagged :latest (mutable but fine for MVP — pinning tracked in
# requirements/Dockerfile separately).
if skip image; then say warn "skip image"; elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 4: build + push agent image"
  ECR_REPO="source-truth/agent"
  GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  say info "[dry-run] ECR repo: ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
  say info "[dry-run] image tags: :latest  :${GIT_SHA}"
  say info "[dry-run] ECR create-if-absent + docker build --platform linux/arm64 + push (both tags)"
else
  say step "Phase 4: build + push agent image"
  require_cmd docker "install Docker (buildx, ARM64 capable)" || exit 1
  # The agent image is ARM64-only. On an x86_64 host without arm64 emulation, the
  # build silently produces an unusable image that Phase 5 then consumes. Fail LOUD
  # ARM64 build capability is verified in preflight_docker (Phase 0) — before any billable
  # resource exists — so there is no gate here.
  ECR_REPO="source-truth/agent"
  GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
  ECR_BASE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
  ECR_URI_LATEST="${ECR_BASE}:latest"
  ECR_URI_SHA="${ECR_BASE}:${GIT_SHA}"
  aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" >/dev/null
  # ECR login must SUCCEED before build/push. Don't swallow it with `>/dev/null 2>&1`:
  # on a fresh account a login failure (clock skew, missing ecr:GetAuthorizationToken on
  # the deploy identity, a region typo, an expired token) would otherwise surface only as
  # an opaque `docker push` denied error one step later. Check the PIPELINE status
  # (set -o pipefail makes a failed get-login-password / docker login fail the pipe) and
  # surface stderr with an actionable message (cross-review MEDIUM: diagnosability).
  if ! aws ecr get-login-password --region "$REGION" \
       | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null; then
    say err "ECR docker login failed for ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
    say err "check: deploy identity has ecr:GetAuthorizationToken; clock is in sync; region/account correct; docker daemon running."
    exit 1
  fi
  docker build --platform linux/arm64 -t "$ECR_URI_LATEST" "$ROOT/agent-container"
  # Content-addressable tagging: tag with git SHA for deterministic rollback via --image-digest
  docker tag "$ECR_URI_LATEST" "$ECR_URI_SHA"
  docker push "$ECR_URI_LATEST"
  docker push "$ECR_URI_SHA"
  # Compute and persist the image digest for rollback support
  DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$ECR_URI_LATEST" 2>/dev/null \
    || docker images --digests --format '{{.Digest}}' "$ECR_URI_LATEST")
  update_env "$CONFIG_FILE" ECR_IMAGE "$ECR_URI_LATEST"
  update_env "$CONFIG_FILE" ECR_IMAGE_SHA "$ECR_URI_SHA"
  # Enables rollback to a known-good image via --image-digest
  update_env "$CONFIG_FILE" LAST_IMAGE_DIGEST "$DIGEST"
  say ok "image pushed: $ECR_URI_LATEST + $ECR_URI_SHA (digest: ${DIGEST##*@})"
fi

# ============================================================
# Phase 5: per-project deploy (bridge attach + runtime + gateway), looped over .local/projects.json
# ============================================================
# The shared base (network/IAM/EC2/image) is up. Each project is now deployed by deploy_project.sh:
# it ships the project's manifest to the host + runs activate_project.sh (git-clone its repos, build
# graphs, start its bridge on its port), deploys a per-project AgentCore runtime pointed at that
# bridge port, and activates a per-project gateway (its own Feishu app). Idempotent + isolated:
# one project's failure doesn't abort the others.
PROJECTS_DEPLOYED=false   # true only if this run deployed ≥1 project (not a service health check)
_PROBE_FAILED=()          # projects that deployed but failed the smoke probe (deploy_project.sh rc 3)
probe_failed_summary() {  # one line per rc-3 project; printed before BOTH the exit-1 and exit-3 paths
  [[ ${#_PROBE_FAILED[@]} -gt 0 ]] || return 0
  local _p
  for _p in "${_PROBE_FAILED[@]}"; do
    say warn "项目 $_p 已部署，但真实问答验收未通过 / project $_p deployed but did not answer the smoke questions — see runbook §5/§8 (docs/runbook_zh.md §五/§八)"
  done
}
if [[ "$SKIP_PROJECTS" == true ]]; then
  say step "Phase 5: per-project deploy"
  say info "--skip-projects: 本次跳过项目部署 / project deployment skipped in this run."
elif skip projects; then
  say warn "skip per-project phase (--skip projects)"
elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 5: per-project deploy"
  if [[ -f "$PROJECTS_CFG" ]]; then
    _pids="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["projects"]))' "$PROJECTS_CFG" 2>/dev/null || echo "")"
    say info "[dry-run] for each project [${_pids}]: activate_project.sh (clone+build+bridge) + deploy_runtime.py + activate_gateway.sh"
    say info "[dry-run]   model=$MODEL  idle_timeout=${IDLE_TIMEOUT}s  max_lifetime=${MAX_LIFETIME}s"
    say info "[dry-run]   image=${ECR_IMAGE:-<from Phase 4>}  index_host=${INDEX_DNS_NAME:-${INDEX_SERVICE_IP:-<from Phase 3>}}"
  else
    say info "[dry-run] no .local/projects.json — base host only; add a project via ./scripts/install.sh"
  fi
elif [[ ! -f "$PROJECTS_CFG" ]]; then
  say step "Phase 5: per-project deploy"
  say info "no .local/projects.json — project deployment skipped in this run."
else
  say step "Phase 5: per-project deploy"
  # (LOG_HASH_SALT is ensured inside deploy_project.sh — identical describe-or-create there,
  # so it also covers install.sh's direct deploy_project path; no duplicate block here.)
  # FAIL-LOUD parse: `mapfile < <(python3 …)` swallows a python failure into an empty list,
  # which would look like a SUCCESSFUL deploy of zero projects. Validate the file explicitly
  # first (syntax + a 'projects' object) and abort with the real reason on any problem.
  if ! _perr="$(python3 -c '
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"invalid JSON: {e}")
p = cfg.get("projects")
if not isinstance(p, dict):
    sys.exit("missing/invalid \"projects\" object")
' "$PROJECTS_CFG" 2>&1)"; then
    say err "projects.json 解析失败 / failed to parse projects.json: ${_perr} (${PROJECTS_CFG})"
    exit 1
  fi
  # Loop every declared project. deploy_project.sh is idempotent; collect failures but keep going
  # (one project's broken git/Feishu must not block the others), then report at the end.
  # bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
  _PIDS=(); while IFS= read -r _line; do
    if [[ -n "$_line" ]]; then _PIDS+=("$_line"); fi
  done \
    < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["projects"]))' "$PROJECTS_CFG")
  _failed=()
  # Count-guard the bare expansion below: on bash 3.2 (stock macOS) `"${arr[@]}"` on an
  # EMPTY array under `set -u` is an unbound-variable error. An empty project declaration
  # produces no IDs; ignore Python's trailing blank line instead of counting it as a project.
  if [[ ${#_PIDS[@]} -gt 0 ]]; then
  for _pid in "${_PIDS[@]}"; do
    [[ -n "$_pid" ]] || continue
    _prc=0; bash "$SCRIPT_DIR/lib/deploy_project.sh" "$REGION" "$_pid" || _prc=$?
    case "$_prc" in
      0) ;;
      # rc 3 = deployed (bridge + runtime + gateway up) but the smoke probe did not pass. Not a
      # deploy failure: keep going, run Phase 7, and report it accurately at the very end.
      3) say warn "project '$_pid' deployed but did not answer the smoke questions — continuing; see the summary at the end"
         _PROBE_FAILED+=("$_pid") ;;
      *) say warn "project '$_pid' deploy failed (rc $_prc) — continuing with the rest; re-run after fixing"
         _failed+=("$_pid") ;;
    esac
  done
  fi
  if [[ ${#_failed[@]} -gt 0 ]]; then
    say err "per-project deploy: ${#_failed[@]} project(s) failed: ${_failed[*]}"
    say err "  the others are up; fix the cause and re-run ./scripts/deploy-all.sh (idempotent)"
    probe_failed_summary   # a hard failure elsewhere must not hide the rc-3 projects
    exit 1
  fi
  if [[ ${#_PIDS[@]} -gt 0 ]]; then
    if [[ ${#_PROBE_FAILED[@]} -gt 0 ]]; then
      say warn "all ${#_PIDS[@]} project(s) deployed (bridge + runtime + gateway each); smoke failed for: ${_PROBE_FAILED[*]}"
    else
      say ok "all ${#_PIDS[@]} project(s) deployed (bridge + runtime + gateway each)"
    fi
    PROJECTS_DEPLOYED=true
  fi
  update_env "$CONFIG_FILE" DEPLOY_GLOSSARY_PENDING_PROJECTS ""
fi

# ============================================================
# Phase 7: monitoring (CloudWatch metric-filters + dashboards + alarms + DAU lambda)
# ============================================================
# Runs AFTER the gateway phase so the gateway has (begun to) log to /source-truth/bot-gateway
# — the metric-filters target that group. BEST-EFFORT: the backend + gateway are already up by
# here, so a monitoring hiccup must WARN, never fail the deploy. apply-monitoring.sh runs all
# stages idempotently and is itself per-stage best-effort; re-running the deploy reconciles.
# Skipped on --dry-run, --skip monitoring, and when no project was deployed this run.
# Existing gateways and log groups may still be active when the project phase is skipped.
#
# EXACT fresh-deploy behavior when the gateway hasn't written its FIRST log line yet (so the
# log group doesn't exist): dashboards PUT FINE (no data dependency); the metric-filters stage
# FAILS (put-metric-filter errors on the missing group) and is warned; the alarms stage
# ABORTS before creating the SNS topic or any alarm (it applies its backing filters first and
# bails on their failure) → so a fresh one-click deploy creates NO alarms yet; the DAU-lambda
# stage SUCCEEDS (role/function/schedule don't need the group; only its scheduled query is idle
# until logs accrue). A deploy RE-RUN after the gateway has logged once creates the filters +
# alarms (idempotent) — that re-run is how alarm coverage is established. The runbook's manual
# path (./scripts/apply-monitoring.sh) is the same reconcile.
if skip monitoring; then
  say warn "skip monitoring"
elif [[ "$WITH_MONITORING" != true ]]; then
  say info "monitoring off (opt-in): pass --with-monitoring, or later run ./scripts/apply-monitoring.sh --region $REGION"
elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 7: monitoring"
  say info "[dry-run] apply-monitoring.sh: metric-filters + dashboards + alarms + DAU lambda (CloudWatch, best-effort)"
elif [[ "$SKIP_PROJECTS" == true ]]; then
  # install.sh calls us with --skip-projects, then deploys the project and applies monitoring itself.
  say info "monitoring is applied after the project deploy (install.sh does this; or run ./scripts/apply-monitoring.sh --region $REGION)"
elif [[ "$PROJECTS_DEPLOYED" != true ]]; then
  # Automatic monitoring follows project deployment in this run; existing service health
  # and log-group availability are not inferred from this flag.
  say info "skip monitoring (no project deployed in this run); run ./scripts/apply-monitoring.sh --region $REGION to apply it separately."
else
  say step "Phase 7: monitoring (best-effort)"
  bash "$SCRIPT_DIR/apply-monitoring.sh" --region "$REGION" \
    && say ok "monitoring applied (best-effort; widgets fill once the gateway logs accrue)" \
    || say warn "  some monitoring stages failed (non-fatal) — re-run ./scripts/apply-monitoring.sh --region $REGION"
fi

# VERIFY THE OBSERVABLE END STATE, not the stage exit codes. Phase 7 is skipped entirely unless a
# project deployed, and even when it runs apply-alarms can abort before creating anything because
# its backing metric-filters fail while the log group does not yet exist. Both paths previously
# ended with `deploy-all complete` and a warn line the operator was expected to notice — which is
# how a whole class of first-time deploys ended up with NO alarms at all while reporting success.
# Ask CloudWatch what actually exists instead. Only meaningful when monitoring is on.
if [[ "$DRY_RUN" != true && "$WITH_MONITORING" == true && "$PROJECTS_DEPLOYED" == true ]]; then
  _want_alarms="$(python3 -c 'import json;print(len(json.load(open("config/alarm-thresholds.json"))["alarms"]))' 2>/dev/null || echo 0)"
  _have_alarms="$(aws cloudwatch describe-alarms --region "$REGION" \
    --alarm-name-prefix source-truth --query 'length(MetricAlarms)' --output text 2>/dev/null || echo 0)"
  case "$_have_alarms" in ''|*[!0-9]*) _have_alarms=0 ;; esac
  if [[ "$_have_alarms" -lt "$_want_alarms" ]]; then
    say warn "ALARMS INCOMPLETE: $_have_alarms of $_want_alarms source-truth alarms exist in $REGION."
    say warn "  Nothing (or not everything) will page you. The usual cause on a FIRST deploy is that"
    say warn "  the gateway log group did not exist yet when the metric-filters were applied."
    say warn "  Re-run once the gateway has logged:  ./scripts/apply-monitoring.sh --region $REGION"
  else
    say ok "alarms verified: $_have_alarms/$_want_alarms present in $REGION"
  fi
fi

say ok "deploy-all complete"

# Exit codes: 0 = everything up and the smoke probe passed (or was skipped); 3 = every project is
# deployed but ≥1 did not answer the smoke questions (same code deploy_project.sh uses); 1 = a deploy
# step failed (exited above); 2 = usage.
if [[ ${#_PROBE_FAILED[@]} -gt 0 ]]; then
  probe_failed_summary
  exit 3
fi

if [[ "$DRY_RUN" != true && "$PROJECTS_DEPLOYED" != true ]]; then
  say info "本次未部署项目 / No projects were deployed in this run."
  _configured_projects="$(python3 - "$PROJECTS_CFG" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
print(" ".join(json.loads(path.read_text())["projects"]) if path.is_file() else "")
PY
)"
  if [[ -n "$_configured_projects" ]]; then
    say info "已配置项目 / Configured projects: $_configured_projects"
    say info "  运行状态需在 index 主机检查 / verify service health on the index host:"
    say info "  bridge /health、gateway /ready；端口与步骤见 docs/runbook_zh.md §五 / docs/runbook_en.md §5."
  else
    say info "本地清单没有配置项目 / No projects configured in .local/projects.json."
    say info "  Run ./scripts/install.sh → 'add a project' to configure and deploy a project."
  fi
fi
