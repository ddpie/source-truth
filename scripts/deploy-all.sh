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
# Phases (each skippable with --skip-<phase>):
#   1 artifacts  : build/stage codegraph-server bin + index-service code + repo → S3
#   2 network    : VPC, public+private subnet, IGW, NAT, route tables (or reuse)
#   3 index-svc  : security groups + ARM EC2 (Ubuntu 24.04) running bootstrap.sh
#   4 runtime    : AgentCore runtime in VPC mode, CODEGRAPH_MCP_URL set
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

CONFIG_DIR="$ROOT/.local"
CONFIG_FILE="$CONFIG_DIR/deploy-config"
mkdir -p "$CONFIG_DIR"

# --- defaults / flags ---
REGION=""
REPO_PATH=""
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
DEFAULT_INSTANCE_TYPE="t4g.large"
DEFAULT_MAX_FILES="10000"
DEFAULT_MODEL="global.anthropic.claude-sonnet-4-6"
DEFAULT_ROOT_VOLUME_GB="30"
REFRESH_INDEX=false       # --refresh-index: replace a running index instance if its artifacts are stale
declare -A SKIP=()

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-all.sh --region <r> --repo <path> [options]

Required (first run):
  --region <r>        AWS region (e.g. ap-northeast-1)
  --repo <path>       Local path to the code repo to index + serve

Options:
  --repo-subdir <n>   Name to place the repo under on the index host (default: basename of --repo)
  --instance-type <t> index-service EC2 type, ARM (default: t4g.large)
  --max-files <n>     codegraph max files to index (default: 10000)
  --root-volume-gb <n> index-service root EBS size in GiB (default: 30). Grow for a
                      large repo: it holds the repo copy + graph.db + tarball.
  --model <id>        Bedrock model id for the agent runtime
  --skip <phase>      Skip a phase: artifacts|iam|network|index-svc|image|runtime (repeatable)
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
    --repo-subdir) REPO_SUBDIR="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
    --root-volume-gb) ROOT_VOLUME_GB="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
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
MAX_FILES="${MAX_FILES:-${DEPLOY_MAX_FILES:-$DEFAULT_MAX_FILES}}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-${DEPLOY_ROOT_VOLUME_GB:-$DEFAULT_ROOT_VOLUME_GB}}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ -n "$REPO_SUBDIR" ]] || REPO_SUBDIR="$(basename "${REPO_PATH:-${REPO_SUBDIR:-repo}}")"
BUCKET="source-truth-repo-${ACCOUNT}-$(echo "$REGION" | tr -d '-')"
say info "account=$ACCOUNT region=$REGION bucket=$BUCKET repo_subdir=$REPO_SUBDIR model=$MODEL"

# Bedrock model-access preflight. On a BRAND-NEW account the IAM grant
# (bedrock:InvokeModel) is NOT enough — the account owner must separately ENABLE
# model access in the Bedrock console. Without it, deploy still goes green (the
# runtime reaches READY without ever invoking the model) and only the first real
# question fails with AccessDeniedException. We probe with a minimal invoke and
# WARN loudly + actionably on denial — non-blocking, because the probe can fail
# for unrelated reasons (deploy identity lacking bedrock-runtime, model-id form,
# transient) and must never block an otherwise-working deploy. Skipped on dry-run.
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
      *AccessDenied*|*"don't have access"*|*"not authorized"*|*not\ enabled*)
        say warn "Bedrock model access appears DISABLED for '$MODEL' in $REGION."
        say warn "  → Enable it in the Bedrock console → Model access (per participating"
        say warn "    region for the global.* inference profile), then questions will work."
        say warn "  (Deploy continues; the runtime will reach READY but answers will fail"
        say warn "   with AccessDeniedException until model access is granted.)" ;;
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
if [[ "$DRY_RUN" != true ]]; then preflight_model_access; preflight_agentcore; fi

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
  say info "[dry-run] ensure bucket $BUCKET; upload codegraph-server bin + index-service.tar.gz + ${REPO_SUBDIR}.tar.gz"
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
  ( cd "$ROOT/index-service" && tar czf "$TMP_IDX" ./*.py requirements.txt )
  run aws s3 cp "$TMP_IDX" "s3://$BUCKET/index-service.tar.gz" --region "$REGION"

  # repo to index. EXCLUDE .git / vendored deps / build caches: codegraph already
  # skips them at index time (--exclude node_modules/.venv/.git), and they're NOT
  # served as source — but without excluding them here they'd inflate the S3 tarball
  # AND the on-disk extract on the index host's (size-bounded) root volume, which is
  # the most likely fresh-account hard-stop on a real repo with a multi-GB .git
  # history. Excluding them keeps the staged artifact == what codegraph indexes.
  if [[ -n "$REPO_PATH" ]]; then
    TMP_REPO="$(mktemp /tmp/repo.XXXX.tar.gz)"
    tar czf "$TMP_REPO" \
      --exclude='.git' --exclude='node_modules' --exclude='.venv' \
      --exclude='*.tmp' --exclude='__pycache__' \
      -C "$(dirname "$REPO_PATH")" "$(basename "$REPO_PATH")"
    run aws s3 cp "$TMP_REPO" "s3://$BUCKET/${REPO_SUBDIR}.tar.gz" --region "$REGION"
  fi
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
# Phase 2: network (reuse if NETWORK_VPC_ID already set)
# ============================================================
if skip network; then say warn "skip network"; else
  say step "Phase 2: network"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] provision_network.sh (VPC/subnets/IGW/NAT) — reuse if VPC_ID set"
  elif [[ -n "${VPC_ID:-}" ]]; then
    say info "reusing VPC $VPC_ID"
  else
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
      say info "blue-green: new index healthy + DNS cut over; draining DNS TTL then terminating old instance $INDEX_OLD_INSTANCE"
      sleep 35  # > Route53 A-record TTL (30s) so warm-VM resolvers pick up the new IP
      aws ec2 terminate-instances --region "$REGION" --instance-ids "$INDEX_OLD_INSTANCE" >/dev/null 2>&1 \
        && say ok "old index instance $INDEX_OLD_INSTANCE terminated" \
        || say warn "could not terminate old index $INDEX_OLD_INSTANCE (terminate it manually); deploy still OK"
      update_env "$CONFIG_FILE" INDEX_OLD_INSTANCE ""   # clear so a later run doesn't re-terminate
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
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com" >/dev/null 2>&1
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
    say info "[dry-run] deploy_runtime.py → AgentCore runtime (model=$MODEL, sg=$RUNTIME_SG, CODEGRAPH_MCP_URL=${CODEGRAPH_URL})"
  else
    # Capture stdout (deploy_runtime.py prints AGENT_RUNTIME_ID/ARN to stdout, all
    # status to stderr) so we can PERSIST the ARN. Without this the runtime deploys
    # but the gateway (which hard-requires RUNTIME_ARN, src/index.ts) has no
    # automated way to find it — breaking the one-click end-to-end goal.
    RT_OUT="$(python3 "$SCRIPT_DIR/lib/deploy_runtime.py" \
      --region "$REGION" --account "$ACCOUNT" \
      --role-arn "$ROLE_ARN" --image "$ECR_URI" --model "$MODEL" \
      --subnets "$SUBNET" --security-groups "$RUNTIME_SG" \
      --codegraph-mcp-url "$CODEGRAPH_URL")"
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
    say ok "runtime deployed → RUNTIME_ARN persisted to ${CONFIG_FILE} (VPC sg=$RUNTIME_SG, CODEGRAPH_MCP_URL → ${CODEGRAPH_URL})"
  fi
fi

say ok "deploy-all complete"

# Final next-steps: the backend (index-service + AgentCore runtime) is now up, but
# the Feishu bot-gateway is NOT deployed by this script and needs the ONE manual
# prerequisite AGENTS.md flags. Surface it loudly (non-blocking) so a fresh-account
# run doesn't report success while the end-to-end 策划→answer path is silently dead.
if [[ "$DRY_RUN" != true ]]; then
  say warn "NEXT STEPS — the backend is READY but the bot-gateway is NOT yet running:"
  say warn "  • bot-gateway is a long-lived process you run separately (not provisioned here)."
  say warn "  • It requires env: FEISHU_APP_ID + FEISHU_APP_SECRET (create the secret by hand —"
  say warn "    Secrets Manager/SSM, per AGENTS.md; this script does NOT create it), FEISHU_BOT_OPEN_ID,"
  say warn "    AWS_REGION, and RUNTIME_ARN (already persisted to ${CONFIG_FILE})."
  say warn "  • Until the gateway runs with those, 策划 @机器人 → answer will NOT work even though"
  say warn "    every AWS resource above is healthy."
fi
