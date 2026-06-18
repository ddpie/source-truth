#!/usr/bin/env bash
# provision_index_service.sh <region> <config> <bucket> <repo_subdir> <max_files> <instance_type>
# Idempotent ARM EC2 (Ubuntu 24.04 — glibc 2.39 for codegraph-server) in the
# private subnet, running index-service/bootstrap.sh as user-data. Prints the
# instance's private IP on stdout (the only stdout line; logs go to stderr).
#
# Security: index-svc SG accepts 8080 from the VPC; the runtime reaches it over
# the private network. The instance also gets 2049 egress to EFS via its SG.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; BUCKET="$3"; REPO_SUBDIR="$4"; MAX_FILES="$5"; ITYPE="$6"
safe_source_env "$CONFIG"
Q() { aws ec2 "$@" --region "$REGION"; }
log() { say "$@" >&2; }

# Authorize an ingress rule idempotently: tolerate ONLY the benign "rule already
# exists" (InvalidPermission.Duplicate) error, and HARD-FAIL on anything else
# (throttling, bad CIDR, IAM denial). A blanket `|| true` would silently swallow
# a real failure and leave the rule missing — which no downstream gate catches
# (wait_index_health.sh curls :8080 over loopback, never crossing the SG), so
# the deploy would falsely report success while the runtime can't reach the
# bridge. So we narrow the tolerance to the duplicate case only. Defined ABOVE
# the reuse block so the :8080 rule can be reconciled on BOTH paths.
authorize_ingress() { # <description> <args...>
  local desc="$1"; shift
  local err
  if ! err="$(Q authorize-security-group-ingress "$@" 2>&1 >/dev/null)"; then
    case "$err" in
      *InvalidPermission.Duplicate*) : ;;  # already present — idempotent, fine
      *) log err "failed to authorize $desc: $err"; exit 1 ;;
    esac
  fi
}

# Reconcile the index-service SG's :8080-from-VPC ingress rule. Run on EVERY
# invocation and BOTH paths (reuse + fresh), because the rule's absence is
# invisible to every downstream gate (the /health probe is loopback-only). A
# prior interrupted run, manual cleanup, or SG-rule drift could leave the rule
# missing on an otherwise-running instance; the reuse path must repair it too.
reconcile_index_sg_ingress() { # <sg>
  authorize_ingress ":8080 from VPC on $1" \
    --group-id "$1" --protocol tcp --port 8080 --cidr "${VPC_CIDR:-10.1.0.0/16}"
}

# Reuse a running index-service instance if present.
# NOTE: reuse does NOT re-bootstrap, so it will NOT pick up new index-service
# code staged to S3 this run. To deploy code changes, terminate the existing
# instance first (aws ec2 terminate-instances) so a fresh one bootstraps.
EXISTING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  IP="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  if [[ -z "$IP" || "$IP" == "None" ]]; then
    log err "reuse: instance $EXISTING has no private IP yet"; exit 1
  fi
  SG="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)"
  # Repair the :8080 ingress on the reused instance's SG too — otherwise a
  # missing/dropped rule on a running instance would never be re-added (the
  # reuse path exits before the fresh-instance reconcile below).
  reconcile_index_sg_ingress "$SG"
  # Persist the same state the new-instance path does, so deploy-all's health
  # gate runs and the runtime gets a valid SG (not skipped/unset).
  update_env "$CONFIG" INDEX_SERVICE_SG "$SG"
  update_env "$CONFIG" INDEX_SERVICE_INSTANCE "$EXISTING"
  log info "reusing index-service $EXISTING ($IP, sg=$SG)"
  echo "$IP"; exit 0
fi

# index-service security group: 8080 in from VPC.
SG="$(Q describe-security-groups --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [[ "$SG" == "None" || -z "$SG" ]]; then
  SG="$(Q create-security-group --group-name source-truth-index-svc --description "index-service codegraph bridge" --vpc-id "$VPC_ID" --query GroupId --output text)"
fi
# Reconcile the :8080 ingress rule EVERY run (NOT gated on SG creation). If the
# deploy crashed between create-sg and authorize last time, a re-run would
# otherwise find the tagged SG and skip the rule, leaving the runtime unable to
# reach the bridge. Same crash-safe pattern as provision_network.sh mk_rt.
reconcile_index_sg_ingress "$SG"
# Let the EFS SG accept NFS from this SG (defensive; CIDR rule already covers it).
authorize_ingress "EFS :2049 from $SG on $EFS_SG" \
  --group-id "$EFS_SG" --protocol tcp --port 2049 --source-group "$SG"

# Latest Ubuntu 24.04 ARM AMI (Canonical owner id 099720109477).
AMI="$(Q describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"

# user-data: write env file, drop bootstrap.sh, run it.
BOOT_B64="$(base64 -w0 "$ROOT/index-service/bootstrap.sh")"
UD="$(cat <<EOF
#!/bin/bash
cat > /etc/index-service.env <<ENV
BUCKET=$BUCKET
REGION=$REGION
EFS_ID=$EFS_ID
REPO_SUBDIR=$REPO_SUBDIR
MAX_FILES=$MAX_FILES
ENV
echo "$BOOT_B64" | base64 -d > /opt/bootstrap.sh
bash /opt/bootstrap.sh
EOF
)"

# Instance profile must exist (provision_iam.sh created it). Without it the EC2
# has no credentials and bootstrap.sh can't pull artifacts from S3 → hard fail.
# Retry: IAM is eventually consistent, so a freshly created profile may take
# longer than provision_iam's sleep to propagate to this API endpoint.
PROFILE="${INDEX_INSTANCE_PROFILE:-source-truth-index-profile}"
PROFILE_OK=false
for _ in $(seq 1 12); do
  if aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
    PROFILE_OK=true; break
  fi
  sleep 5
done
if [[ "$PROFILE_OK" != true ]]; then
  log err "instance profile '$PROFILE' missing/not propagated — run the IAM phase first (deploy-all.sh)"
  exit 1
fi
PROFILE_ARG=(--iam-instance-profile "Name=$PROFILE")

IID="$(Q run-instances --image-id "$AMI" --instance-type "$ITYPE" \
  --subnet-id "$PRIVATE_SUBNET" --security-group-ids "$SG" \
  "${PROFILE_ARG[@]}" \
  --user-data "$UD" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=source-truth-index-service}]' \
  --query 'Instances[0].InstanceId' --output text)"
log info "launched index-service $IID (Ubuntu 24.04 ARM); bootstrap runs build→serve"
# Wait for the instance to be running so its ENI/private IP is assigned — a
# query right after run-instances can return "None" and poison CODEGRAPH_MCP_URL.
Q wait instance-running --instance-ids "$IID"
IP="$(Q describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
if [[ -z "$IP" || "$IP" == "None" ]]; then
  log err "index-service private IP not assigned after instance-running"
  exit 1
fi
update_env "$CONFIG" INDEX_SERVICE_SG "$SG"
update_env "$CONFIG" INDEX_SERVICE_INSTANCE "$IID"
echo "$IP"
