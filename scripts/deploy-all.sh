#!/usr/bin/env bash
# deploy-all.sh — one-click, idempotent, region/account-agnostic deploy of the
# full source-truth backend: S3 artifacts → VPC/index-service EC2 →
# AgentCore runtime (VPC + CodeGraph MCP).
#
# Everything is parameterized — no hardcoded account/region/resource IDs — so a
# fresh AWS account in any region works:
#
#   ./scripts/deploy-all.sh --region ap-northeast-1 --repo /path/to/code-5x
#
# Idempotent: every resource is "describe-or-create". Re-running reconciles.
# State persists to .local/deploy-config (gitignored); later runs read it back.
#
# Phases (numbers match the operator-visible `say step "Phase N"` labels; --skip <name>):
#   1  artifacts  : build/stage codegraph-server bin + index-service code + repo → S3
#   1b iam        : execution + index-service instance roles/policies (describe-or-create)
#   2  network    : VPC, public+private subnet, IGW, NAT, route tables (or reuse)
#   3  index-svc  : security groups + ARM EC2 (Ubuntu 24.04) running bootstrap.sh
#   4  image      : build the agent container (ARM64) and push to ECR
#   5  runtime    : AgentCore runtime in VPC mode, CODEGRAPH_MCP_URL set
#   6  gateway    : write /etc/bot-gateway.env + start bot-gateway.service (co-located
#                   on the index host) via SSM — once the runtime ARN exists
#   7  monitoring : CloudWatch metric-filters + dashboards + alarms + DAU lambda
#                   (best-effort, after the gateway logs to /source-truth/bot-gateway)
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
mkdir -p "$CONFIG_DIR"

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
DEFAULT_GLOSSARY_MAX_FILES="400"   # cc scans this many files per glossary build; 0 = no cap (whole repo)
DEFAULT_MODEL="global.anthropic.claude-opus-4-8"
DEFAULT_ROOT_VOLUME_GB="30"
# Idle timeout default = AWS's own default (900s/15min). The gateway derives its
# session-reuse TTL from this exact value (persisted to deploy-config), so "warm
# enough to reuse" on the gateway and "still alive" on AgentCore mean the same
# thing. Cost: AgentCore bills idle MEMORY (not idle CPU), so raising this trades
# follow-up warm-hit rate for idle-memory spend — tune per workload.
DEFAULT_IDLE_TIMEOUT="900"
DEFAULT_MAX_LIFETIME="28800"
# Where to fetch codegraph-server when it's neither local nor already in S3 (the
# fresh-machine / one-line-installer path). Must serve the ARM aarch64 / glibc>=2.38
# 0.18.5 build. Two routes: `gh release download` (works for a PRIVATE repo via the
# operator's gh auth — preferred) then a plain-curl URL (works once public / a mirror).
CODEGRAPH_SERVER_REPO="${CODEGRAPH_SERVER_REPO:-ddpie/source-truth}"
CODEGRAPH_SERVER_TAG="${CODEGRAPH_SERVER_TAG:-codegraph-server-v0.18.5}"
CODEGRAPH_SERVER_URL_DEFAULT="https://github.com/${CODEGRAPH_SERVER_REPO}/releases/download/${CODEGRAPH_SERVER_TAG}/codegraph-server"
REFRESH_INDEX=false       # --refresh-index: replace a running index instance if its artifacts are stale
declare -A SKIP=()

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
  --glossary-max-files <n>  term-glossary build file cap per repo (default: 400; 0 = no cap)
  --root-volume-gb <n> index host root EBS size in GiB (default: 30). Grow for large repos:
                      it holds every project's repo clones + graph.db.
  --model <id>        default Bedrock model id (a project may override it in projects.json)
  --idle-timeout <s>  AgentCore session idle timeout, seconds (60..28800; default 900/15min).
                      The gateway's session-reuse TTL is aligned to this.
  --max-lifetime <s>  AgentCore microVM hard max age before forced recycle (60..28800; default 28800/8h)
  --skip <phase>      Skip a phase: artifacts|iam|network|index-svc|image|runtime|gateway|monitoring (repeatable)
  --refresh-index     Replace the index host if this run staged newer BASE code (bridge/gateway).
                      Repo code is NOT a reason to refresh — repos refresh live via git pull.
  --dry-run           Print the plan and resolved IDs, make no changes
  -h, --help

PREREQUISITES (not auto-provisioned — the deploy hard-fails / WARNs if missing):
  • codegraph-server binary (ARM aarch64, glibc>=2.38, pinned 0.18.5) on PATH or via
    CODEGRAPH_SERVER_BIN. If absent locally and not yet in S3, it is downloaded from
    CODEGRAPH_SERVER_URL (default: this repo's Release asset) — so a fresh machine works.
  • A host that can build linux/arm64 images (arm64 host, or x86 + binfmt).
  • Bedrock model access for the model, and AgentCore available in --region (probed, WARN).
  • A read-only git credential in Secrets Manager (source-truth/git-credentials) for cloning
    private repos — install.sh's "add a project" creates it; or create it by hand.
  • Per-project Feishu app secrets (source-truth/feishu-<projectId>) — install.sh creates these.
EOF
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --skip-projects) SKIP_PROJECTS=true; shift ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
    --glossary-max-files) GLOSSARY_MAX_FILES="$2"; shift 2 ;;
    --root-volume-gb) ROOT_VOLUME_GB="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --max-lifetime) MAX_LIFETIME="$2"; shift 2 ;;
    --skip) SKIP["$2"]=1; shift 2 ;;
    --refresh-index) REFRESH_INDEX=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "Unknown flag: $1"; usage >&2; exit 2 ;;
  esac
done

# --- preflight ---
say step "Phase 0: preflight"
require_cmd aws || exit 1
require_cmd python3 || exit 1
safe_source_env "$CONFIG_FILE"
REGION="${REGION:-${DEPLOY_REGION:-}}"
[[ -n "$REGION" ]] || { say err "--region required"; exit 2; }
# Resolve flag > persisted > default for the operator-tunable knobs, so a flagless
# reconcile re-run keeps the earlier choice instead of reverting to the default
# (which would flip the live runtime's model via the in-place update).
MODEL="${MODEL:-${DEPLOY_MODEL:-$DEFAULT_MODEL}}"
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
  MODEL="$(resolve_model_for_region "$MODEL" "$REGION")"
  [[ "$MODEL" == "$MODEL_DECLARED" ]] || say info "resolved model for $REGION: $MODEL_DECLARED → $MODEL"
fi
INSTANCE_TYPE="${INSTANCE_TYPE:-${DEPLOY_INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}}"
# Export so provision_network.sh can pick an AZ that actually offers this type
# (Graviton isn't in every AZ of every region) instead of a blind AvailabilityZones[0].
export DEPLOY_INSTANCE_TYPE="$INSTANCE_TYPE"
MAX_FILES="${MAX_FILES:-${DEPLOY_MAX_FILES:-$DEFAULT_MAX_FILES}}"
GLOSSARY_MAX_FILES="${GLOSSARY_MAX_FILES:-${DEPLOY_GLOSSARY_MAX_FILES:-$DEFAULT_GLOSSARY_MAX_FILES}}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-${DEPLOY_ROOT_VOLUME_GB:-$DEFAULT_ROOT_VOLUME_GB}}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-${DEPLOY_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}}"
MAX_LIFETIME="${MAX_LIFETIME:-${DEPLOY_MAX_LIFETIME:-$DEFAULT_MAX_LIFETIME}}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# Repos are NOT a CLI concern any more — they live in .local/projects.json and are git-cloned on
# the index host by activate_project.sh (Phase 5). The deploy stages only the codegraph binary +
# index-service/bot-gateway code to S3 (Phase 1); no repo tarballs.
BUCKET="source-truth-repo-${ACCOUNT}-$(echo "$REGION" | tr -d '-')"
say info "account=$ACCOUNT region=$REGION bucket=$BUCKET model=$MODEL skip_projects=$SKIP_PROJECTS"

# Bedrock invoke preflight. AWS no longer requires per-model "Model access" enablement,
# so a denial here is NOT a console toggle — it's a real config problem: the deploy
# identity lacks bedrock:InvokeModel, or the model-id / inference-profile form isn't
# offered in this region. Deploy still goes READY without invoking the model, so the
# first real question would fail; we probe with a minimal invoke and WARN actionably on
# denial — non-blocking (the probe can fail for unrelated/transient reasons and must never
# block an otherwise-working deploy). Skipped on dry-run.
preflight_model_access() {
  command -v aws >/dev/null || return 0
  local body resp err rc
  body='{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
  resp="$(mktemp)"
  # HARD timeout so a slow/blocked invoke-model can never stall the whole deploy
  # (observed: this call can hang for minutes in some networks). A timeout falls
  # through to the inconclusive→continue branch, never blocks. `timeout` exits 124
  # on expiry; aws cli connect/read timeouts add a second belt. Probe stays best-
  # effort: only a clear AccessDenied WARNs; everything else just continues.
  if err="$(timeout 30 aws bedrock-runtime invoke-model --region "$REGION" --model-id "$MODEL" \
        --cli-connect-timeout 8 --cli-read-timeout 20 \
        --body "$body" --content-type application/json --accept application/json \
        "$resp" 2>&1)"; then
    say ok "bedrock model access OK ($MODEL)"
  else
    rc=$?
    case "$err" in
      *AccessDenied*|*"don't have access"*|*"not authorized"*|*not\ enabled*|*ValidationException*|*"not found"*|*"inference profile"*)
        say warn "Bedrock model '$MODEL' couldn't be invoked in $REGION (an IAM/region/"
        say warn "  inference-profile-form issue — note: AWS no longer requires per-model"
        say warn "  'Model access' enablement, so this is a config problem, not a console toggle)."
        # Suggest a profile that actually exists in THIS region, derived live from
        # Bedrock (not a hardcoded prefix — the geo prefixes are us./eu./jp./au., and
        # many regions only carry global.). resolve_model_for_region already ran before
        # this probe, so if MODEL still doesn't work, surface the region's real options.
        # `|| true`: grep exits 1 on no-match, which under set -e + pipefail would
        # otherwise abort the deploy right where this HELPFUL hint should print.
        avail="$(list_region_profiles "$REGION" 2>/dev/null | grep -F "$(model_basename "$MODEL")" | paste -sd' ' - || true)"
        if [[ -n "$avail" ]]; then
          say warn "  → inference profiles for this model that ARE offered in $REGION:"
          say warn "    $avail"
          say warn "    pass one via --model <id> (or check the deploy identity's bedrock:InvokeModel perms)."
        else
          say warn "  → no inference profile for '$(model_basename "$MODEL")' is offered in $REGION;"
          say warn "    pick a supported region, or verify the model/IAM in this one."
        fi
        say warn "  (Deploy continues; the runtime reaches READY but answers fail with"
        say warn "   AccessDenied/ValidationException until the model is available.)" ;;
      *)
        if [[ "$rc" == 124 ]]; then
          say info "model-access probe timed out (>30s); skipping check and continuing"
        else
          say info "model-access probe inconclusive (non-access error: ${err%%$'\n'*}); continuing"
        fi ;;
    esac
  fi
  rm -f "$resp"
}
# AgentCore is a newer service available only in a SUBSET of regions, and on a
# fresh account first use can need a service-linked role / activation. If it isn't
# reachable in this region, Phase 5 would later abort with a raw boto3 traceback.
# Probe it up-front and WARN actionably (non-blocking, like the model-access probe)
# so the operator learns the region/enablement gap before the long index/build phases.
preflight_agentcore() {
  command -v aws >/dev/null || return 0
  if timeout 20 aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" --max-results 1 >/dev/null 2>&1; then
    say ok "AgentCore reachable in $REGION"
  else
    say warn "AgentCore (bedrock-agentcore-control) not reachable in $REGION via this identity."
    say warn "  → On a NEW account/region, confirm AgentCore is available in $REGION and enabled"
    say warn "    for the account (first use may auto-create a service-linked role). If the region"
    say warn "    doesn't support AgentCore, pick a supported one. Phase 5 will fail until then."
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
  local eips vpcs
  eips="$(aws ec2 describe-addresses --region "$REGION" --query 'length(Addresses)' --output text 2>/dev/null || echo "")"
  vpcs="$(aws ec2 describe-vpcs --region "$REGION" --query 'length(Vpcs)' --output text 2>/dev/null || echo "")"
  # NB: use `if`, NOT `[[ … ]] && say` — under `set -e`, a `[[ … ]] && cmd` whose
  # test is FALSE returns non-zero, and as the LAST statement of the function that
  # non-zero return aborts the whole script (this exact trap silently killed a
  # deploy at Phase 0 when the account had <4 EIPs — the common fresh-account case).
  if [[ "$eips" =~ ^[0-9]+$ && "$eips" -ge 4 ]]; then
    say warn "已有 $eips 个 EIP（默认配额 5）——若 NAT 的 allocate-address 失败，先去 Service Quotas 提额或释放闲置 EIP。"
  fi
  if [[ "$vpcs" =~ ^[0-9]+$ && "$vpcs" -ge 4 ]]; then
    say warn "已有 $vpcs 个 VPC（默认配额 5）——若 create-vpc 失败，先提额或清理。"
  fi
  # vCPU (On-Demand Standard family, quota L-1216C47A): a BRAND-NEW account often caps
  # standard On-Demand vCPUs low (historically as low as 5, sometimes 0 until raised). The
  # index instance is a Standard-family Graviton (t4g.large = 2 vCPU). Without this, a fresh
  # account fails LATE in Phase 3 with a raw VcpuLimitExceeded instead of an early WARN like
  # EIP/VPC. Best-effort: service-quotas may be unavailable/denied → silently skip (return 0).
  local vcpu_quota
  vcpu_quota="$(aws service-quotas get-service-quota --region "$REGION" \
    --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text 2>/dev/null || echo "")"
  # Value comes back like "5.0"; compare the integer part. Only WARN when implausibly low
  # for one t4g.large (need ≥2 vCPU; warn at <4 to leave headroom + flag near-zero caps).
  if [[ "$vcpu_quota" =~ ^([0-9]+) ]]; then
    local vcpu_int="${BASH_REMATCH[1]}"
    if [[ "$vcpu_int" -lt 4 ]]; then
      say warn "On-Demand Standard vCPU 配额仅 ${vcpu_int}（quota L-1216C47A）——index 实例需 2 vCPU（t4g.large）。若 run-instances 报 VcpuLimitExceeded，去 Service Quotas 提额。"
    fi
  fi
  return 0
}
if [[ "$DRY_RUN" != true ]]; then preflight_boto3; preflight_model_access; preflight_agentcore; preflight_quota; fi

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
  update_env "$CONFIG_FILE" DEPLOY_GLOSSARY_MAX_FILES "$GLOSSARY_MAX_FILES"
  update_env "$CONFIG_FILE" DEPLOY_ROOT_VOLUME_GB "$ROOT_VOLUME_GB"
fi

run() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] $*"; else "$@"; fi; }

# det_tar — archive the given paths to stdout, deterministically WHEN POSSIBLE. GNU tar
# (or `gtar`) supports --sort/--mtime/--owner, which pin byte order so the gzipped tarball
# (hence its S3 ETag) is identical across runs with identical content — that's what keeps
# the index-host ArtifactSig staleness check from reporting "stale" every deploy.
# macOS ships BSD tar, which REJECTS those flags (`Option --sort=name is not supported`),
# so we fall back to a plain archive there. Determinism is an OPTIMIZATION, not correctness:
# the fallback works fine, it just may re-stage a byte-different (but content-identical)
# tarball, at worst causing an extra upload / a stale-WARN on reuse. `gzip -n` (no name/
# timestamp in the gzip header) is portable and applied by the caller either way.
# `brew install gnu-tar` on macOS restores full determinism.
det_tar() {  # caller sets cwd; args = files/dirs to include
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - "$@"
  elif command -v gtar >/dev/null 2>&1; then
    gtar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - "$@"
  else
    tar -cf - "$@"
  fi
}
skip() { [[ -n "${SKIP[$1]:-}" ]]; }

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
  # README.md "codegraph-server 二进制来源" for the canonical download). Resolve
  # order: explicit $CODEGRAPH_SERVER_BIN → on PATH → ~/.local/bin. If none is
  # found locally AND the S3 object isn't already staged from a prior run, HARD-
  # FAIL here with an actionable message — do NOT warn-green and let the missing
  # binary surface minutes later as an opaque Phase-4 health timeout (bootstrap
  # `aws s3 cp` of the missing key dies under set -e → index never builds).
  # Resolve order: explicit $CODEGRAPH_SERVER_BIN → on PATH → ~/.local/bin → already
  # in S3 (prior run) → download from $CODEGRAPH_SERVER_URL (the published Release asset,
  # so a fresh machine with no local binary still works — this is what the one-line
  # installer relies on). Only the URL tier is new; the local/S3 tiers are unchanged.
  CG_BIN="${CODEGRAPH_SERVER_BIN:-$(command -v codegraph-server || echo "$HOME/.local/bin/codegraph-server")}"
  if [[ -x "$CG_BIN" ]]; then
    run aws s3 cp "$CG_BIN" "s3://$BUCKET/bin/codegraph-server" --region "$REGION"
  elif aws s3api head-object --bucket "$BUCKET" --key bin/codegraph-server --region "$REGION" >/dev/null 2>&1; then
    say info "codegraph-server not local, but already staged at s3://$BUCKET/bin/codegraph-server (reuse)"
  else
    # Download once to a temp file, then stage to S3 (same path the local-binary tier uses).
    # The asset must be the ARM aarch64 / glibc>=2.38 0.18.5 build — the host can't run a
    # mismatched arch. Two ways, tried in order so a PRIVATE repo works without going public:
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
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      say info "codegraph-server not local or in S3 — downloading via gh from $CODEGRAPH_SERVER_REPO ($CODEGRAPH_SERVER_TAG)"
      if run gh release download "$CODEGRAPH_SERVER_TAG" --repo "$CODEGRAPH_SERVER_REPO" \
           --pattern codegraph-server --output "$CG_TMP" --clobber && [[ -s "$CG_TMP" ]]; then
        cg_got=true
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
      chmod +x "$CG_TMP"
      run aws s3 cp "$CG_TMP" "s3://$BUCKET/bin/codegraph-server" --region "$REGION"
      rm -f "$CG_TMP"; trap - EXIT
    else
      rm -f "$CG_TMP"; trap - EXIT
      say err "codegraph-server not found locally / in S3, and download failed (gh + curl both)."
      say err "  → If the repo is private, run 'gh auth login' so 'gh release download' can reach the asset;"
      say err "    or set CODEGRAPH_SERVER_BIN=/path/to/codegraph-server (ARM aarch64, glibc>=2.38) and re-run."
      [[ "$DRY_RUN" == true ]] || exit 1
    fi
  fi

  # index-service code (bridge + persistent session + path align + perf, etc).
  # Package ALL top-level *.py + requirements.txt — NOT a hand-maintained file
  # list. codegraph_session.py imports perf.py at module load, so an omitted
  # module would crash the bridge on import on a fresh instance (health gate then
  # times out). Globbing every .py makes new modules ship automatically; tests/
  # live in a subdir and are excluded by the top-level-only glob.
  TMP_IDX="$(mktemp /tmp/index-service.XXXX.tar.gz)"
  # Stage the index-service top-level .py + requirements.txt PLUS the shared manifest
  # parser (scripts/lib/render_manifest.py) into one dir, so bootstrap.sh on the instance
  # can validate + iterate REPO_MANIFEST_JSON with the SAME parser the deploy/tests use
  # (no duplicated validation logic on the host). tests/ live in a subdir and are excluded
  # by the top-level-only copy.
  # DETERMINISTIC archive: pin sort order, mtime, and owner, and `gzip -n` (no name/
  # timestamp in the gzip header). Otherwise the tarball's bytes — hence its S3 ETag —
  # change on every run even when content is identical, which makes the index-host
  # ArtifactSig staleness check (provision_index_service.sh) ALWAYS report stale and
  # makes --refresh-index rebuild the instance every run for no reason (cross-review HIGH).
  IDX_STAGE="$(mktemp -d /tmp/idx-stage.XXXX)"
  # Ship the top-level *.py AND *.sh (git_fetch.sh + activate_project.sh — the host runs them to
  # clone repos + attach projects) + requirements.txt + the shared manifest parser. tests/ live in
  # a subdir and are excluded by the top-level-only copy.
  cp "$ROOT"/index-service/*.py "$ROOT"/index-service/*.sh "$ROOT"/index-service/requirements.txt "$IDX_STAGE"/
  cp "$ROOT"/scripts/lib/render_manifest.py "$IDX_STAGE"/
  ( cd "$IDX_STAGE" && det_tar ./*.py ./*.sh requirements.txt | gzip -n > "$TMP_IDX" )
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
  TMP_GW="$(mktemp /tmp/bot-gateway.XXXX.tar.gz)"
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
  say step "Phase 1b: IAM"
  run "$SCRIPT_DIR/lib/provision_iam.sh" "$REGION" "$CONFIG_FILE" "$BUCKET"
  safe_source_env "$CONFIG_FILE"
fi

# ============================================================
# Phase 2: network (VPC/subnets/IGW/NAT — fully idempotent, reconciles by tag)
# ============================================================
if skip network; then say warn "skip network"; else
  say step "Phase 2: network"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] provision_network.sh (VPC/subnets/IGW/NAT) — discovers + reconciles by tag"
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
  say info "[dry-run] provision_index_service.sh (ARM EC2 + bootstrap, reuse if running) + /health wait"
else
  say step "Phase 3: index-service EC2 (BASE host — no project bound)"
  INDEX_IP="$("$SCRIPT_DIR/lib/provision_index_service.sh" \
    "$REGION" "$CONFIG_FILE" "$BUCKET" "$MAX_FILES" "$INSTANCE_TYPE" "$REFRESH_INDEX" "$ROOT_VOLUME_GB" "$MODEL" "$GLOSSARY_MAX_FILES")"
  update_env "$CONFIG_FILE" INDEX_SERVICE_IP "$INDEX_IP"
  safe_source_env "$CONFIG_FILE"
  # Wait for the BASE host bootstrap to finish before attaching any project. The base host
  # has NO bridge yet (projects attach later via deploy_project.sh), so we wait for SSM-online
  # + the BOOTSTRAP_DONE marker, NOT a bridge /health (per-project bridge health is gated inside
  # deploy_project.sh after activation). The instance is private, so we poll via SSM.
  if [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    say info "waiting for base-host bootstrap (apt + codegraph bin + gateway build, ~3-8 min) ..."
    # Hard-fail: never attach a project to an unconfirmed base host. Re-run after fixing.
    "$SCRIPT_DIR/lib/wait_base_host.sh" "$REGION" "$INDEX_SERVICE_INSTANCE" || {
      say err "index base host never finished bootstrap — aborting before attaching projects."
      say err "  inspect: aws ssm start-session --target $INDEX_SERVICE_INSTANCE ; tail /var/log/index-svc-bootstrap.log"
      # FAILED BLUE-GREEN REFRESH cleanup (cross-review P1): when this is a --refresh-index
      # run, INDEX_OLD_INSTANCE holds the still-HEALTHY old host (DNS still points at it),
      # and INDEX_SERVICE_INSTANCE is the BROKEN new one we just launched. If we just exit,
      # the broken new instance (a) bills forever and (b) — because its ArtifactSig ==
      # CURRENT_SIG — gets RE-SELECTED and reused by every later run's deterministic
      # selector, so the deploy never converges and the healthy old host bills in parallel.
      # So terminate the broken NEW instance and restore INDEX_SERVICE_INSTANCE to the old
      # healthy one, leaving the service exactly as it was before this failed refresh.
      if [[ -n "${INDEX_OLD_INSTANCE:-}" && "$INDEX_OLD_INSTANCE" != "${INDEX_SERVICE_INSTANCE:-}" ]]; then
        say warn "failed refresh: terminating the unhealthy NEW instance ${INDEX_SERVICE_INSTANCE} and keeping the healthy old one ${INDEX_OLD_INSTANCE} (still DNS target)"
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INDEX_SERVICE_INSTANCE" >/dev/null 2>&1 \
          && say ok "unhealthy new instance ${INDEX_SERVICE_INSTANCE} terminated" \
          || say warn "could not terminate unhealthy new instance ${INDEX_SERVICE_INSTANCE} — terminate manually to avoid a paid orphan"
        update_env "$CONFIG_FILE" INDEX_SERVICE_INSTANCE "$INDEX_OLD_INSTANCE"
        update_env "$CONFIG_FILE" INDEX_OLD_INSTANCE ""
      fi
      exit 1
    }
  fi
  # STABLE ENDPOINT: point the agent at a Route53 private DNS name, not the raw IP.
  # On a --refresh-index the instance (and its IP) change, but we just re-point the
  # SAME DNS name — so the runtime's CODEGRAPH_MCP_URL never changes, and AgentCore's
  # warm microVMs (which cache the env for 30+ min) never end up pointed at a dead,
  # terminated IP. This eliminates the intermittent empty-answer cards a refresh used
  # to cause. The runtime phase below uses INDEX_DNS_NAME instead of INDEX_SERVICE_IP.
  if [[ "$DRY_RUN" != true ]]; then
    "$SCRIPT_DIR/lib/provision_index_dns.sh" "$REGION" "$CONFIG_FILE" "$VPC_ID" "$INDEX_IP" >/dev/null
    safe_source_env "$CONFIG_FILE"
    # BLUE-GREEN terminate-last: provision_index_service recorded the OLD instance
    # in INDEX_OLD_INSTANCE (refresh path) instead of killing it up-front. Now that
    # the NEW instance is /health-green (the wait above) AND the DNS name is cut over
    # to it, drain the TTL (30s) so resolver caches expire, then terminate the old
    # one. This makes --refresh-index seamless (no dead-host window) and makes a
    # FAILED refresh a no-op (we never reach here — the health gate exited — so the
    # old instance keeps serving). Best-effort: a terminate hiccup must not fail the
    # otherwise-successful deploy.
    if [[ -n "${INDEX_OLD_INSTANCE:-}" && "$INDEX_OLD_INSTANCE" != "$INDEX_SERVICE_INSTANCE" ]]; then
      # Drain longer than the A-record TTL so warm-VM resolvers pick up the new IP
      # before we kill the old host. Derive the wait from the SAME TTL the DNS
      # record was written with (INDEX_DNS_TTL, persisted by provision_index_dns)
      # + a 5s margin, so the two can't silently drift apart. Fallback 35 if unset
      # (older config) — still > the historical 30s TTL.
      DRAIN_S=$(( ${INDEX_DNS_TTL:-30} + 5 ))
      # BREAK-BEFORE-MAKE for the gateway: the old instance also runs bot-gateway,
      # whose Feishu long-connection is a GLOBAL singleton per app (cluster mode —
      # two live clients steal each other's events). Synchronously stop the OLD
      # gateway NOW (systemctl stop returns after the process exits → connection
      # dropped), BEFORE Phase 6 starts the NEW instance's gateway, so the two can
      # never overlap. (Index/codegraph CAN run two instances — separate graph.db —
      # which is why index is make-before-break but gateway must be break-before-make.)
      bash "$SCRIPT_DIR/lib/stop_gateway.sh" "$REGION" "$INDEX_OLD_INSTANCE" || true
      say info "blue-green: new index healthy + DNS cut over; draining ${DRAIN_S}s (TTL ${INDEX_DNS_TTL:-30}+5) then terminating old instance $INDEX_OLD_INSTANCE"
      sleep "$DRAIN_S"
      # Clear INDEX_OLD_INSTANCE only on a SUCCESSFUL terminate: if terminate fails
      # (throttle/IAM), keep the id so the next deploy's reconcile can still GC the
      # orphan (clearing it unconditionally would leak a paid instance silently).
      if aws ec2 terminate-instances --region "$REGION" --instance-ids "$INDEX_OLD_INSTANCE" >/dev/null 2>&1; then
        say ok "old index instance $INDEX_OLD_INSTANCE terminated"
        update_env "$CONFIG_FILE" INDEX_OLD_INSTANCE ""   # clear so a later run doesn't re-terminate
      else
        say warn "could not terminate old index $INDEX_OLD_INSTANCE (kept in config for next-run GC; terminate manually if needed); deploy still OK"
      fi
    fi
  fi
  say ok "index-service at $INDEX_IP:8080 (stable name: ${INDEX_DNS_NAME:-pending})"
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
  say info "[dry-run] ECR create-if-absent + docker build --platform linux/arm64 + push source-truth/agent:latest"
else
  say step "Phase 4: build + push agent image"
  require_cmd docker "install Docker (buildx, ARM64 capable)" || exit 1
  # The agent image is ARM64-only. On an x86_64 host without arm64 emulation, the
  # build silently produces an unusable image that Phase 5 then consumes. Fail LOUD
  # with the fix command unless the host is arm64 OR a linux/arm64 buildx target is
  # available. (On the ARM dev host this passes immediately.)
  if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
    if ! docker buildx inspect --bootstrap 2>/dev/null | grep -q "linux/arm64"; then
      say err "host is $(uname -m) and cannot build linux/arm64. Set up emulation first:"
      say err "  docker run --privileged --rm tonistiigi/binfmt --install arm64"
      say err "  (or run the deploy from an arm64 host). The agent container is ARM64-only."
      exit 1
    fi
  fi
  ECR_REPO="source-truth/agent"
  ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"
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
  docker build --platform linux/arm64 -t "$ECR_URI" "$ROOT/agent-container"
  docker push "$ECR_URI"
  update_env "$CONFIG_FILE" ECR_IMAGE "$ECR_URI"
  say ok "image pushed: $ECR_URI"
fi

# ============================================================
# Phase 5: per-project deploy (bridge attach + runtime + gateway), looped over .local/projects.json
# ============================================================
# The shared base (network/IAM/EC2/image) is up. Each project is now deployed by deploy_project.sh:
# it ships the project's manifest to the host + runs activate_project.sh (git-clone its repos, build
# graphs, start its bridge on its port), deploys a per-project AgentCore runtime pointed at that
# bridge port, and activates a per-project gateway (its own Feishu app). Idempotent + isolated:
# one project's failure doesn't abort the others.
PROJECTS_CFG="$ROOT/.local/projects.json"
PROJECTS_DEPLOYED=false   # set true once ≥1 project's gateway is active (gates monitoring + footer)
if [[ "$SKIP_PROJECTS" == true ]]; then
  say step "Phase 5: per-project deploy"
  say info "--skip-projects: shared BASE host is provisioned; attaching NO project (init-env)."
  say info "  → run ./scripts/install.sh → 'add a project' to bring a bot online."
elif skip runtime && skip gateway; then
  say warn "skip per-project phase (runtime+gateway skipped)"
elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 5: per-project deploy"
  if [[ -f "$PROJECTS_CFG" ]]; then
    _pids="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["projects"]))' "$PROJECTS_CFG" 2>/dev/null || echo "")"
    say info "[dry-run] for each project [${_pids}]: activate_project.sh (clone+build+bridge) + deploy_runtime.py + activate_gateway.sh"
  else
    say info "[dry-run] no .local/projects.json — base host only; add a project via ./scripts/install.sh"
  fi
elif [[ ! -f "$PROJECTS_CFG" ]]; then
  say step "Phase 5: per-project deploy"
  say warn "no .local/projects.json — shared base is up, but NO project deployed yet."
  say warn "  → run ./scripts/install.sh → 'add a project' (creates the Feishu/git secrets + the"
  say warn "    projects.json entry), or copy config/projects.example.json to .local/projects.json."
else
  say step "Phase 5: per-project deploy"
  # LOG_HASH_SALT (host-shared, project-agnostic): ensure the secret EXISTS before any gateway
  # starts — hashUserId de-identification is only sound if the salt is SECRET (log.ts falls back
  # to a PUBLIC repo constant when unset). run.sh fetches the VALUE host-side, so it never crosses
  # an SSM command body. create-secret only on NOT-FOUND (never rotate an existing salt — that
  # would break DAU/retention correlation). Best-effort: if the deploy identity can't create it,
  # run.sh still tries to read it (and stamps saltWeak if absent).
  if [[ "$DRY_RUN" != true ]] && ! aws secretsmanager describe-secret --region "$REGION" --secret-id source-truth/log-hash-salt >/dev/null 2>&1; then
    GW_SALT="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    if err="$(aws secretsmanager create-secret --region "$REGION" --name source-truth/log-hash-salt \
         --secret-string "$GW_SALT" --description 'source-truth gateway LOG_HASH_SALT (telemetry de-identification)' 2>&1)"; then
      say ok "created a random LOG_HASH_SALT in Secrets Manager (source-truth/log-hash-salt)"
    else
      say warn "could not create source-truth/log-hash-salt (${err%%$'\n'*}); gateways run with the weak public fallback (telemetry stamps saltWeak)."
    fi
    unset GW_SALT
  fi
  # Loop every declared project. deploy_project.sh is idempotent; collect failures but keep going
  # (one project's broken git/Feishu must not block the others), then report at the end.
  mapfile -t _PIDS < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["projects"]))' "$PROJECTS_CFG")
  _failed=()
  for _pid in "${_PIDS[@]}"; do
    [[ -n "$_pid" ]] || continue
    if ! bash "$SCRIPT_DIR/lib/deploy_project.sh" "$REGION" "$_pid"; then
      say warn "project '$_pid' deploy failed — continuing with the rest; re-run after fixing"
      _failed+=("$_pid")
    fi
  done
  if [[ ${#_failed[@]} -gt 0 ]]; then
    say err "per-project deploy: ${#_failed[@]} project(s) failed: ${_failed[*]}"
    say err "  the others are up; fix the cause and re-run ./scripts/deploy-all.sh (idempotent)"
    exit 1
  fi
  say ok "all ${#_PIDS[@]} project(s) deployed (bridge + runtime + gateway each)"
  PROJECTS_DEPLOYED=true
fi

# ============================================================
# Phase 7: monitoring (CloudWatch metric-filters + dashboards + alarms + DAU lambda)
# ============================================================
# Runs AFTER the gateway phase so the gateway has (begun to) log to /source-truth/bot-gateway
# — the metric-filters target that group. BEST-EFFORT: the backend + gateway are already up by
# here, so a monitoring hiccup must WARN, never fail the deploy. All four applies are
# idempotent; re-running the deploy reconciles them. Skipped on --dry-run, --skip monitoring,
# and when the gateway wasn't activated this run (FEISHU_SECRET_ID empty → no log group yet).
#
# EXACT fresh-deploy behavior when the gateway hasn't written its FIRST log line yet (so the
# log group doesn't exist): dashboards PUT FINE (no data dependency); apply-metric-filters
# FAILS (its put-metric-filter calls error on the missing group) and is warned; apply-alarms
# ABORTS before creating the SNS topic or any alarm (it applies its backing filters first and
# bails on their failure) → so a fresh one-click deploy creates NO alarms yet; apply-dau-lambda
# SUCCEEDS (role/function/schedule don't need the group; only its scheduled query is idle until
# logs accrue). A deploy RE-RUN after the gateway has logged once creates the filters + alarms
# (idempotent) — that re-run is how alarm coverage is established. The runbook's manual 4-step
# is the same reconcile path.
if skip monitoring; then
  say warn "skip monitoring"
elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 7: monitoring"
  say info "[dry-run] apply metric-filters + dashboards + alarms + DAU lambda (CloudWatch, best-effort)"
elif [[ "$PROJECTS_DEPLOYED" != true ]]; then
  # No gateway activated this run → /source-truth/bot-gateway likely doesn't exist yet.
  # Dashboards/alarms would build on an empty/absent group; defer to a post-gateway re-run.
  say warn "skip monitoring (no gateway active yet — add a project, then monitoring applies on re-run; see runbook)"
else
  say step "Phase 7: monitoring (best-effort)"
  # Dashboards first (put regardless of data); then a-class metric-filters; then alarms
  # (applies its own dense backing filters first, then creates the SNS topic + alarms — so it
  # only succeeds once the log group exists); then the DAU lambda. Each warns on failure,
  # never aborts (the deploy is already past the point where the bot works).
  bash "$SCRIPT_DIR/apply-dashboards.sh" --region "$REGION" \
    || say warn "  apply-dashboards failed (non-fatal) — re-run ./scripts/apply-dashboards.sh --region $REGION"
  bash "$SCRIPT_DIR/apply-metric-filters.sh" --region "$REGION" \
    || say warn "  apply-metric-filters failed (non-fatal; log group may not exist until the gateway logs once) — re-run later"
  # Per-project breakdown filters (projectId-dimensioned companions; the by-project dashboard
  # reads these). Separate defs so the rollup metrics above stay dense/un-dimensioned.
  bash "$SCRIPT_DIR/apply-metric-filters.sh" --region "$REGION" \
    --defs "$ROOT/infra/monitoring/queries/metric-filters/by-project-metrics.json" \
    || say warn "  apply-metric-filters (by-project) failed (non-fatal) — re-run later"
  bash "$SCRIPT_DIR/apply-alarms.sh" --region "$REGION" \
    || say warn "  apply-alarms failed (non-fatal) — re-run ./scripts/apply-alarms.sh --region $REGION"
  bash "$SCRIPT_DIR/apply-dau-lambda.sh" --region "$REGION" \
    || say warn "  apply-dau-lambda failed (non-fatal) — re-run ./scripts/apply-dau-lambda.sh --region $REGION"
  say ok "monitoring applied (best-effort; widgets fill once the gateway logs accrue)"
fi

say ok "deploy-all complete"

if [[ "$DRY_RUN" != true && "$PROJECTS_DEPLOYED" != true ]]; then
  say warn "NEXT STEPS — shared base READY, but NO project/bot is active yet:"
  say warn "  • Run ./scripts/install.sh → 'add a project' to create its Feishu + git secrets and"
  say warn "    its projects.json entry, then it deploys that project's bridge + runtime + gateway."
  say warn "  • Until then, 策划 @机器人 → answer will NOT work even though the base host is healthy."
fi
