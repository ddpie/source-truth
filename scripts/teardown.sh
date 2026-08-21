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
# (AgentCore runtimes are enumerated directly at delete time — see phase 1 below — not from config.)
# Discover ALL index-service instances by tag, then UNION with the config-recorded id.
# The TAG SWEEP is the load-bearing half and stays that way: deploys only ever update the
# one host in place, but more than one tagged instance can still be alive (a hand-launched
# box, an instance the config never captured because the deploy died mid-run, a stale
# config file), and the old tag query used `Reservations[].Instances[0]` (first per
# reservation) + only the config var, so it could miss a second tagged instance and
# leave it billing after reporting "teardown complete" (cross-review P1). Collect every
# `Instances[].InstanceId` across all reservations + the config id, dedup, terminate all.
# Both tag names: source-truth-index-service (default two-machine) AND source-truth-host (the
# --local single host launch-host.sh creates). Missing the latter left the --local box billing and,
# because its ENI kept the VPC's SG/subnet pinned, cascaded into DependencyViolation on VPC delete.
TAGGED_INSTANCES="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service,source-truth-host" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")"
# space-separated, deduped union of the config id + every tagged id. CRITICAL: `|| true`
# on the pipeline — `grep -v` exits 1 when NOTHING matches (the zero-instances case: EC2
# already torn down but NAT/EIP/zone still billing), and under `set -euo pipefail` that
# rc-1 would ABORT teardown right here, BEFORE the plan/confirm/delete phases — i.e. the
# script would refuse to run in the exact leak scenario it exists to clean up (2nd-pass
# cross-review P1). The `|| true` makes an empty result a clean empty string.
ALL_INSTANCES="$( { printf '%s\n' ${INDEX_SERVICE_INSTANCE:-} $TAGGED_INSTANCES | grep -vE '^(None)?$' | sort -u | tr '\n' ' '; } || true )"
# (No separate EC2_ID: the full deduped ALL_INSTANCES set is both displayed in the plan
# and terminated in the loop below; the SG/ENI-drain later discovers the SG by group-name,
# not via an instance id, so no single "primary" id is needed.)
VPC="${VPC_ID:-}"; is_set "$VPC" || VPC="$(by_tag vpcs source-truth-vpc Vpcs VpcId)"
NAT="${NAT_GATEWAY:-}"; is_set "$NAT" || NAT="$(Q describe-nat-gateways --filter "Name=tag:Name,Values=source-truth-nat" "Name=state,Values=available,pending" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "")"
ZONE_ID="${INDEX_DNS_ZONE_ID:-}"

say step "teardown plan — region $REGION, account ${ACCOUNT:-?}"
say info "  AgentCore runtimes: all source_truth_agent* (enumerated at delete)"
say info "  index-service EC2 : ${ALL_INSTANCES:-<none>}"
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
TEARDOWN_INCOMPLETE=0
LEFT_BEHIND=""

# del <what> <cmd...> — delete one resource, telling the truth about the outcome.
#
# The previous one-liner collapsed EVERY failure into "may already be gone" with stdout and
# stderr discarded, so AccessDenied, DependencyViolation, DeleteConflict, BucketNotEmpty,
# throttling and genuinely-absent were indistinguishable — and the script still exited 0. Two
# structural bugs (an EventBridge target id mismatch and an undetached managed policy) sat
# invisible behind that message while printing a green check.
del() {
  local what="$1"; shift
  local err
  if err="$("$@" 2>&1 >/dev/null)"; then
    say ok "deleted $what"
    return 0
  fi
  # Resource-specific not-found codes are the ONLY genuine success-by-absence.
  if printf '%s' "$err" | grep -qE 'NotFound|NoSuchEntity|NoSuchBucket|ResourceNotFoundException|does not exist|NoSuchHostedZone'; then
    say ok "$what already gone"
    return 0
  fi
  say warn "FAILED $what — $(printf '%s' "$err" | tr -d '\n' | cut -c1-200)"
  TEARDOWN_INCOMPLETE=$((TEARDOWN_INCOMPLETE + 1))
  LEFT_BEHIND="${LEFT_BEHIND}
  • ${what}"
  return 0
}

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
  # MUST be 0, not 1: every call site is a bare command under `set -euo pipefail`, so returning
  # non-zero here ABORTED the whole teardown at the first slow NAT — the EIP was never released,
  # the VPC/SGs/subnets were never touched, and monitoring cleanup never ran, all while the
  # operator read a warning that promised the opposite ("continuing"). A wait timeout is a
  # degraded outcome to record, not a reason to stop cleaning up. TEARDOWN_INCOMPLETE carries
  # the signal to the final exit code instead.
  TEARDOWN_INCOMPLETE=$((TEARDOWN_INCOMPLETE + 1))
  return 0
}

# ---- 1. AgentCore runtime(s) (boto3; no aws-cli verb in older CLIs) ----
# Multi-project: there is ONE runtime PER project, named source_truth_agent_<projectId> (plus the
# legacy single source_truth_agent). The config no longer records a single AGENT_RUNTIME_ID, so
# ENUMERATE every runtime whose name starts with source_truth_agent and delete each — otherwise a
# per-project runtime survives teardown and keeps billing (cross-review HIGH).
say info "deleting all source_truth_agent* AgentCore runtimes ..."
python3 - "$REGION" <<'PY' 2>/dev/null || say warn "runtime enumeration/delete had issues (some may already be gone)"
import sys, boto3
region = sys.argv[1]
c = boto3.client("bedrock-agentcore-control", region_name=region)
deleted = 0
token = None
ids = []
while True:
    kw = {"maxResults": 100}
    if token: kw["nextToken"] = token
    resp = c.list_agent_runtimes(**kw)
    for rt in resp.get("agentRuntimes", []):
        if rt.get("agentRuntimeName", "").startswith("source_truth_agent"):
            ids.append(rt["agentRuntimeId"])
    token = resp.get("nextToken")
    if not token: break
for rid in ids:
    try:
        c.delete_agent_runtime(agentRuntimeId=rid); deleted += 1
        print(f"deleted runtime {rid}")
    except Exception as e:
        print(f"skip {rid}: {e}")
print(f"runtimes deleted: {deleted}")
PY
# The runtimes hold requester-managed ENIs in the private subnet; AWS releases them
# ASYNCHRONOUSLY (often 1-5 min). We wait for them to clear before the VPC teardown below
# (an ENI still attached makes delete-subnet/SG/VPC fail with DependencyViolation). The wait is
# keyed on the index SG further down.

# ---- 2. EC2 index-service instance(s) — terminate EVERY discovered one ----
# Iterate the full deduped union (tag-discovered + the config id), not just the config
# var, so an instance the config never recorded can't survive teardown and keep billing.
for inst in $ALL_INSTANCES; do
  if is_set "$inst"; then
    # Termination protection is enabled at provision time (arm_instance_resilience) to stop an
    # accidental console/CLI terminate. It also makes terminate-instances fail outright, so
    # teardown MUST clear it first or the host survives every teardown and the operator is left
    # with an instance they cannot delete from the documented path. Best-effort: an instance that
    # never had it set, or is already gone, must not abort the teardown.
    Q modify-instance-attribute --instance-id "$inst" --no-disable-api-termination >/dev/null 2>&1 || true
    del "instance $inst" Q terminate-instances --instance-ids "$inst"
    Q wait instance-terminated --instance-ids "$inst" 2>/dev/null || true
  fi
done

# ---- 3. Route53 private hosted zone (records first, then the zone) ----
# Discover by config id → by VPC → by NAME. The name fallback matters because a 2-pass
# teardown (common when pass 1 times out on ENI drain) may have ALREADY deleted the VPC,
# after which list-hosted-zones-by-vpc returns nothing and the (paid $0.50/mo) zone would
# leak with no way to find it (cross-review P2). list-hosted-zones is global, so match the
# private zone by its DNS name as a last resort. (A name collision with an unrelated
# `source-truth.internal` PRIVATE zone in the same account is implausible and still only
# deletes a zone matching THIS project's name.)
is_set "$ZONE_ID" || { is_set "$VPC" && ZONE_ID="$(aws route53 list-hosted-zones-by-vpc --vpc-id "$VPC" --vpc-region "$REGION" --query "HostedZoneSummaries[?Name=='source-truth.internal.'].HostedZoneId | [0]" --output text 2>/dev/null || echo "")"; }
if ! is_set "$ZONE_ID"; then
  # Name fallback, but REGION-SCOPED: source-truth.internal is account-global, so a
  # multi-region/same-account setup could have several. Only adopt a candidate whose VPC
  # associations include one in THIS region — otherwise `teardown --region A` could delete
  # region B's still-live zone (2nd-pass cross-review P2). Walk each same-named private
  # zone and check its GetHostedZone VPCs for a match on $REGION.
  for cand in $(aws route53 list-hosted-zones --query "HostedZones[?Name=='source-truth.internal.' && Config.PrivateZone].Id" --output text 2>/dev/null | sed 's#/hostedzone/##'); do
    if aws route53 get-hosted-zone --id "$cand" --query 'VPCs[].VPCRegion' --output text 2>/dev/null | grep -qw "$REGION"; then
      ZONE_ID="$cand"; break
    fi
  done
fi
if is_set "$ZONE_ID"; then
  # The private zone `source-truth.internal` is SHARED across regions: each region owns its OWN
  # record `index.<region>.source-truth.internal` (see provision_index_dns.sh). So we must NOT wipe
  # every record + the whole zone — that would kill OTHER regions' live records (and their VPCs still
  # rely on the zone). Delete ONLY this region's record; drop the zone only if nothing region-scoped
  # is left (this was the last region). config-id ($INDEX_DNS_ZONE_ID) may point at that shared zone.
  OUR_REC="index.${REGION}.source-truth.internal."
  rec="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${OUR_REC}' && Type=='A']" --output json 2>/dev/null || echo "[]")"
  if [[ "$rec" != "[]" && -n "$rec" ]]; then
    batch="$(python3 -c "import json,sys; rs=json.load(sys.stdin); print(json.dumps({'Changes':[{'Action':'DELETE','ResourceRecordSet':r} for r in rs]}))" <<<"$rec" 2>/dev/null || echo "")"
    [[ -n "$batch" ]] && del "DNS record ${OUR_REC}" aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$batch"
  fi
  # Delete the zone only if no A records remain (no other region uses it). Route53 keeps SOA+NS.
  remaining="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query "ResourceRecordSets[?Type=='A'] | length(@)" --output text 2>/dev/null || echo "?")"
  if [[ "$remaining" == "0" ]]; then
    del "hosted zone $ZONE_ID (no records left)" aws route53 delete-hosted-zone --id "$ZONE_ID"
  else
    say info "保留共享私有区 $ZONE_ID（仍有其它区域记录：$remaining 条 A）——只删本区域的记录"
  fi
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
  # Our runtime SG (source-truth-index-svc). Wait for its ENIs before deleting anything.
  SG="$(Q describe-security-groups --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")"
  if is_set "$SG"; then
    wait_gone "ENIs on SG $SG" 300 Q describe-network-interfaces \
      --filters "Name=group-id,Values=$SG" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  fi
  is_set "${PRIVATE_SUBNET:-}" && wait_gone "ENIs in subnet $PRIVATE_SUBNET" 120 Q describe-network-interfaces \
    --filters "Name=subnet-id,Values=$PRIVATE_SUBNET" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  # Delete EVERY non-default SG in the VPC — not just index-svc. --local also creates
  # source-truth-host (SSH SG); a leftover SG pins the VPC and fails delete-vpc. The VPC is
  # ours (source-truth-vpc tag), so its non-default SGs are all ours. Retry-friendly: a SG still
  # referenced by a not-yet-released ENI fails here and a re-run finishes it.
  for sg in $(Q describe-security-groups --filters "Name=vpc-id,Values=$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || echo ""); do
    del "security group $sg" Q delete-security-group --group-id "$sg"
  done

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

  # Flow logs + custom NACLs (both added by provision_network.sh: H7 / H5). Removed explicitly
  # rather than relying on delete-vpc cascade, so they can never be the thing that pins the VPC.
  for fl in $(Q describe-flow-logs --filter "Name=resource-id,Values=$VPC" --query 'FlowLogs[].FlowLogId' --output text 2>/dev/null || echo ""); do
    is_set "$fl" && del "flow log $fl" Q delete-flow-logs --flow-log-ids "$fl"
  done
  for acl in $(Q describe-network-acls --filters "Name=vpc-id,Values=$VPC" --query 'NetworkAcls[?IsDefault==`false`].NetworkAclId' --output text 2>/dev/null || echo ""); do
    is_set "$acl" && del "network acl $acl" Q delete-network-acl --network-acl-id "$acl"
  done

  # delete-vpc with a BOUNDED RETRY. A NAT gateway's ENI keeps draining for a while after the NAT
  # is deleted, so the first attempt can lose a race and fail with DependencyViolation. The old
  # code made one attempt through `del`, which reports "may already be gone" on failure — so a
  # VPC that was very much still there leaked silently, burning one of the account's 5 VPC slots
  # on every teardown (observed 2026-08-20). Retry, then report the REAL API error.
  vpc_err=""
  for attempt in 1 2 3 4 5 6; do
    if vpc_err="$(Q delete-vpc --vpc-id "$VPC" 2>&1 >/dev/null)"; then
      say ok "deleted VPC $VPC"
      vpc_err=""
      break
    fi
    # Gone already (a 2nd-pass teardown) is success, not a failure to retry.
    if printf '%s' "$vpc_err" | grep -q InvalidVpcID.NotFound; then
      say ok "VPC $VPC already gone"
      vpc_err=""
      break
    fi
    [[ $attempt -lt 6 ]] && sleep 10
  done
  if [[ -n "$vpc_err" ]]; then
    say err "VPC $VPC NOT deleted — it is still billable-adjacent and holds a VPC-quota slot"
    say err "  → $(printf '%s' "$vpc_err" | tr -d '\n' | cut -c1-300)"
    say err "  re-run this teardown, or delete the remaining dependency shown above by hand"
  fi
fi

# ---- 6. monitoring stack (region-scoped, best-effort — Phase 7 of deploy-all builds it) ----
# DAU Lambda + its EventBridge daily rule (+ the lambda permission that rule installs).
# Enumerate the target ids instead of guessing one. `--ids 1` never matched: apply-dau-lambda.sh
# registers Id=dau. remove-targets is a BATCH api that exits 0 and reports per-entry failure only
# in its response body, so the mismatch printed a green check while the target survived — and
# EventBridge then refuses to delete a rule that still has targets, so the rule leaked too
# (firing daily at a Lambda this script had already deleted).
_DAU_TARGET_IDS="$(aws events list-targets-by-rule --region "$REGION" --rule source-truth-dau-daily --query 'Targets[].Id' --output text 2>/dev/null || echo "")"
if is_set "$_DAU_TARGET_IDS"; then
  # shellcheck disable=SC2086  # deliberate word-split: --ids takes a list
  del "EventBridge rule source-truth-dau-daily targets ($_DAU_TARGET_IDS)" aws events remove-targets --region "$REGION" --rule source-truth-dau-daily --ids $_DAU_TARGET_IDS
fi
del "EventBridge rule source-truth-dau-daily" aws events delete-rule --region "$REGION" --name source-truth-dau-daily
del "Lambda source-truth-dau-preaggregate" aws lambda delete-function --region "$REGION" --function-name source-truth-dau-preaggregate
# Dashboards (both pages).
del "dashboards source-truth-{product,sre,by-project}" aws cloudwatch delete-dashboards --region "$REGION" \
  --dashboard-names source-truth-product source-truth-sre source-truth-by-project
# Alarms (enumerate by our prefix — the set grows) + the SNS topic they notify.
ALARMS="$(aws cloudwatch describe-alarms --region "$REGION" --alarm-name-prefix source-truth --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null || echo "")"
is_set "$ALARMS" && del "CloudWatch alarms ($ALARMS)" aws cloudwatch delete-alarms --region "$REGION" --alarm-names $ALARMS
TOPIC="$(aws sns list-topics --region "$REGION" --query "Topics[?ends_with(TopicArn, ':source-truth-alarms')].TopicArn | [0]" --output text 2>/dev/null || echo "")"
[[ "$TOPIC" == "None" ]] && TOPIC=""
is_set "$TOPIC" && del "SNS topic source-truth-alarms" aws sns delete-topic --region "$REGION" --topic-arn "$TOPIC"
# Metric filters live on the gateway log group; deleting the log group (or the filters) is optional —
# they stop costing once the log group is gone. Delete our filters by name best-effort.
GW_LOG="/source-truth/bot-gateway"
for mf in $(aws logs describe-metric-filters --region "$REGION" --log-group-name "$GW_LOG" --query 'metricFilters[].filterName' --output text 2>/dev/null || echo ""); do
  del "metric filter $mf" aws logs delete-metric-filter --region "$REGION" --log-group-name "$GW_LOG" --filter-name "$mf"
done

# ---- 7. ECR repository (region-scoped) ----
del "ECR repo source-truth/agent" aws ecr delete-repository --repository-name source-truth/agent --region "$REGION" --force

# ---- 8. shared resources (opt-in) ----
if [[ "$INCLUDE_SHARED" == true ]]; then
  # CROSS-REGION GUARD: the IAM roles + S3 bucket are ACCOUNT-global and shared by every region's
  # host. Deleting them while another region still runs a host would instantly break its
  # S3/Secrets/Bedrock access. Refuse if any source-truth host exists in ANOTHER region.
  OTHER=""
  for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null || echo ""); do
    [[ "$r" == "$REGION" ]] && continue
    hit="$(aws ec2 describe-instances --region "$r" \
      --filters "Name=tag:Name,Values=source-truth-index-service,source-truth-host" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")"
    is_set "$hit" && OTHER="$OTHER $r"
  done
  if is_set "$OTHER"; then
    say warn "跳过共享 IAM 角色 + S3 桶：其它区域仍有 source-truth 主机在跑（$OTHER）——删了会让那些机器失权。"
    say info "  等所有区域都拆完，再在最后一个区域跑 --include-shared。"
  else
  # DAU Lambda's IAM role (account-global, created by apply-monitoring.sh's dau stage).
  # Detach MANAGED policies before deleting a role: delete-role fails with DeleteConflict while
  # any remains. Applied to ALL THREE roles via one helper \u2014 the enumerate-don't-name fix was
  # first written for the DAU role only, leaving source-truth-index-role deleting a single ARN by
  # name and SourceTruthAgentRuntimeRole detaching nothing, so either could still leak.
  detach_managed() { # <role-name>
    local r="$1" pa
    for pa in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo ""); do
      is_set "$pa" && aws iam detach-role-policy --role-name "$r" --policy-arn "$pa" >/dev/null 2>&1 || true
    done
  }

  detach_managed source-truth-dau-lambda-role
  for p in $(aws iam list-role-policies --role-name source-truth-dau-lambda-role --query 'PolicyNames[]' --output text 2>/dev/null || echo ""); do
    aws iam delete-role-policy --role-name source-truth-dau-lambda-role --policy-name "$p" >/dev/null 2>&1 || true
  done
  del "IAM role source-truth-dau-lambda-role" aws iam delete-role --role-name source-truth-dau-lambda-role
  # IAM index role: detach managed, delete inline + profile, then the role.
  aws iam remove-role-from-instance-profile --instance-profile-name source-truth-index-profile --role-name source-truth-index-role >/dev/null 2>&1 || true
  del "instance profile source-truth-index-profile" aws iam delete-instance-profile --instance-profile-name source-truth-index-profile
  detach_managed source-truth-index-role
  # Delete ALL inline policies before the role (delete-role fails if any remain). Enumerate
  # rather than name them (the set grew: s3-artifacts, secrets-read, cloudwatch-logs, …).
  for p in $(aws iam list-role-policies --role-name source-truth-index-role --query 'PolicyNames[]' --output text 2>/dev/null || echo ""); do
    aws iam delete-role-policy --role-name source-truth-index-role --policy-name "$p" >/dev/null 2>&1 || true
  done
  del "IAM role source-truth-index-role" aws iam delete-role --role-name source-truth-index-role
  # Runtime role: delete any inline policies, then the role.
  detach_managed SourceTruthAgentRuntimeRole
  for p in $(aws iam list-role-policies --role-name SourceTruthAgentRuntimeRole --query 'PolicyNames[]' --output text 2>/dev/null || echo ""); do
    aws iam delete-role-policy --role-name SourceTruthAgentRuntimeRole --policy-name "$p" >/dev/null 2>&1 || true
  done
  del "IAM role SourceTruthAgentRuntimeRole" aws iam delete-role --role-name SourceTruthAgentRuntimeRole
  # S3 artifact bucket (empty then delete).
  if is_set "${ARTIFACT_BUCKET:-}"; then
    aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive >/dev/null 2>&1 || true
    del "S3 bucket ${ARTIFACT_BUCKET}" aws s3api delete-bucket --bucket "${ARTIFACT_BUCKET}" --region "$REGION"
  fi
  fi   # cross-region guard
fi

say info "verify no billable orphans:  aws ec2 describe-nat-gateways --region $REGION --filter Name=tag:Name,Values=source-truth-nat"

# RETAINED BY DESIGN — these are never deleted by a default run, and staying silent about them
# is how a "complete" teardown quietly keeps billing. Secrets are ~$0.40/mo each and the log
# groups keep storage charges (the Lambda one has no retention at all).
say info "RETAINED (billable, delete by hand or with --include-shared):"
say info "  • Secrets Manager: source-truth/feishu-<projectId>, /log-hash-salt, /git-credentials, /deploy-github-token"
say info "  • Log groups: /source-truth/bot-gateway, /source-truth/index-bridge, /aws/lambda/source-truth-dau-preaggregate"
if [[ "$INCLUDE_SHARED" != true ]]; then
  say info "  • IAM roles + instance profile + S3 artifact bucket (pass --include-shared to remove)"
fi

# Exit non-zero when anything actually failed, so CI and the operator can tell a partial
# teardown from a clean one. The old script exited 0 unconditionally.
#
# The success line lives HERE, not above: printed unconditionally it sat directly above the
# failure report, so an operator saw a green "complete" over a red "INCOMPLETE", and any wrapper
# grepping for "teardown complete" reported success on a run that leaked a billable VPC.
if [[ "$TEARDOWN_INCOMPLETE" -gt 0 ]]; then
  say err "teardown INCOMPLETE — ${TEARDOWN_INCOMPLETE} operation(s) failed:${LEFT_BEHIND}"
  say err "re-run this teardown; resources above may still be billable"
  exit 1
fi
say ok "teardown complete for $REGION"
