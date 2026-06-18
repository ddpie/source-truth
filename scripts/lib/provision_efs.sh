#!/usr/bin/env bash
# provision_efs.sh <region> <config_file>
# Idempotent EFS + access point (/repo, posix uid/gid 1000) + a mount target in
# the private subnet. The EFS security group accepts NFS (2049) from the VPC.
# Both index-service and the AgentCore runtime mount this same access point.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; safe_source_env "$CONFIG"
Q() { aws efs "$@" --region "$REGION"; }
QE() { aws ec2 "$@" --region "$REGION"; }

# Find an EFS tagged source-truth, else create one.
EFS_ID="$(Q describe-file-systems --query "FileSystems[?Name=='source-truth-efs'].FileSystemId | [0]" --output text 2>/dev/null)"
if [[ "$EFS_ID" == "None" || -z "$EFS_ID" ]]; then
  EFS_ID="$(Q create-file-system --performance-mode generalPurpose --throughput-mode bursting \
    --tags Key=Name,Value=source-truth-efs --query FileSystemId --output text)"
  say info "waiting for EFS $EFS_ID ..."
  EFS_READY=false
  for _ in $(seq 1 30); do
    [[ "$(Q describe-file-systems --file-system-id "$EFS_ID" --query 'FileSystems[0].LifeCycleState' --output text)" == available ]] && { EFS_READY=true; break; }
    sleep 5
  done
  [[ "$EFS_READY" == true ]] || { say err "EFS $EFS_ID did not become available within timeout"; exit 1; }
fi

# Access point: root /repo owned 1000:1000 (matches container non-root user).
# Select by the LOAD-BEARING property (RootDirectory.Path == /repo), NOT by
# position ([0]). The runtime mounts this AP's root at /mnt/repo; if a foreign or
# stale AP (manual, sibling stack, or a future schema migration that left an old
# one) sorted ahead of ours, positional [0] would bind the runtime to the wrong
# directory tree — the agent then reads the wrong code with NOTHING downstream
# catching it (the health gate is loopback on the index instance, never crossing
# the runtime's mount), directly violating "code is the only source of truth".
AP="$(Q describe-access-points --file-system-id "$EFS_ID" --query "AccessPoints[?RootDirectory.Path=='/repo'].AccessPointId | [0]" --output text 2>/dev/null)"
if [[ "$AP" == "None" || -z "$AP" ]]; then
  AP="$(Q create-access-point --file-system-id "$EFS_ID" \
    --posix-user "Uid=1000,Gid=1000" \
    --root-directory "Path=/repo,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
    --tags Key=Name,Value=source-truth-repo-ap \
    --query AccessPointId --output text)"
  # Wait for the access point to be 'available' before any client mounts it —
  # mounting a still-'creating' AP can fail the access-point permission checks.
  say info "waiting for access point $AP ..."
  AP_READY=false
  for _ in $(seq 1 30); do
    [[ "$(Q describe-access-points --access-point-id "$AP" --query 'AccessPoints[0].LifeCycleState' --output text)" == available ]] && { AP_READY=true; break; }
    sleep 5
  done
  [[ "$AP_READY" == true ]] || { say err "access point $AP did not become available within timeout"; exit 1; }
fi

# EFS security group: allow NFS 2049 from within the VPC.
EFS_SG="$(QE describe-security-groups --filters "Name=group-name,Values=source-truth-efs-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [[ "$EFS_SG" == "None" || -z "$EFS_SG" ]]; then
  EFS_SG="$(QE create-security-group --group-name source-truth-efs-sg --description "source-truth EFS NFS" --vpc-id "$VPC_ID" --query GroupId --output text)"
fi
# Reconcile the :2049 ingress rule EVERY run (NOT gated on SG creation): a crash
# between create-security-group and authorize would otherwise leave a tagged-but-
# ruleless EFS SG that a re-run skips, so EFS mounts hang for both index-service
# and the runtime — and no health gate catches it (loopback /health never crosses
# NFS). Tolerate ONLY the benign Duplicate error; hard-fail anything else, so a
# real authorize failure aborts the deploy instead of silently breaking EFS.
# Same crash-safe pattern as provision_index_service.sh and provision_network.sh.
efs_authorize_err="$(QE authorize-security-group-ingress --group-id "$EFS_SG" --protocol tcp --port 2049 --cidr "${VPC_CIDR:-10.1.0.0/16}" 2>&1 >/dev/null)" || {
  case "$efs_authorize_err" in
    *InvalidPermission.Duplicate*) : ;;  # already present — idempotent, fine
    *) say err "failed to authorize EFS :2049 ingress on $EFS_SG: $efs_authorize_err"; exit 1 ;;
  esac
}

# Mount target in the private subnet (one per AZ).
if [[ "$(Q describe-mount-targets --file-system-id "$EFS_ID" --query 'length(MountTargets)' --output text)" == "0" ]]; then
  Q create-mount-target --file-system-id "$EFS_ID" --subnet-id "$PRIVATE_SUBNET" --security-groups "$EFS_SG" >/dev/null
  say info "waiting for mount target ..."
  MT_READY=false
  for _ in $(seq 1 30); do
    [[ "$(Q describe-mount-targets --file-system-id "$EFS_ID" --query 'MountTargets[0].LifeCycleState' --output text)" == available ]] && { MT_READY=true; break; }
    sleep 5
  done
  [[ "$MT_READY" == true ]] || { say err "EFS mount target did not become available within timeout"; exit 1; }
fi

update_env "$CONFIG" EFS_ID "$EFS_ID"
update_env "$CONFIG" EFS_ACCESS_POINT "$AP"
update_env "$CONFIG" EFS_SG "$EFS_SG"
say ok "efs ready: fs=$EFS_ID ap=$AP sg=$EFS_SG"
