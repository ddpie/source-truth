#!/usr/bin/env bash
# provision_network.sh <region> <config_file>
# Idempotent VPC for source-truth: one VPC, a public + private subnet (same AZ),
# IGW, NAT gateway, and route tables. Writes IDs back to the config file.
# Reuses anything tagged Name=source-truth-* so re-runs don't duplicate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"
CIDR="10.1.0.0/16"
Q() { aws ec2 "$@" --region "$REGION"; }
tag() { Q create-tags --resources "$1" --tags "Key=Name,Value=$2" >/dev/null; }
by_name() { Q describe-"$1" --filters "Name=tag:Name,Values=$2" --query "${3}[0].${4:-${1%s}Id}" --output text 2>/dev/null; }

VPC_ID="$(by_name vpcs source-truth-vpc Vpcs VpcId)"
if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  VPC_ID="$(Q create-vpc --cidr-block "$CIDR" --query Vpc.VpcId --output text)"
  tag "$VPC_ID" source-truth-vpc
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
AZ="$(Q describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)"

ensure_subnet() { # name cidr public
  local id; id="$(by_name subnets "$1" Subnets SubnetId)"
  if [[ "$id" == "None" || -z "$id" ]]; then
    id="$(Q create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$AZ" --query Subnet.SubnetId --output text)"
    tag "$id" "$1"
    [[ "$3" == public ]] && Q modify-subnet-attribute --subnet-id "$id" --map-public-ip-on-launch >/dev/null
  fi
  echo "$id"
}
PUB="$(ensure_subnet source-truth-public 10.1.0.0/24 public)"
PRIV="$(ensure_subnet source-truth-private 10.1.1.0/24 private)"

IGW="$(by_name internet-gateways source-truth-igw InternetGateways InternetGatewayId)"
if [[ "$IGW" == "None" || -z "$IGW" ]]; then
  IGW="$(Q create-internet-gateway --query InternetGateway.InternetGatewayId --output text)"
  tag "$IGW" source-truth-igw
fi
# Reconcile the VPC attachment EVERY run (NOT gated on IGW creation): a crash
# between create and attach would otherwise leave a tagged-but-detached IGW that
# a re-run skips, leaving the public subnet with no internet path. Tolerate only
# the benign "already attached" errors; hard-fail anything else.
ATTACHED="$(Q describe-internet-gateways --internet-gateway-ids "$IGW" --query "InternetGateways[0].Attachments[?VpcId=='$VPC_ID'] | [0].State" --output text 2>/dev/null)"
if [[ "$ATTACHED" == "None" || -z "$ATTACHED" ]]; then
  igw_err="$(Q attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>&1 >/dev/null)" || {
    case "$igw_err" in
      *Resource.AlreadyAssociated*|*already\ attached*) : ;;  # race: already attached — fine
      *) say err "failed to attach IGW $IGW to $VPC_ID: $igw_err"; exit 1 ;;
    esac
  }
fi

# NAT needs an EIP in the public subnet.
NAT="$(Q describe-nat-gateways --filter "Name=tag:Name,Values=source-truth-nat" "Name=state,Values=available,pending" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)"
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
  NAT="$(Q create-nat-gateway --subnet-id "$PUB" --allocation-id "$EIP" --query NatGateway.NatGatewayId --output text)"
  tag "$NAT" source-truth-nat
  say info "waiting for NAT $NAT ..."
  Q wait nat-gateway-available --nat-gateway-ids "$NAT"
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
  local rt; rt="$(by_name route-tables "$1" RouteTables RouteTableId)"
  if [[ "$rt" == "None" || -z "$rt" ]]; then
    rt="$(Q create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)"; tag "$rt" "$1"
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
update_env "$CONFIG" VPC_ID "$VPC_ID"
update_env "$CONFIG" VPC_CIDR "$VPC_CIDR"
update_env "$CONFIG" PUBLIC_SUBNET "$PUB"
update_env "$CONFIG" PRIVATE_SUBNET "$PRIV"
update_env "$CONFIG" NAT_GATEWAY "$NAT"
say ok "network ready: vpc=$VPC_ID ($VPC_CIDR) priv=$PRIV pub=$PUB nat=$NAT"
