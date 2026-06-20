#!/usr/bin/env bash
#
# teardown.sh — tear down EVERYTHING deploy-all.sh created, in reverse-dependency
# order, in one region. The companion to the one-click deploy: a fresh-account trial
# (or a deploy that died midway) otherwise leaves BILLABLE orphans — NAT gateway
# (~$32/mo), an Elastic IP, the index-service EC2 — with no built-in way to find or
# remove them. This finds each resource from .local/deploy-config first, then falls
# back to its `source-truth-*` Name tag, so it works even when the config is partial
# (a mid-deploy crash) or absent (a different machine).
#
#   ./scripts/teardown.sh --region <r>            # prints the plan, asks to confirm
#   ./scripts/teardown.sh --region <r> --dry-run  # plan only, deletes nothing
#   ./scripts/teardown.sh --region <r> --yes      # skip the interactive confirm
#
# DESTRUCTIVE + irreversible. Per AGENTS.md this is an "ask first" operation: it
# refuses to run without an explicit --yes or an interactive "yes" at the prompt.
# IAM roles (source-truth-index-role / SourceTruthAgentRuntimeRole) and the S3
# artifact bucket are account/region-shared and only removed with --include-shared.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/env-utils.sh
source "$SCRIPT_DIR/lib/env-utils.sh"

CONFIG_FILE="$ROOT/.local/deploy-config"
REGION=""
DRY_RUN=false
ASSUME_YES=false
INCLUDE_SHARED=false

usage() {
  cat <<EOF
Usage: $0 --region <r> [--dry-run] [--yes] [--include-shared]
  --region <r>        AWS region to tear down (required)
  --dry-run           print the deletion plan, change nothing
  --yes               skip the interactive confirmation
  --include-shared    ALSO delete the IAM roles + S3 artifact bucket (account-shared)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --include-shared) INCLUDE_SHARED=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { say err "--region is required"; usage; exit 2; }
require_cmd aws || exit 1

# Read back whatever the deploy persisted (resource IDs). Missing file is fine —
# we fall back to tag discovery for every resource.
if [[ -f "$CONFIG_FILE" ]]; then safe_source_env "$CONFIG_FILE"; fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
Q() { aws ec2 "$@" --region "$REGION"; }
# by_tag <ec2-resource-plural> <name-tag> <JMESPath-list> [IdField] — discover an id
# by its source-truth Name tag (fallback when the config didn't capture it). Prints
# the id or empty; never fails the script (a missing resource is the normal case).
by_tag() { Q describe-"$1" --filters "Name=tag:Name,Values=$2" --query "${3}[0].${4:-${1%s}Id}" --output text 2>/dev/null || echo ""; }
is_set() { [[ -n "${1:-}" && "${1:-}" != "None" ]]; }

# --- discover (config first, then tag) ---
RT_ID="${AGENT_RUNTIME_ID:-}"
EC2_ID="${INDEX_SERVICE_INSTANCE:-}"; is_set "$EC2_ID" || EC2_ID="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null || echo "")"
OLD_EC2_ID="${INDEX_OLD_INSTANCE:-}"
VPC="${VPC_ID:-}"; is_set "$VPC" || VPC="$(by_tag vpcs source-truth-vpc Vpcs VpcId)"
NAT="${NAT_GATEWAY:-}"; is_set "$NAT" || NAT="$(Q describe-nat-gateways --filter "Name=tag:Name,Values=source-truth-nat" "Name=state,Values=available,pending" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "")"
ZONE_ID="${INDEX_DNS_ZONE_ID:-}"

say step "teardown plan — region $REGION, account ${ACCOUNT:-?}"
say info "  AgentCore runtime : ${RT_ID:-<none>}"
say info "  index-service EC2 : ${EC2_ID:-<none>}${OLD_EC2_ID:+ (+ old $OLD_EC2_ID)}"
say info "  NAT gateway       : ${NAT:-<none>} (+ its Elastic IP)"
say info "  VPC + subnets/RT/IGW/SG : ${VPC:-<none>}"
say info "  Route53 private zone    : ${ZONE_ID:-<discover by VPC>}"
say info "  ECR repo source-truth/agent : (in $REGION)"
if [[ "$INCLUDE_SHARED" == true ]]; then
  say warn "  SHARED (--include-shared): IAM roles + S3 artifact bucket WILL be deleted"
else
  say info "  IAM roles + S3 bucket    : KEPT (pass --include-shared to remove)"
fi

if [[ "$DRY_RUN" == true ]]; then say ok "[dry-run] nothing deleted"; exit 0; fi

if [[ "$ASSUME_YES" != true ]]; then
  printf '%s' "Type 'yes' to DELETE the above in $REGION: " >&2
  read -r reply
  [[ "$reply" == "yes" ]] || { say warn "aborted (no 'yes')"; exit 1; }
fi

# Helper: run a delete, tolerate "already gone", log each step. Never aborts the
# whole teardown on one resource's failure — we want to remove as much as possible.
del() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then say ok "deleted $what"; else say warn "skip/failed $what (may already be gone)"; fi; }

# wait_gone <desc> <max_secs> <cmd...> — poll until <cmd> prints empty/None (the
# resource is gone), or the timeout elapses. AWS deletes for NAT/ENI are ASYNC, so a
# one-shot `aws wait` that times out under throttling would let the NEXT step (EIP
# release / subnet delete) run while the dependency still holds → a stranded billable
# orphan, the exact thing teardown exists to prevent (cross-review). Polls every 5s.
wait_gone() {
  local desc="$1" max="$2"; shift 2
  local waited=0 left
  while [[ "$waited" -lt "$max" ]]; do
    left="$("$@" 2>/dev/null || echo "")"
    if [[ -z "$left" || "$left" == "None" ]]; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  say warn "$desc still present after ${max}s — continuing (may strand a dependent resource; re-run teardown)"
  return 1
}

# ---- 1. AgentCore runtime (boto3; no aws-cli verb in older CLIs) ----
if is_set "$RT_ID"; then
  if python3 - "$REGION" "$RT_ID" <<'PY' 2>/dev/null; then say ok "deleted runtime $RT_ID"; else say warn "skip/failed runtime (may already be gone)"; fi
import sys, boto3
region, rid = sys.argv[1], sys.argv[2]
boto3.client("bedrock-agentcore-control", region_name=region).delete_agent_runtime(agentRuntimeId=rid)
PY
  # The runtime holds requester-managed ENIs in the private subnet; AWS releases them
  # ASYNCHRONOUSLY (often 1-5 min). We wait for them to clear before the VPC teardown
  # below (an ENI still attached makes delete-subnet/SG/VPC fail with
  # DependencyViolation → those strand). The wait is keyed on the index SG further down.
fi

# ---- 2. EC2 index-service instance(s) ----
for inst in "$EC2_ID" "$OLD_EC2_ID"; do
  if is_set "$inst"; then
    del "instance $inst" Q terminate-instances --instance-ids "$inst"
    Q wait instance-terminated --instance-ids "$inst" 2>/dev/null || true
  fi
done

# ---- 3. Route53 private hosted zone (records first, then the zone) ----
is_set "$ZONE_ID" || { is_set "$VPC" && ZONE_ID="$(aws route53 list-hosted-zones-by-vpc --vpc-id "$VPC" --vpc-region "$REGION" --query "HostedZoneSummaries[?Name=='source-truth.internal.'].HostedZoneId | [0]" --output text 2>/dev/null || echo "")"; }
if is_set "$ZONE_ID"; then
  # Delete every non-SOA/NS record set, then the zone (Route53 refuses a non-empty zone).
  recs="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query "ResourceRecordSets[?Type!='SOA' && Type!='NS']" --output json 2>/dev/null || echo "[]")"
  if [[ "$recs" != "[]" && -n "$recs" ]]; then
    batch="$(python3 -c "import json,sys; rs=json.load(sys.stdin); print(json.dumps({'Changes':[{'Action':'DELETE','ResourceRecordSet':r} for r in rs]}))" <<<"$recs" 2>/dev/null || echo "")"
    [[ -n "$batch" ]] && aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$batch" >/dev/null 2>&1 || true
  fi
  del "hosted zone $ZONE_ID" aws route53 delete-hosted-zone --id "$ZONE_ID"
fi

# ---- 4. NAT gateway + release its Elastic IP ----
if is_set "$NAT"; then
  # Capture the EIP allocation BEFORE deleting the NAT (it's reported on the NAT).
  EIP_ALLOC="$(Q describe-nat-gateways --nat-gateway-ids "$NAT" --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "")"
  del "NAT gateway $NAT" Q delete-nat-gateway --nat-gateway-id "$NAT"
  # Wait until the NAT is truly DELETED before releasing its EIP — release-address
  # fails while the EIP is still associated with a deleting NAT, which would strand
  # the (billable) EIP (cross-review P0). Poll, don't one-shot.
  wait_gone "NAT $NAT" 300 Q describe-nat-gateways --nat-gateway-ids "$NAT" \
    --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text
fi
# Release the NAT EIP — by captured alloc, else by its Name tag (covers a NAT that
# was already gone but left its EIP allocated, the exact mid-deploy-crash orphan).
is_set "${EIP_ALLOC:-}" || EIP_ALLOC="$(Q describe-addresses --filters "Name=tag:Name,Values=source-truth-nat-eip" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "")"
is_set "${EIP_ALLOC:-}" && del "Elastic IP $EIP_ALLOC" Q release-address --allocation-id "$EIP_ALLOC"

# ---- 5. VPC teardown (subnets, route tables, IGW, SG) then the VPC ----
if is_set "$VPC"; then
  # The AgentCore runtime + the index EC2 leave requester-managed ENIs in the VPC that
  # AWS releases asynchronously; deleting a subnet/SG/VPC while one is still attached
  # fails with DependencyViolation and STRANDS that resource (cross-review P1). Wait
  # for the project's ENIs (those on the index SG, and any in the private subnet) to
  # clear first. Bounded — if they linger, we warn and a re-run finishes the job.
  SG="$(Q describe-security-groups --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")"
  if is_set "$SG"; then
    wait_gone "ENIs on SG $SG" 300 Q describe-network-interfaces \
      --filters "Name=group-id,Values=$SG" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  fi
  is_set "${PRIVATE_SUBNET:-}" && wait_gone "ENIs in subnet $PRIVATE_SUBNET" 120 Q describe-network-interfaces \
    --filters "Name=subnet-id,Values=$PRIVATE_SUBNET" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  # Security group (non-default): delete after the instance + ENIs are gone.
  is_set "$SG" && del "security group $SG" Q delete-security-group --group-id "$SG"

  # Detach + delete the internet gateway.
  IGW="$(Q describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")"
  if is_set "$IGW"; then
    del "detach IGW $IGW" Q detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
    del "IGW $IGW" Q delete-internet-gateway --internet-gateway-id "$IGW"
  fi

  # Subnets.
  for sn in $(Q describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo ""); do
    del "subnet $sn" Q delete-subnet --subnet-id "$sn"
  done

  # Non-main route tables (the main one is deleted with the VPC).
  for rt in $(Q describe-route-tables --filters "Name=vpc-id,Values=$VPC" --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text 2>/dev/null || echo ""); do
    del "route table $rt" Q delete-route-table --route-table-id "$rt"
  done

  del "VPC $VPC" Q delete-vpc --vpc-id "$VPC"
fi

# ---- 6. ECR repository (region-scoped) ----
del "ECR repo source-truth/agent" aws ecr delete-repository --repository-name source-truth/agent --region "$REGION" --force

# ---- 7. shared resources (opt-in) ----
if [[ "$INCLUDE_SHARED" == true ]]; then
  # IAM index role: detach managed, delete inline + profile, then the role.
  aws iam remove-role-from-instance-profile --instance-profile-name source-truth-index-profile --role-name source-truth-index-role >/dev/null 2>&1 || true
  del "instance profile source-truth-index-profile" aws iam delete-instance-profile --instance-profile-name source-truth-index-profile
  aws iam detach-role-policy --role-name source-truth-index-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name source-truth-index-role --policy-name s3-artifacts >/dev/null 2>&1 || true
  del "IAM role source-truth-index-role" aws iam delete-role --role-name source-truth-index-role
  # Runtime role: delete any inline policies, then the role.
  for p in $(aws iam list-role-policies --role-name SourceTruthAgentRuntimeRole --query 'PolicyNames[]' --output text 2>/dev/null || echo ""); do
    aws iam delete-role-policy --role-name SourceTruthAgentRuntimeRole --policy-name "$p" >/dev/null 2>&1 || true
  done
  del "IAM role SourceTruthAgentRuntimeRole" aws iam delete-role --role-name SourceTruthAgentRuntimeRole
  # S3 artifact bucket (empty then delete).
  if is_set "${ARTIFACT_BUCKET:-}"; then
    aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive >/dev/null 2>&1 || true
    del "S3 bucket ${ARTIFACT_BUCKET}" aws s3api delete-bucket --bucket "${ARTIFACT_BUCKET}" --region "$REGION"
  fi
fi

say ok "teardown complete for $REGION"
say info "verify no billable orphans:  aws ec2 describe-nat-gateways --region $REGION --filter Name=tag:Name,Values=source-truth-nat"
