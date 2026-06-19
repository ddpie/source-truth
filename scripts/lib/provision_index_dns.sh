#!/usr/bin/env bash
# provision_index_dns.sh <region> <config_file> <vpc_id> <index_private_ip>
# Idempotent Route53 PRIVATE hosted zone + A-record giving the index-service a
# STABLE DNS name that survives instance replacement.
#
# WHY THIS EXISTS (the bug it fixes): the agent runtime's CODEGRAPH_MCP_URL used
# the index instance's raw private IP. Every `--refresh-index` REPLACES the
# instance → new IP → the runtime env must be updated → but AgentCore's already-
# WARM microVMs keep the OLD CODEGRAPH_MCP_URL for 30+ min until they age out, so
# questions hitting a warm VM pointed at the (now-terminated) old IP get a
# connection failure → empty codegraph results → the agent correctly refuses
# ("index not ready"), producing intermittent empty answer cards. Pinning the
# agent to a STABLE name (index.source-truth.internal) that we just re-point at
# the new IP means the runtime env NEVER changes on a refresh, so warm VMs stay
# valid — the empty-card class is eliminated.
#
# Prints INDEX_DNS_NAME=<fqdn> on stdout; persists INDEX_DNS_ZONE_ID + the name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; VPC_ID="$3"; INDEX_IP="$4"
ZONE_NAME="source-truth.internal"
RECORD="index.${ZONE_NAME}"

: "${INDEX_IP:?provision_index_dns: index private IP required}"
[[ "$INDEX_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { say err "index IP '$INDEX_IP' is not an IPv4 address"; exit 1; }

R() { aws route53 "$@"; }  # route53 is global; no --region

# --- find-or-create the PRIVATE hosted zone associated with our VPC ----------
# list-hosted-zones-by-vpc returns zones already associated with the VPC, so a
# re-run reuses the same zone rather than creating a duplicate (Route53 allows
# multiple private zones with the same name, which would be ambiguous).
ZONE_ID="$(aws route53 list-hosted-zones-by-vpc --vpc-id "$VPC_ID" --vpc-region "$REGION" \
  --query "HostedZoneSummaries[?Name=='${ZONE_NAME}.'].HostedZoneId | [0]" --output text 2>/dev/null || echo "")"
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
  # list-hosted-zones-by-vpc only returns zones ALREADY associated with this VPC. A
  # zone may EXIST (same name) but not be associated — e.g. a partial prior run that
  # created the zone then failed before/at association, or a later disassociation.
  # In that case create-hosted-zone with our stable CallerReference would fail with
  # HostedZoneAlreadyExists and (under set -e, stderr eaten) abort the deploy with no
  # message. So first look up the zone BY NAME; if it exists, ASSOCIATE this VPC
  # (idempotent) instead of creating. Only create when truly absent.
  EXISTING="$(R list-hosted-zones --query "HostedZones[?Name=='${ZONE_NAME}.' && Config.PrivateZone].Id | [0]" --output text 2>/dev/null || echo "")"
  if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
    ZONE_ID="${EXISTING##*/}"
    say info "private zone $ZONE_NAME exists ($ZONE_ID) but not associated with $VPC_ID; associating" >&2
    # Idempotent: a ConflictingDomainExists / already-associated error is benign.
    assoc_err="$(R associate-vpc-with-hosted-zone --hosted-zone-id "$ZONE_ID" \
      --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" 2>&1 >/dev/null)" || {
      case "$assoc_err" in
        *ConflictingDomainExists*|*already*associated*|*HasVPCAssociation*) : ;;
        *) say err "failed to associate zone $ZONE_ID with $VPC_ID: $assoc_err"; exit 1 ;;
      esac
    }
  else
    say info "creating private hosted zone $ZONE_NAME for $VPC_ID" >&2
    # CallerReference stable per VPC. Surface errors (don't 2>/dev/null-swallow) so a
    # genuine failure is actionable instead of a silent set -e abort.
    create_out="$(R create-hosted-zone --name "$ZONE_NAME" \
      --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" \
      --hosted-zone-config "Comment=source-truth index-service stable endpoint,PrivateZone=true" \
      --caller-reference "source-truth-${VPC_ID}" \
      --query 'HostedZone.Id' --output text 2>&1)" || {
      say err "create-hosted-zone failed: $create_out"; exit 1
    }
    ZONE_ID="$create_out"
  fi
fi
# Normalize the zone id (Route53 returns "/hostedzone/ZXXXX").
ZONE_ID="${ZONE_ID##*/}"

# --- upsert the A-record → current index IP (idempotent; UPSERT replaces) -----
# UPSERT is the whole point: on a fresh deploy it creates the record; on a
# --refresh-index (new IP) it REPLACES the value, re-pointing the stable name at
# the new instance WITHOUT the agent runtime env ever changing. TTL is short (30s)
# so a re-point propagates fast and a warm VM's resolver cache doesn't hold a dead
# IP for long. (The runtime never re-resolves mid-connection anyway, but new
# connections pick up the new IP within the TTL.)
CHANGE_ID="$(R change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"${RECORD}\",
      \"Type\": \"A\",
      \"TTL\": 30,
      \"ResourceRecords\": [{\"Value\": \"${INDEX_IP}\"}]
    }
  }]
}" --query 'ChangeInfo.Id' --output text 2>/dev/null)"
say info "upserted ${RECORD} → ${INDEX_IP} (zone $ZONE_ID, change ${CHANGE_ID##*/})" >&2

update_env "$CONFIG" INDEX_DNS_ZONE_ID "$ZONE_ID"
update_env "$CONFIG" INDEX_DNS_NAME "$RECORD"
say ok "index DNS ready: ${RECORD} → ${INDEX_IP}" >&2
echo "INDEX_DNS_NAME=${RECORD}"
