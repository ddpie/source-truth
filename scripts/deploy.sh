#!/usr/bin/env bash
# deploy.sh — DEPRECATED compatibility shim. Use scripts/deploy-all.sh.
#
# The original deploy.sh had stub (unimplemented) index-service and bot-gateway
# phases, so running it produced a half-broken deploy. The real, verified,
# fresh-account-capable orchestrator is scripts/deploy-all.sh (artifacts → IAM →
# network → index-service → image build/push → AgentCore runtime; idempotent;
# --dry-run safe). This shim forwards compatible flags to deploy-all.sh so anyone
# still invoking deploy.sh lands on the working path, and prints a deprecation note.
#
# Usage:
#   ./scripts/deploy.sh [--region <r>] [--repo <path>] [--dry-run] [-h|--help]
#   (delegates to deploy-all.sh; idempotent = re-run updates in place / 幂等)
#
# Flags forwarded as-is: --region, --repo, --dry-run, --skip <phase>.
# Legacy --only-* / --skip-* flags are mapped to deploy-all.sh's --skip <phase>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy.sh [FLAGS]   (DEPRECATED — delegates to deploy-all.sh)

deploy.sh is a compatibility shim. The canonical one-click orchestrator is
scripts/deploy-all.sh (idempotent = upgrade / 幂等; --dry-run safe).

Flags (forwarded to deploy-all.sh):
  --region <r>     AWS region
  --repo <path>    Local repo to index + serve (required for a full deploy)
  --dry-run        Print the plan; make no changes
  --skip <phase>   Skip a phase: artifacts|iam|network|index-svc|image|runtime
  -h, --help       Show this help

See scripts/deploy-all.sh --help for the full, current interface.
EOF
}

FWD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --region|--repo|--skip) FWD+=("$1" "$2"); shift 2 ;;
    --dry-run) FWD+=("$1"); shift ;;
    # Legacy flag mappings → deploy-all.sh --skip <phase>.
    --only-agent)   FWD+=(--skip artifacts --skip iam --skip network --skip index-svc); shift ;;
    --only-index)   FWD+=(--skip image --skip runtime); shift ;;
    --only-gateway) say err "bot-gateway is not part of deploy-all.sh; deploy it separately."; exit 2 ;;
    --skip-index)   FWD+=(--skip index-svc); shift ;;
    --skip-gateway) shift ;;  # no gateway phase in deploy-all.sh; no-op
    *) say err "Unknown flag: $1"; usage >&2; exit 2 ;;
  esac
done

say warn "deploy.sh is DEPRECATED — delegating to deploy-all.sh (the working orchestrator)."
exec "$SCRIPT_DIR/deploy-all.sh" "${FWD[@]}"
