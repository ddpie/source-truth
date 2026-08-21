#!/usr/bin/env bash
# provision_network.sh <region> <config_file>
# Idempotent VPC for source-truth: one VPC, a public + private subnet (same AZ),
# IGW, NAT gateway, and route tables. Writes IDs back to the config file.
# Reuses anything tagged Name=source-truth-* **inside this VPC** so re-runs don't duplicate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"
CIDR="10.1.0.0/16"
Q() { aws ec2 "$@" --region "$REGION"; }

# Name tag applied ATOMICALLY at creation. Every create-* below passes this instead of a separate
# create-tags call: a crash / throttle / Ctrl-C between "created" and "tagged" leaves a resource
# that the tag-only discovery on the next run cannot see and teardown.sh can never delete — the
# subnet case is worse than a leak, because the untagged subnet still holds 10.1.0.0/24 and every
# future deploy then dies on InvalidSubnet.Conflict until someone removes it by hand. The EIP block
# below already solved this the same way and explains the quota consequences.
tspec() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s}]' "$1" "$2"; }

# Tag-only lookup, optionally scoped by extra --filters arguments.
#
# tag:Name is NOT a unique key within an account. --local mode (provision_index_service.sh, the
# "no source-truth-private subnet in <vpc>" branch) discovers that subnet inside the LOCAL host's
# OWN VPC, so an account that has ever run --local — or any operator who tagged a second resource
# by hand — carries two resources with the same Name in two different VPCs. Unscoped, this lookup
# can return the OTHER VPC's subnet / route table / NACL and the run splices the two networks
# together: create-nat-gateway and associate-route-table fail with cross-VPC errors, or the
# hardened NACL gets associated to a subnet we do not own. So every VPC-scoped resource passes
# "Name=vpc-id,Values=$VPC_ID", and assert_in_vpc re-checks the answer — an older CLI that drops
# an unsupported filter would otherwise silently hand back an unscoped match.
by_name() { # <resources> <name> <Collection> <IdField> [extra --filters args ...]
  local res="$1" name="$2" coll="$3" field="$4"; shift 4
  Q describe-"$res" --filters "Name=tag:Name,Values=$name" "$@" \
    --query "${coll}[0].${field}" --output text 2>/dev/null
}

# Hard-fail if a discovered resource belongs to a different VPC. Splicing two VPCs is expensive to
# unpick after the fact (half-associated route tables, a NACL on someone else's subnet), so refuse
# up front rather than letting the AWS call fail three steps later with a cross-VPC error.
assert_in_vpc() { # <resources> <ids-flag> <id> <Collection> [VpcId-field]
  local res="$1" flag="$2" id="$3" coll="$4" field="${5:-VpcId}" owner
  owner="$(Q describe-"$res" "$flag" "$id" --query "${coll}[0].${field}" --output text 2>/dev/null || echo "")"
  [[ "$owner" == "$VPC_ID" ]] && return 0
  say err "$res $id matches our tag:Name but lives in VPC ${owner:-unknown}, not $VPC_ID —"
  say err "  refusing to splice two VPCs together. A prior --local deploy or a hand-tagged"
  say err "  resource collides on tag:Name; retag or remove it, then re-run."
  exit 1
}

VPC_ID="$(by_name vpcs source-truth-vpc Vpcs VpcId)"
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  VPC_ID="$(Q create-vpc --cidr-block "$CIDR" \
    --tag-specifications "$(tspec vpc source-truth-vpc)" --query Vpc.VpcId --output text)"
fi
# Reconcile BOTH DNS attributes EVERY run (not just on create): the index-service
# stable endpoint (index.source-truth.internal, a Route53 private hosted zone) only
# resolves inside the VPC when enableDnsSupport=true (drives the .2 resolver) AND
# enableDnsHostnames=true. create-vpc defaults support=true, but a REUSED/externally
# created VPC tagged source-truth-vpc could have it off → the agent runtime would get
# NXDOMAIN on CODEGRAPH_MCP_URL → empty codegraph results on EVERY question. Setting
# both unconditionally is idempotent and closes that silent foot-gun.
Q modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support >/dev/null
Q modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
# Pick an AZ that actually OFFERS the index instance type. A blind AvailabilityZones[0]
# breaks in regions where Graviton (t4g.*) isn't in the first AZ — run-instances later
# dies with Unsupported/InsufficientInstanceCapacity (cross-review M4). Prefer the first
# AZ that offers the type; fall back to AZ[0] if the lookup yields nothing (older CLI /
# odd region). The instance type comes from the deploy config/env (default t4g.large).
ITYPE_FOR_AZ="${DEPLOY_INSTANCE_TYPE:-t4g.large}"
AZ="$(Q describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=$ITYPE_FOR_AZ" \
  --query 'InstanceTypeOfferings[0].Location' --output text 2>/dev/null || echo "")"
if [[ -z "$AZ" || "$AZ" == "None" ]]; then
  AZ="$(Q describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"
  say warn "no AZ offers $ITYPE_FOR_AZ via offerings lookup; falling back to first AZ $AZ"
fi

ensure_subnet() { # name cidr public
  local id; id="$(by_name subnets "$1" Subnets SubnetId "Name=vpc-id,Values=$VPC_ID")"
  if [[ "$id" == "None" || -z "$id" ]]; then
    id="$(Q create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$AZ" \
      --tag-specifications "$(tspec subnet "$1")" --query Subnet.SubnetId --output text)"
  else
    assert_in_vpc subnets --subnet-ids "$id" Subnets
  fi
  # Reconcile map-public-ip-on-launch EVERY run, not only on create — same reasoning as the IGW
  # attachment and the routes in mk_rt below. Gated on creation it was never repaired: a crash
  # between create-subnet and modify-subnet-attribute left a public subnet that assigns no public
  # IP (NAT gateway creation then fails), and a reused/externally-created subnet tagged
  # source-truth-private that has the flag ON would hand the index host a public IP, quietly
  # undoing the private-subnet design. Both directions are asserted, and both are no-ops when the
  # attribute already matches.
  local want=false maps
  [[ "$3" == public ]] && want=true
  maps="$(Q describe-subnets --subnet-ids "$id" --query 'Subnets[0].MapPublicIpOnLaunch' --output text 2>/dev/null || echo "")"
  if [[ "$want" == true && "$maps" != "True" ]]; then
    Q modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch >/dev/null
  elif [[ "$want" == false && "$maps" == "True" ]]; then
    Q modify-subnet-attribute --subnet-id "$id" --no-map-public-ip-on-launch >/dev/null
  fi
  echo "$id"
}
PUB="$(ensure_subnet source-truth-public 10.1.0.0/24 public)"
PRIV="$(ensure_subnet source-truth-private 10.1.1.0/24 private)"

IGW="$(by_name internet-gateways source-truth-igw InternetGateways InternetGatewayId)"
if [[ "$IGW" == "None" || -z "$IGW" ]]; then
  IGW="$(Q create-internet-gateway --tag-specifications "$(tspec internet-gateway source-truth-igw)" \
    --query InternetGateway.InternetGatewayId --output text)"
fi
# An IGW is NOT looked up with a vpc-id filter (only attachment.vpc-id exists, and that would miss
# the tagged-but-detached IGW this block deliberately repairs), so check ownership explicitly: an
# IGW can be attached to at most one VPC, and if that is someone else's VPC we must stop. Previously
# attach-internet-gateway was attempted anyway and its Resource.AlreadyAssociated error was
# swallowed as "benign race", so a cross-VPC IGW was reported as attached to ours.
IGW_VPC="$(Q describe-internet-gateways --internet-gateway-ids "$IGW" \
  --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null || echo "")"
if [[ -n "$IGW_VPC" && "$IGW_VPC" != "None" && "$IGW_VPC" != "$VPC_ID" ]]; then
  say err "IGW $IGW (tag:Name source-truth-igw) is attached to VPC $IGW_VPC, not $VPC_ID —"
  say err "  retag or detach it, then re-run. Attaching it here would fail or hijack that VPC."
  exit 1
fi
# Reconcile the VPC attachment EVERY run (NOT gated on IGW creation): a crash
# between create and attach would otherwise leave a tagged-but-detached IGW that
# a re-run skips, leaving the public subnet with no internet path. Tolerate only
# the benign "already attached" errors; hard-fail anything else.
if [[ "$IGW_VPC" == "None" || -z "$IGW_VPC" ]]; then
  igw_err="$(Q attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>&1 >/dev/null)" || {
    case "$igw_err" in
      *Resource.AlreadyAssociated*|*already\ attached*) : ;;  # race: already attached — fine
      *) say err "failed to attach IGW $IGW to $VPC_ID: $igw_err"; exit 1 ;;
    esac
  }
fi

# NAT needs an EIP in the public subnet. Scoped by vpc-id: a NAT gateway tagged source-truth-nat in
# another VPC (a --local account) would otherwise be adopted and then fail to route this subnet.
NAT="$(Q describe-nat-gateways --filter "Name=tag:Name,Values=source-truth-nat" "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)"
if [[ "$NAT" == "None" || -z "$NAT" ]]; then
  # Reuse a tagged, UNASSOCIATED EIP before allocating a new one. Otherwise a
  # crash/Ctrl-C/throttle landing between allocate-address and create-nat-gateway
  # leaks an un-tagged, un-attached EIP that no re-run can find — and each retry
  # allocates another, exhausting the new-account default quota (5) and hard-
  # failing on AddressLimitExceeded. We TAG the EIP at allocation time (atomic
  # via --tag-specifications, so even a crash before any separate tag call leaves
  # a recoverable address) and look for a reclaimable one first.
  EIP="$(Q describe-addresses --filters "Name=tag:Name,Values=source-truth-nat-eip" "Name=domain,Values=vpc" --query 'Addresses[?AssociationId==`null`] | [0].AllocationId' --output text 2>/dev/null)"
  if [[ "$EIP" == "None" || -z "$EIP" ]]; then
    EIP="$(Q allocate-address --domain vpc \
      --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=source-truth-nat-eip}]' \
      --query AllocationId --output text)"
  else
    say info "reusing orphaned EIP $EIP"
  fi
  NAT="$(Q create-nat-gateway --subnet-id "$PUB" --allocation-id "$EIP" \
    --tag-specifications "$(tspec natgateway source-truth-nat)" \
    --query NatGateway.NatGatewayId --output text)"
  say info "waiting for NAT $NAT ..."
  Q wait nat-gateway-available --nat-gateway-ids "$NAT"
else
  assert_in_vpc nat-gateways --nat-gateway-ids "$NAT" NatGateways
fi

# Route tables: public → IGW, private → NAT.
# Each sub-resource (the table, its default route, its subnet association) is
# reconciled INDEPENDENTLY — RT existence is NOT used as a proxy for "route +
# association are correct". Otherwise a crash/throttle/Ctrl-C between creating
# the tagged table and adding the route would leave a tagged-but-routeless table
# that a re-run skips, leaving the private subnet with no 0.0.0.0/0 → NAT route
# (index-service then can't reach S3 to bootstrap). Mirrors the put-policy-
# outside-the-get-role-gate pattern in provision_iam.sh.
mk_rt() { # name subnet target-flag target-id
  local rt; rt="$(by_name route-tables "$1" RouteTables RouteTableId "Name=vpc-id,Values=$VPC_ID")"
  if [[ "$rt" == "None" || -z "$rt" ]]; then
    rt="$(Q create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tspec route-table "$1")" --query RouteTable.RouteTableId --output text)"
  else
    assert_in_vpc route-tables --route-table-ids "$rt" RouteTables
  fi
  # Ensure the default route exists, regardless of whether the table is new.
  # create-route fails if the route already exists, so check first; if a route
  # to 0.0.0.0/0 exists but points elsewhere, replace it to converge.
  local existing; existing="$(Q describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0]" --output text 2>/dev/null)"
  if [[ "$existing" == "None" || -z "$existing" ]]; then
    Q create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 "$3" "$4" >/dev/null
  else
    # Converge an existing 0.0.0.0/0 route onto the intended target. Surface a
    # real failure rather than masking it with `|| true` — a route that can't be
    # corrected silently breaks egress for the subnet.
    Q replace-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 "$3" "$4" >/dev/null
  fi
  # Ensure the subnet is associated with this table (idempotent).
  local assoc; assoc="$(Q describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Associations[?SubnetId=='$2'] | [0].RouteTableAssociationId" --output text 2>/dev/null)"
  if [[ "$assoc" == "None" || -z "$assoc" ]]; then
    Q associate-route-table --route-table-id "$rt" --subnet-id "$2" >/dev/null
  fi
}
mk_rt source-truth-public-rt "$PUB" --gateway-id "$IGW"
mk_rt source-truth-private-rt "$PRIV" --nat-gateway-id "$NAT"

VPC_CIDR="$(Q describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)"

# ---- H5: Restrictive Network ACL on private subnet ----
# Inbound: TCP 8080-8099 and 443 from the VPC CIDR (index bridge + internal HTTPS), plus
# ephemeral RETURN traffic (TCP and UDP) and ICMP fragmentation-needed. Outbound: allow all,
# which NAT egress requires. Everything else hits the implicit deny at 32767.
NACL_ID="$(by_name network-acls source-truth-private-nacl NetworkAcls NetworkAclId "Name=vpc-id,Values=$VPC_ID")"
if [[ "$NACL_ID" == "None" || -z "$NACL_ID" ]]; then
  NACL_ID="$(Q create-network-acl --vpc-id "$VPC_ID" \
    --tag-specifications "$(tspec network-acl source-truth-private-nacl)" \
    --query NetworkAcl.NetworkAclId --output text)"
else
  assert_in_vpc network-acls --network-acl-ids "$NACL_ID" NetworkAcls
fi

# ADDITIVE convergence, never delete-then-recreate.
#
# The previous version deleted every custom entry and then re-created them. A custom NACL's
# baseline is deny-all, so that opened a window where the private subnet denied ALL traffic in
# both directions — and under `set -euo pipefail` any failure among the re-creates (throttle,
# IAM denial, transient) exited the script and left the subnet at deny-all permanently: bridge
# down, NAT egress down, SSM down, i.e. no way back in except the console. Self-inflicted and
# exactly the kind of outage a "security hardening" step must not cause.
#
# Instead: create each desired rule, and if that rule number already exists, REPLACE it in
# place. There is no moment at which a needed rule is absent. Same tolerate-duplicate pattern
# authorize_ingress already uses for security-group rules.
nacl_rule() { # <ingress|egress> <rule-number> <aws-cli args...>
  local dir="$1" num="$2"; shift 2
  local flag="--ingress"; [[ "$dir" == "egress" ]] && flag="--egress"
  if ! Q create-network-acl-entry --network-acl-id "$NACL_ID" "$flag" --rule-number "$num" "$@" >/dev/null 2>&1; then
    Q replace-network-acl-entry --network-acl-id "$NACL_ID" "$flag" --rule-number "$num" "$@" >/dev/null
  fi
}

# 100: TCP 8080-8099 from the VPC only — the index bridge ports.
nacl_rule ingress 100 --protocol 6 --port-range "From=8080,To=8099" --cidr-block "$VPC_CIDR" --rule-action allow
# 110: TCP 443 from the VPC only — internal HTTPS between co-located components.
nacl_rule ingress 110 --protocol 6 --port-range "From=443,To=443" --cidr-block "$VPC_CIDR" --rule-action allow
# 120/130: ephemeral RETURN traffic for connections this subnet originated through the NAT.
# Scoped to the Linux ephemeral range (32768-60999), NOT 1024-65535: the wider range fully
# contained rule 100, so the bridge ports were in practice reachable from 0.0.0.0/0 and rule
# 100's VPC-CIDR restriction was dead. UDP is listed too — egress allows all protocols, so a
# TCP-only return rule silently blackholes UDP replies (an NTP fallback off the link-local
# source then drifts the clock until SigV4 signatures start failing, which looks like an IAM
# fault). The VPC resolver, IMDS and Amazon Time Sync are link-local and unaffected by NACLs.
nacl_rule ingress 120 --protocol 6 --port-range "From=32768,To=60999" --cidr-block "0.0.0.0/0" --rule-action allow
nacl_rule ingress 130 --protocol 17 --port-range "From=32768,To=60999" --cidr-block "0.0.0.0/0" --rule-action allow
# 140: ICMP type 3 code 4 (fragmentation needed) so Path MTU Discovery works. Without it large
# TLS transfers hang rather than fail — ECR layer pulls, npm ci, apt — which is intermittent and
# very expensive to diagnose.
nacl_rule ingress 140 --protocol 1 --icmp-type-code "Type=3,Code=4" --cidr-block "0.0.0.0/0" --rule-action allow
# Outbound: allow all. No --port-range: with protocol -1 it is meaningless and reads as if ports
# were constrained when they are not.
nacl_rule egress 100 --protocol -1 --cidr-block "0.0.0.0/0" --rule-action allow

# Remove any stale custom entry that is NOT in the desired set — AFTER the desired rules are in
# place, so convergence never passes through a deny-all state.
_DESIRED_IN="100 110 120 130 140"
_DESIRED_OUT="100"
_nacl_rules="$(Q describe-network-acls --network-acl-ids "$NACL_ID" \
  --query 'NetworkAcls[0].Entries[?RuleNumber < `32767`].[RuleNumber,Egress]' --output text 2>/dev/null || echo "")"
while IFS=$'\t' read -r _rnum _egress; do
  [[ -z "$_rnum" ]] && continue
  if [[ "$_egress" == "True" || "$_egress" == "true" ]]; then
    [[ " $_DESIRED_OUT " == *" $_rnum "* ]] && continue
    Q delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number "$_rnum" --egress >/dev/null 2>&1 || true
  else
    [[ " $_DESIRED_IN " == *" $_rnum "* ]] && continue
    Q delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number "$_rnum" --ingress >/dev/null 2>&1 || true
  fi
done <<< "$_nacl_rules"
# Associate NACL with private subnet (replace the default). A subnet has exactly one
# NACL association — replacing it is idempotent (just points to the same NACL again).
NACL_ASSOC="$(Q describe-network-acls --filters "Name=association.subnet-id,Values=$PRIV" \
  --query 'NetworkAcls[0].Associations[?SubnetId==`'"$PRIV"'`].NetworkAclAssociationId | [0]' --output text 2>/dev/null)"
if [[ -n "$NACL_ASSOC" && "$NACL_ASSOC" != "None" ]]; then
  Q replace-network-acl-association --association-id "$NACL_ASSOC" --network-acl-id "$NACL_ID" >/dev/null
else
  # A running subnet ALWAYS has exactly one NACL association, so an empty read is an API glitch,
  # not a valid state. Skipping silently left the subnet on its default allow-all NACL while the
  # deploy reported network success — the control appears to exist but does not, which is worse
  # than not having it. Same reasoning already applied to the security-group read in
  # provision_index_service.sh.
  say err "could not read the NACL association for subnet $PRIV — refusing to leave it on the default allow-all NACL; re-run"
  exit 1
fi

# ---- H7: VPC Flow Logs to S3 ----
# Uses the project's artifact bucket with a vpc-flow-logs/ prefix (cheapest: S3 destination,
# no extra CloudWatch Logs cost). Idempotent: skip if a flow log with our tag already exists.
FLOW_LOG_ID="$(Q describe-flow-logs --filter "Name=tag:Name,Values=source-truth-vpc-flow-log" "Name=resource-id,Values=$VPC_ID" \
  --query 'FlowLogs[0].FlowLogId' --output text 2>/dev/null)"
if [[ "$FLOW_LOG_ID" == "None" || -z "$FLOW_LOG_ID" ]]; then
  # Bucket name: take the AUTHORITATIVE value Phase 1 wrote to deploy-config. Deriving it here
  # is what broke this on first live run — the bucket convention strips the dashes out of the
  # region (…-uswest2), so a locally-built "…-${REGION}" name (…-us-west-2) pointed at a bucket
  # that does not exist and create-flow-logs failed. Fall back to the same tr -d '-' rule
  # deploy-all.sh uses, for a standalone invocation with no config yet.
  # Read via the shared helper, NOT an ad-hoc sed: env-utils' safe_source_env strips a trailing
  # \r, and a config saved with CRLF line endings otherwise yields "bucket<CR>", producing
  # --log-destination arn:aws:s3:::bucket<CR>/vpc-flow-logs/ and a creation failure that is only
  # WARNED about — so the VPC silently ends up with no flow log, which is the exact outcome the
  # earlier fixes to this block were written to end.
  safe_source_env "$CONFIG" 2>/dev/null || true
  FLOW_BUCKET="${ARTIFACT_BUCKET:-}"
  if [[ -z "$FLOW_BUCKET" ]]; then
    ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    FLOW_BUCKET="source-truth-repo-${ACCOUNT}-$(printf '%s' "$REGION" | tr -d '-')"
  fi
  # create-flow-logs returns 0 even when it creates NOTHING: the per-resource error lands in
  # .Unsuccessful and FlowLogIds comes back empty. The first version of this block only read
  # FlowLogIds[0] and logged success unconditionally, so a failed creation reported
  # "✓ vpc flow log created: None" and the VPC silently had no flow log. Inspect both fields.
  FLOW_JSON="$(Q create-flow-logs --resource-type VPC --resource-ids "$VPC_ID" \
    --traffic-type ALL --log-destination-type s3 \
    --log-destination "arn:aws:s3:::${FLOW_BUCKET}/vpc-flow-logs/" \
    --max-aggregation-interval 600 \
    --tag-specifications "ResourceType=vpc-flow-log,Tags=[{Key=Name,Value=source-truth-vpc-flow-log}]" \
    --output json 2>&1)" || true
  FLOW_LOG_ID="$(printf '%s' "$FLOW_JSON" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
ids=d.get("FlowLogIds") or []
print(ids[0] if ids else "")' 2>/dev/null)"
  if [[ -n "$FLOW_LOG_ID" ]]; then
    say ok "vpc flow log created: $FLOW_LOG_ID → s3://${FLOW_BUCKET}/vpc-flow-logs/"
  elif printf '%s' "$FLOW_JSON" | grep -q FlowLogAlreadyExists; then
    # AWS enforces uniqueness on (resource, traffic-type, destination) — NOT on our tag. A flow
    # log with this exact config already exists (older script version, another tool, or an
    # operator), so the desired state already holds; the tag-only lookup above just could not
    # see it. Treat as success rather than warning on every single deploy.
    say ok "vpc flow log already present for $VPC_ID → s3://${FLOW_BUCKET}/vpc-flow-logs/ (untagged/pre-existing)"
  else
    # Non-fatal: flow logs are an audit aid, not a serving dependency. But say WHY.
    say warn "vpc flow log NOT created (non-fatal — no network audit trail for $VPC_ID)"
    say warn "  → $(printf '%s' "$FLOW_JSON" | tr -d '\n' | cut -c1-300)"
  fi
fi

update_env "$CONFIG" VPC_ID "$VPC_ID"
# Ours: this script created the VPC (or adopted one carrying the source-truth-vpc tag it
# created earlier), so teardown may clean up inside it. See teardown.sh section 5.
update_env "$CONFIG" VPC_OWNED true
update_env "$CONFIG" VPC_CIDR "$VPC_CIDR"
update_env "$CONFIG" PUBLIC_SUBNET "$PUB"
update_env "$CONFIG" PRIVATE_SUBNET "$PRIV"
update_env "$CONFIG" NAT_GATEWAY "$NAT"
say ok "network ready: vpc=$VPC_ID ($VPC_CIDR) priv=$PRIV pub=$PUB nat=$NAT"
