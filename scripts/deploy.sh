#!/usr/bin/env bash
# deploy.sh — One-click idempotent deploy for source-truth (MVP).
#
# Orchestrates three components in dependency order:
#   1. index-service  (常驻 CodeGraph + EFS + MCP-over-HTTP bridge)
#   2. AgentCore Runtime  (agent-container image → Firecracker microVM)
#   3. bot-gateway  (TypeScript long-poll + CardKit streaming)
#
# Idempotent: resource exists → update; absent → create.
# Config persists to .local/deploy-config (gitignored); subsequent runs read it.
#
# Usage:
#   ./scripts/deploy.sh [FLAGS]
#
# Flags:
#   --region <r>         AWS region (default: from deploy-config > env > us-east-1)
#   --dry-run            Preflight checks + print plan only (no AWS calls)
#   --only-agent         Only (re)deploy agent-container to AgentCore Runtime
#   --only-gateway       Only (re)deploy bot-gateway
#   --only-index         Only (re)deploy index-service
#   --skip-index         Skip index-service step
#   --skip-gateway       Skip bot-gateway step
#   -h, --help           Show this help
#
# Idempotent: existing resources are updated in place, not recreated.
# Secrets go through AWS Secrets Manager / SSM — never baked into images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/env-utils.sh
source "$SCRIPT_DIR/lib/env-utils.sh"

CONFIG_DIR="$ROOT/.local"
CONFIG_FILE="$CONFIG_DIR/deploy-config"

# --- Usage ---
usage() {
  cat <<'EOF'
Usage: ./scripts/deploy.sh [FLAGS]

One-click idempotent deploy for source-truth MVP.

Orchestrates: index-service → AgentCore Runtime → bot-gateway.
Idempotent: resource exists → update; absent → create.

Flags:
  --region <r>         AWS region (default: deploy-config > env > us-east-1)
  --dry-run            Preflight checks + print plan (no AWS calls)
  --only-agent         Only (re)deploy agent-container
  --only-gateway       Only (re)deploy bot-gateway
  --only-index         Only (re)deploy index-service
  --skip-index         Skip index-service step
  --skip-gateway       Skip bot-gateway step
  -h, --help           Show this help
EOF
}

# --- Parse flags ---
REGION=""
DRY_RUN=false
ONLY_AGENT=false
ONLY_GATEWAY=false
ONLY_INDEX=false
SKIP_INDEX=false
SKIP_GATEWAY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)       REGION="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --only-agent)   ONLY_AGENT=true; shift ;;
    --only-gateway) ONLY_GATEWAY=true; shift ;;
    --only-index)   ONLY_INDEX=true; shift ;;
    --skip-index)   SKIP_INDEX=true; shift ;;
    --skip-gateway) SKIP_GATEWAY=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              say err "Unknown flag: $1"; usage >&2; exit 2 ;;
  esac
done

# --- Load saved config ---
[[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
safe_source_env "$CONFIG_FILE"

# --- Resolve region ---
REGION="${REGION:-${DEPLOY_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

# ============================================================
# Phase 0: Preflight
# ============================================================
say step "Phase 0: Preflight"
say info "Region: $REGION"

require_cmd aws "install AWS CLI v2" || exit 1
require_cmd python3 || exit 1
require_cmd jq || exit 1

# Verify AWS credentials
if ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  say ok "AWS credentials valid (account $ACCOUNT_ID)"
else
  if [[ "$DRY_RUN" == true ]]; then
    say warn "AWS credentials not available (dry-run continues without)"
    ACCOUNT_ID="<unknown>"
  else
    say err "AWS credentials not configured. Run 'aws configure' or set AWS_PROFILE."
    exit 1
  fi
fi

# boto3 check
if python3 -c "import boto3" 2>/dev/null; then
  say ok "boto3 importable"
else
  say err "boto3 not installed. Run 'pip install boto3'."
  exit 1
fi

# Persist region
update_env "$CONFIG_FILE" "DEPLOY_REGION" "$REGION"

say info "Config: $CONFIG_FILE"
say ok "Preflight passed"
echo ""

# --- Dry run: stop here ---
if [[ "$DRY_RUN" == true ]]; then
  say step "Dry-run plan"
  echo "  Would deploy (in order):"
  [[ "$SKIP_INDEX" == false && "$ONLY_AGENT" == false && "$ONLY_GATEWAY" == false ]] && echo "    1. index-service (EFS + CodeGraph + MCP bridge)"
  [[ "$ONLY_INDEX" == false && "$ONLY_GATEWAY" == false ]] && echo "    2. AgentCore Runtime (agent-container image)"
  [[ "$SKIP_GATEWAY" == false && "$ONLY_AGENT" == false && "$ONLY_INDEX" == false ]] && echo "    3. bot-gateway (飞书长连接 + CardKit)"
  echo "  Region: $REGION | Account: $ACCOUNT_ID"
  say ok "Dry-run complete (no changes made)"
  exit 0
fi

# ============================================================
# Phase 1: index-service
# ============================================================
if [[ "$SKIP_INDEX" == false && "$ONLY_AGENT" == false && "$ONLY_GATEWAY" == false ]]; then
  say step "Phase 1: index-service"
  # TODO(p1): EFS setup + CodeGraph container + MCP bridge deploy
  say warn "index-service deploy: not yet implemented (桩·未验证)"
  echo ""
fi

# ============================================================
# Phase 2: AgentCore Runtime (agent-container)
# ============================================================
if [[ "$ONLY_INDEX" == false && "$ONLY_GATEWAY" == false ]]; then
  say step "Phase 2: AgentCore Runtime (agent-container)"
  # TODO(p1): boto3 create/update_agent_runtime
  #   - Build ARM64 image → push ECR
  #   - create_agent_runtime or update_agent_runtime (idempotent by RUNTIME_ID in deploy-config)
  #   - Wait READY
  #   - Persist RUNTIME_ID + RUNTIME_ARN to deploy-config
  say warn "AgentCore Runtime deploy: not yet implemented (桩·未验证)"
  echo ""
fi

# ============================================================
# Phase 3: bot-gateway
# ============================================================
if [[ "$SKIP_GATEWAY" == false && "$ONLY_AGENT" == false && "$ONLY_INDEX" == false ]]; then
  say step "Phase 3: bot-gateway"
  # TODO(p1): npm install + build + systemd/ECS deploy
  say warn "bot-gateway deploy: not yet implemented (桩·未验证)"
  echo ""
fi

# ============================================================
# Done
# ============================================================
say ok "deploy.sh complete (idempotent)"
