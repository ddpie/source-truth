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
# Phases (each skippable with --skip <phase>):
#   1 artifacts  : build/stage codegraph-server bin + index-service code + repo → S3
#   2 iam        : execution + index-service instance roles/policies (describe-or-create)
#   3 network    : VPC, public+private subnet, IGW, NAT, route tables (or reuse)
#   4 index-svc  : security groups + ARM EC2 (Ubuntu 24.04) running bootstrap.sh
#   5 image      : build the agent container (ARM64) and push to ECR
#   6 runtime    : AgentCore runtime in VPC mode, CODEGRAPH_MCP_URL set
#   7 gateway    : write /etc/bot-gateway.env + start bot-gateway.service (co-located
#                  on the index host) via SSM — once the runtime ARN exists
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
# shellcheck source=lib/resolve_repo.sh
source "$SCRIPT_DIR/lib/resolve_repo.sh"

CONFIG_DIR="$ROOT/.local"
CONFIG_FILE="$CONFIG_DIR/deploy-config"
mkdir -p "$CONFIG_DIR"

# --- defaults / flags ---
REGION=""
REPO_PATH=""             # --repo source: local dir | git URL | s3:// tarball/prefix (resolve_repo.sh)
REPO_REF=""              # --repo-ref: git branch/tag/commit (git sources only)
REPO_SUBDIR=""           # name the repo lives under on the index host (defaults to basename)
# These three honor a persist-and-read-back contract (flag > persisted > default)
# so a flagless reconcile re-run does NOT silently revert an operator's earlier
# choice (deploy_runtime.py updates the runtime IN PLACE, so a reverted MODEL would
# actually flip the live runtime). Empty here = "not given on the CLI"; resolved
# against the persisted config + defaults after safe_source_env below.
INSTANCE_TYPE=""
MAX_FILES=""
MODEL=""
ROOT_VOLUME_GB=""
IDLE_TIMEOUT=""          # AgentCore session idle timeout (s); gateway session TTL is aligned to this
MAX_LIFETIME=""          # AgentCore microVM hard max age (s) before forced recycle
DEFAULT_INSTANCE_TYPE="t4g.large"
DEFAULT_MAX_FILES="10000"
DEFAULT_MODEL="global.anthropic.claude-opus-4-8"
DEFAULT_ROOT_VOLUME_GB="30"
# Idle timeout default = AWS's own default (900s/15min). The gateway derives its
# session-reuse TTL from this exact value (persisted to deploy-config), so "warm
# enough to reuse" on the gateway and "still alive" on AgentCore mean the same
# thing. Cost: AgentCore bills idle MEMORY (not idle CPU), so raising this trades
# follow-up warm-hit rate for idle-memory spend — tune per workload.
DEFAULT_IDLE_TIMEOUT="900"
DEFAULT_MAX_LIFETIME="28800"
REFRESH_INDEX=false       # --refresh-index: replace a running index instance if its artifacts are stale
declare -A SKIP=()

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-all.sh --region <r> --repo <path> [options]

Required (first run):
  --region <r>        AWS region (e.g. ap-northeast-1)
  --repo <src>        Code repo to index + serve. Accepts ANY of:
                        • local dir   /path/to/repo
                        • git URL     https://github.com/org/repo(.git),
                                      https://gitlab.com/org/repo.git, git@host:org/repo.git
                        • S3 tarball  s3://bucket/key.tar.gz (or .tgz)
                        • S3 prefix   s3://bucket/prefix/
                      Git/S3 sources are fetched to a local temp dir, then staged
                      exactly like a local dir (idempotency unchanged).

Options:
  --repo-ref <r>      Git branch / tag / commit to clone (git sources only; default: default branch)
  --repo-subdir <n>   Name to place the repo under on the index host (default: derived from --repo)
  --instance-type <t> index-service EC2 type, ARM (default: t4g.large)
  --max-files <n>     codegraph max files to index (default: 10000)
  --root-volume-gb <n> index-service root EBS size in GiB (default: 30). Grow for a
                      large repo: it holds the repo copy + graph.db + tarball.
  --model <id>        Bedrock model id for the agent runtime
  --idle-timeout <s>  AgentCore session idle timeout, seconds (60..28800; default 900/15min).
                      The gateway's session-reuse TTL is aligned to this. Larger = higher
                      follow-up warm-hit rate but more idle-memory cost (idle CPU is free).
  --max-lifetime <s>  AgentCore microVM hard max age before forced recycle (60..28800; default 28800/8h)
  --skip <phase>      Skip a phase: artifacts|iam|network|index-svc|image|runtime|gateway (repeatable)
  --refresh-index     Replace the running index-service instance if this run staged
                      newer index-service code / repo to S3 (reuse can't re-bootstrap).
                      Without it, a stale reuse only WARNs (never silently serves old code).
  --dry-run           Print the plan and resolved IDs, make no changes
  -h, --help

First-run PREREQUISITES (not auto-provisioned — the deploy hard-fails / WARNs if missing):
  • codegraph-server binary (ARM aarch64, glibc>=2.38, pinned 0.18.5) on PATH or
    via CODEGRAPH_SERVER_BIN — obtain from its official release channel; the deploy
    does NOT download it.
  • A host that can build linux/arm64 images (arm64 host, or x86 + `docker run
    --privileged --rm tonistiigi/binfmt --install arm64`).
  • Bedrock model access enabled for the model, and AgentCore available in --region
    (both are probed at preflight and WARN if missing).
  • Feishu app secret created by hand (Secrets Manager/SSM) for the separately-run
    bot-gateway — see the NEXT STEPS printed at the end.
EOF
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --repo) REPO_PATH="$2"; shift 2 ;;
    --repo-ref) REPO_REF="$2"; shift 2 ;;
    --repo-subdir) REPO_SUBDIR="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
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
INSTANCE_TYPE="${INSTANCE_TYPE:-${DEPLOY_INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}}"
# Export so provision_network.sh can pick an AZ that actually offers this type
# (Graviton isn't in every AZ of every region) instead of a blind AvailabilityZones[0].
export DEPLOY_INSTANCE_TYPE="$INSTANCE_TYPE"
MAX_FILES="${MAX_FILES:-${DEPLOY_MAX_FILES:-$DEFAULT_MAX_FILES}}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-${DEPLOY_ROOT_VOLUME_GB:-$DEFAULT_ROOT_VOLUME_GB}}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-${DEPLOY_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}}"
MAX_LIFETIME="${MAX_LIFETIME:-${DEPLOY_MAX_LIFETIME:-$DEFAULT_MAX_LIFETIME}}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# --- resolve the --repo source (local dir | git URL | s3:// tarball/prefix) ---
# Classify + derive the on-host subdir name here (network-free, dry-run safe). The
# ACTUAL fetch (git clone / s3 download) is deferred to the artifacts phase so it
# is skipped on --dry-run and `--skip artifacts`, and so a reconcile re-run with no
# --repo (REPO_PATH empty, subdir read back from persisted config) does no network.
REPO_KIND=""
if [[ -n "$REPO_PATH" ]]; then
  REPO_KIND="$(classify_repo_source "$REPO_PATH")"
  if [[ "$REPO_KIND" == "unknown" ]]; then
    say err "--repo '$REPO_PATH' is not a local path, git URL, or s3:// URI."
    say err "  local dir: /path/to/repo   git: https://github.com/org/repo(.git)   s3: s3://bucket/key.tar.gz"
    exit 2
  fi
  [[ -n "$REPO_SUBDIR" ]] || REPO_SUBDIR="$(repo_subdir_from_source "$REPO_PATH" "$REPO_KIND")"
  if [[ "$REPO_KIND" == "git" ]]; then
    require_cmd git "install git to clone a git --repo source" || exit 1
  fi
else
  # No --repo this run: reuse the persisted subdir (reconcile path). Keep the old
  # basename fallback so a config that predates this resolver still works.
  [[ -n "$REPO_SUBDIR" ]] || REPO_SUBDIR="repo"
fi

BUCKET="source-truth-repo-${ACCOUNT}-$(echo "$REGION" | tr -d '-')"
say info "account=$ACCOUNT region=$REGION bucket=$BUCKET repo=${REPO_PATH:-<reuse>} kind=${REPO_KIND:-n/a} repo_subdir=$REPO_SUBDIR model=$MODEL"

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
        case "$MODEL" in
          global.*)
            say warn "  → '$MODEL' is a GLOBAL inference profile, only carried in a SUBSET of"
            say warn "    regions. For a region outside that set, pass a REGION-SCOPED profile"
            say warn "    instead, e.g. --model apac.anthropic.claude-opus-4-8 (APAC) or the"
            say warn "    us.anthropic.* / eu.anthropic.* form for your region." ;;
        esac
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
  return 0
}
if [[ "$DRY_RUN" != true ]]; then preflight_boto3; preflight_model_access; preflight_agentcore; preflight_quota; fi

# Persist resolved config — but NOT on --dry-run (dry-run must make no changes,
# including no writes to deploy-config).
if [[ "$DRY_RUN" != true ]]; then
  update_env "$CONFIG_FILE" DEPLOY_REGION "$REGION"
  update_env "$CONFIG_FILE" ARTIFACT_BUCKET "$BUCKET"
  update_env "$CONFIG_FILE" REPO_SUBDIR "$REPO_SUBDIR"
  # Persist the resolved knobs so the next flagless run reads them back.
  update_env "$CONFIG_FILE" DEPLOY_MODEL "$MODEL"
  update_env "$CONFIG_FILE" DEPLOY_INSTANCE_TYPE "$INSTANCE_TYPE"
  update_env "$CONFIG_FILE" DEPLOY_MAX_FILES "$MAX_FILES"
  update_env "$CONFIG_FILE" DEPLOY_ROOT_VOLUME_GB "$ROOT_VOLUME_GB"
fi

run() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] $*"; else "$@"; fi; }
skip() { [[ -n "${SKIP[$1]:-}" ]]; }

# ============================================================
# Phase 1: artifacts → S3
# ============================================================
if skip artifacts; then say warn "skip artifacts"; elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 1: artifacts → S3"
  say info "[dry-run] ensure bucket $BUCKET; upload codegraph-server bin + index-service.tar.gz + ${REPO_SUBDIR}.tar.gz + bot-gateway.tar.gz"
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
  CG_BIN="${CODEGRAPH_SERVER_BIN:-$(command -v codegraph-server || echo "$HOME/.local/bin/codegraph-server")}"
  if [[ -x "$CG_BIN" ]]; then
    run aws s3 cp "$CG_BIN" "s3://$BUCKET/bin/codegraph-server" --region "$REGION"
  elif aws s3api head-object --bucket "$BUCKET" --key bin/codegraph-server --region "$REGION" >/dev/null 2>&1; then
    say info "codegraph-server not local, but already staged at s3://$BUCKET/bin/codegraph-server (reuse)"
  else
    say err "codegraph-server binary not found: not at '\$CODEGRAPH_SERVER_BIN'/PATH/~/.local/bin, and not staged in S3."
    say err "  → Download the ARM aarch64 codegraph-server (glibc>=2.38) per index-service/README.md,"
    say err "    put it on PATH or set CODEGRAPH_SERVER_BIN=/path/to/codegraph-server, then re-run."
    [[ "$DRY_RUN" == true ]] || exit 1
  fi

  # index-service code (bridge + persistent session + path align + perf, etc).
  # Package ALL top-level *.py + requirements.txt — NOT a hand-maintained file
  # list. codegraph_session.py imports perf.py at module load, so an omitted
  # module would crash the bridge on import on a fresh instance (health gate then
  # times out). Globbing every .py makes new modules ship automatically; tests/
  # live in a subdir and are excluded by the top-level-only glob.
  TMP_IDX="$(mktemp /tmp/index-service.XXXX.tar.gz)"
  # DETERMINISTIC archive: pin sort order, mtime, and owner, and `gzip -n` (no name/
  # timestamp in the gzip header). Otherwise the tarball's bytes — hence its S3 ETag —
  # change on every run even when content is identical, which makes the index-host
  # ArtifactSig staleness check (provision_index_service.sh) ALWAYS report stale and
  # makes --refresh-index rebuild the instance every run for no reason (cross-review HIGH).
  ( cd "$ROOT/index-service" && tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - ./*.py requirements.txt | gzip -n > "$TMP_IDX" )
  run aws s3 cp "$TMP_IDX" "s3://$BUCKET/index-service.tar.gz" --region "$REGION"

  # repo to index. EXCLUDE .git / vendored deps / build caches: codegraph already
  # skips them at index time (--exclude node_modules/.venv/.git), and they're NOT
  # served as source — but without excluding them here they'd inflate the S3 tarball
  # AND the on-disk extract on the index host's (size-bounded) root volume, which is
  # the most likely fresh-account hard-stop on a real repo with a multi-GB .git
  # history. Excluding them keeps the staged artifact == what codegraph indexes.
  if [[ -n "$REPO_PATH" ]]; then
    # Resolve a git/s3 source into a LOCAL dir named after REPO_SUBDIR, then stage it
    # exactly like a local dir. Done HERE (not at flag-parse) so it's skipped on
    # --dry-run / `--skip artifacts` and a flagless reconcile re-run does no network.
    STAGE_REPO_PATH="$REPO_PATH"
    if [[ "$REPO_KIND" == "git" || "$REPO_KIND" == "s3" ]]; then
      REPO_FETCH_ROOT="$(mktemp -d /tmp/st-repo-src.XXXX)"
      # cleanup on exit: a fetched repo can be GBs — don't leak it under /tmp.
      trap '[[ -n "${REPO_FETCH_ROOT:-}" ]] && rm -rf "$REPO_FETCH_ROOT"' EXIT
      STAGE_REPO_PATH="$REPO_FETCH_ROOT/$REPO_SUBDIR"
      fetch_repo_source "$REPO_PATH" "$REPO_KIND" "$REGION" "$STAGE_REPO_PATH" "$REPO_REF" \
        || { say err "failed to fetch --repo source ($REPO_KIND): $REPO_PATH"; exit 1; }
    elif [[ ! -d "$REPO_PATH" ]]; then
      say err "--repo local path does not exist or is not a directory: $REPO_PATH"; exit 1
    fi
    TMP_REPO="$(mktemp /tmp/repo.XXXX.tar.gz)"
    # Deterministic (see index-service tar above): a git clone / s3 fetch writes files
    # with fresh mtimes every run, so without pinning mtime/sort/owner + `gzip -n` the
    # ETag would change every deploy and --refresh-index would rebuild the index host
    # on every run even when the repo content is unchanged (cross-review HIGH).
    tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
      --exclude='.git' --exclude='node_modules' --exclude='.venv' \
      --exclude='*.tmp' --exclude='__pycache__' \
      -cf - -C "$(dirname "$STAGE_REPO_PATH")" "$(basename "$STAGE_REPO_PATH")" \
      | gzip -n > "$TMP_REPO"
    run aws s3 cp "$TMP_REPO" "s3://$BUCKET/${REPO_SUBDIR}.tar.gz" --region "$REGION"
    rm -f "$TMP_REPO"
  fi

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
  ( cd "$ROOT/bot-gateway" && tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - src tsconfig.json package.json package-lock.json run.sh | gzip -n > "$TMP_GW" )
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
  say step "Phase 3: index-service EC2"
  INDEX_IP="$("$SCRIPT_DIR/lib/provision_index_service.sh" \
    "$REGION" "$CONFIG_FILE" "$BUCKET" "$REPO_SUBDIR" "$MAX_FILES" "$INSTANCE_TYPE" "$REFRESH_INDEX" "$ROOT_VOLUME_GB")"
  update_env "$CONFIG_FILE" INDEX_SERVICE_IP "$INDEX_IP"
  safe_source_env "$CONFIG_FILE"
  # Wait for the bridge to become healthy before wiring the runtime to it. The
  # instance is in a private subnet (not reachable from here), so we poll its
  # /health via SSM. The bridge serves 200 only once the graph warmed non-empty.
  if [[ "$DRY_RUN" != true ]] && [[ -n "${INDEX_SERVICE_INSTANCE:-}" ]]; then
    say info "waiting for index-service /health (build + warmup, ~2-7 min) ..."
    # Hard-fail: never wire the runtime to an unconfirmed index. A timeout here
    # means the build/warmup didn't succeed — serving on it would violate the
    # prime directive (code is the only source of truth). Re-run after fixing.
    "$SCRIPT_DIR/lib/wait_index_health.sh" "$REGION" "$INDEX_SERVICE_INSTANCE" || {
      say err "index-service never became healthy — aborting before runtime wiring."
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
# Phase 5: AgentCore runtime (VPC + CodeGraph MCP)
# ============================================================
if skip runtime; then say warn "skip runtime"; elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 5: AgentCore runtime"
  say info "[dry-run] deploy_runtime.py (VPC + CODEGRAPH_MCP_URL → index-service; no EFS mount)"
else
  say step "Phase 5: AgentCore runtime"
  # Use the image built+pushed in Phase 4b (persisted to config); fall back to
  # the computed URI if the image phase was skipped.
  ECR_URI="${ECR_IMAGE:-${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/source-truth/agent:latest}"
  # Guard required cross-phase state with actionable messages (consistent with
  # RUNTIME_SG below) rather than a bare set -u "unbound variable".
  ROLE_ARN="${AGENT_RUNTIME_ROLE:-arn:aws:iam::${ACCOUNT}:role/SourceTruthAgentRuntimeRole}"
  SUBNET="${PRIVATE_SUBNET:?PRIVATE_SUBNET not set — run the network phase first}"
  IDX_IP="${INDEX_SERVICE_IP:?INDEX_SERVICE_IP not set — run the index-svc phase first}"
  # Use the STABLE DNS name (set by provision_index_dns.sh) so the runtime env is
  # invariant across index-instance replacement — warm microVMs never end up on a
  # dead IP. Fall back to the raw IP only if DNS wasn't provisioned (e.g. an old
  # config), so a partial/legacy state still deploys.
  IDX_ENDPOINT="${INDEX_DNS_NAME:-$IDX_IP}"
  CODEGRAPH_URL="http://${IDX_ENDPOINT}:8080/mcp"
  # Runtime joins the VPC with the index-service SG: it has default egress-all
  # (reaches the bridge on :8080), and the index SG accepts inbound from the VPC
  # CIDR — which covers this SG's members. No EFS: the agent reads all code over
  # that HTTP bridge, so the microVM mounts no filesystem.
  RUNTIME_SG="${INDEX_SERVICE_SG:?INDEX_SERVICE_SG not set — run the index-svc phase first}"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] deploy_runtime.py → AgentCore runtime (model=$MODEL, sg=$RUNTIME_SG, CODEGRAPH_MCP_URL=${CODEGRAPH_URL}, idle=${IDLE_TIMEOUT}s, maxlife=${MAX_LIFETIME}s)"
  else
    # Capture stdout (deploy_runtime.py prints AGENT_RUNTIME_ID/ARN to stdout, all
    # status to stderr) so we can PERSIST the ARN. Without this the runtime deploys
    # but the gateway (which hard-requires RUNTIME_ARN, src/index.ts) has no
    # automated way to find it — breaking the one-click end-to-end goal.
    RT_OUT="$(python3 "$SCRIPT_DIR/lib/deploy_runtime.py" \
      --region "$REGION" --account "$ACCOUNT" \
      --role-arn "$ROLE_ARN" --image "$ECR_URI" --model "$MODEL" \
      --subnets "$SUBNET" --security-groups "$RUNTIME_SG" \
      --codegraph-mcp-url "$CODEGRAPH_URL" \
      --idle-timeout "$IDLE_TIMEOUT" --max-lifetime "$MAX_LIFETIME")"
    RT_ARN="$(printf '%s\n' "$RT_OUT" | sed -n 's/^AGENT_RUNTIME_ARN=//p')"
    RT_ID="$(printf '%s\n' "$RT_OUT" | sed -n 's/^AGENT_RUNTIME_ID=//p')"
    if [[ -z "$RT_ARN" ]]; then
      say err "deploy_runtime.py produced no AGENT_RUNTIME_ARN — cannot wire the gateway"
      printf '%s\n' "$RT_OUT"
      exit 1
    fi
    update_env "$CONFIG_FILE" AGENT_RUNTIME_ARN "$RT_ARN"
    update_env "$CONFIG_FILE" RUNTIME_ARN "$RT_ARN"  # the name bot-gateway reads
    [[ -n "$RT_ID" ]] && update_env "$CONFIG_FILE" AGENT_RUNTIME_ID "$RT_ID"
    # Persist the lifecycle knobs: read back on a flagless rerun (so an in-place
    # update doesn't revert them), AND consumed by the gateway phase so the gateway's
    # session-reuse TTL is aligned to the runtime's actual idle window.
    update_env "$CONFIG_FILE" DEPLOY_IDLE_TIMEOUT "$IDLE_TIMEOUT"
    update_env "$CONFIG_FILE" DEPLOY_MAX_LIFETIME "$MAX_LIFETIME"
    say ok "runtime deployed → RUNTIME_ARN persisted to ${CONFIG_FILE} (VPC sg=$RUNTIME_SG, idle=${IDLE_TIMEOUT}s, maxlife=${MAX_LIFETIME}s, CODEGRAPH_MCP_URL → ${CODEGRAPH_URL})"
  fi
fi

# ============================================================
# Phase 6: activate bot-gateway (co-located on the index host)
# ============================================================
# The gateway was BUILT + INSTALLED by bootstrap.sh but left stopped (it needs the
# now-existing RUNTIME_ARN). Here we write /etc/bot-gateway.env + start the service
# via SSM. Requires a Feishu secret id (FEISHU_SECRET_ID): install.sh creates the
# secret and persists the id; a backend-only run without it SKIPS activation and
# prints how to finish. The credentials themselves stay in Secrets Manager — only
# the secret id is written to the host (run.sh fetches the creds at start).
GW_RUNTIME_ARN="${RUNTIME_ARN:-${AGENT_RUNTIME_ARN:-}}"
GW_INSTANCE="${INDEX_SERVICE_INSTANCE:-}"
# Backfill FEISHU_SECRET_ID when it isn't in the env/config: a direct `deploy-all.sh`
# rerun (not via install.sh, which is the only thing that persists it) would otherwise
# skip gateway activation. If the conventional secret (created by install.sh) exists,
# adopt it so a plain rerun still (re)activates the gateway — critical after a
# --refresh-index swapped the index host, since the OLD gateway was just terminated
# and the NEW one only comes up here (cross-review HIGH).
if [[ -z "${FEISHU_SECRET_ID:-}" && "$DRY_RUN" != true ]]; then
  if aws secretsmanager describe-secret --secret-id "source-truth/feishu-app" --region "$REGION" >/dev/null 2>&1; then
    FEISHU_SECRET_ID="source-truth/feishu-app"
    update_env "$CONFIG_FILE" FEISHU_SECRET_ID "$FEISHU_SECRET_ID"
    say info "adopted existing Feishu secret source-truth/feishu-app (FEISHU_SECRET_ID backfilled)"
  fi
fi
# Did this run swap the index host? If so the old gateway was terminated in Phase 3,
# so NOT activating the new one now leaves the bot offline — escalate that case.
GW_SWAPPED=false
[[ -n "${INDEX_OLD_INSTANCE:-}" ]] && GW_SWAPPED=true
if skip gateway; then
  say warn "skip gateway"
  [[ "$GW_SWAPPED" == true ]] && say err "WARNING: index host was just replaced AND gateway activation was skipped — the bot is now OFFLINE. Re-run without --skip gateway."
elif [[ "$DRY_RUN" == true ]]; then
  say step "Phase 6: activate bot-gateway"
  say info "[dry-run] write /etc/bot-gateway.env (RUNTIME_ARN, FEISHU_SECRET_ID, LOCALE) + start bot-gateway.service via SSM"
elif [[ -z "${FEISHU_SECRET_ID:-}" ]]; then
  say step "Phase 6: activate bot-gateway"
  if [[ "$GW_SWAPPED" == true ]]; then
    say err "index host was REPLACED this run but no FEISHU_SECRET_ID is configured — the new host's gateway is NOT started, so the bot is now OFFLINE."
    say err "  → Run ./scripts/install.sh, or set FEISHU_SECRET_ID and re-run, to bring the gateway back."
  else
    say warn "no FEISHU_SECRET_ID configured — skipping gateway activation (backend-only deploy)."
    say warn "  → Run ./scripts/install.sh (interactive) to create the Feishu secret + activate the gateway,"
    say warn "    or set FEISHU_SECRET_ID (a Secrets Manager secret holding {app_id,app_secret,bot_open_id}) and re-run."
  fi
else
  say step "Phase 6: activate bot-gateway"
  bash "$SCRIPT_DIR/lib/activate_gateway.sh" \
    "$REGION" "$GW_INSTANCE" "$GW_RUNTIME_ARN" "$FEISHU_SECRET_ID" \
    "${LOCALE:-zh}" "${LOG_HASH_SALT:-}" "${FEISHU_API_BASE:-}" "$IDLE_TIMEOUT" \
    || { say err "gateway activation failed — backend is up; fix and re-run (or --skip gateway)"; exit 1; }
  say ok "bot-gateway activated on $GW_INSTANCE"
fi

say ok "deploy-all complete"

if [[ "$DRY_RUN" != true && -z "${FEISHU_SECRET_ID:-}" ]]; then
  say warn "NEXT STEPS — backend READY, but the bot-gateway is NOT yet active:"
  say warn "  • Run ./scripts/install.sh to create the Feishu secret in Secrets Manager and activate the gateway,"
  say warn "  • or create the secret yourself and re-run with FEISHU_SECRET_ID set."
  say warn "  • Until then, 策划 @机器人 → answer will NOT work even though every AWS resource is healthy."
fi
