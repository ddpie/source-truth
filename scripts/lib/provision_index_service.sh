#!/usr/bin/env bash
# provision_index_service.sh <region> <config> <bucket> <repo_subdir> <max_files> <instance_type> [refresh]
# Idempotent ARM EC2 (Ubuntu 24.04 — glibc 2.39 for codegraph-server) in the
# private subnet, running index-service/bootstrap.sh as user-data. Prints the
# instance's private IP on stdout (the only stdout line; logs go to stderr).
#
# Security: index-svc SG accepts 8080 from the VPC; the runtime reaches it over
# the private network. No EFS (the repo copy is local to this instance).
#
# refresh (7th arg, "true"/"false", default false): when true, a reused instance
# whose bootstrapped artifacts are STALE (S3 tarballs re-staged since it booted)
# is terminated so a fresh one re-bootstraps the new code/repo. When false, a
# stale reuse only WARNs (loudly) — it never silently serves old code as "green".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; BUCKET="$3"; REPO_SUBDIR="$4"; MAX_FILES="$5"; ITYPE="$6"; REFRESH="${7:-false}"; ROOT_VOLUME_GB="${8:-30}"
safe_source_env "$CONFIG"
Q() { aws ec2 "$@" --region "$REGION"; }
QS() { aws s3api "$@" --region "$REGION"; }
log() { say "$@" >&2; }

# A signature of the artifacts an instance would bootstrap from: the ETags of the
# index-service code tarball + the repo tarball in S3. If either changed since an
# instance booted, that instance is serving STALE code/index. ETag is S3's
# content hash, so this changes iff the staged content changed.
artifact_signature() {
  local idx repo gw
  idx="$(QS head-object --bucket "$BUCKET" --key index-service.tar.gz --query ETag --output text 2>/dev/null || echo none)"
  repo="$(QS head-object --bucket "$BUCKET" --key "${REPO_SUBDIR}.tar.gz" --query ETag --output text 2>/dev/null || echo none)"
  # bot-gateway runs ON this instance now, so its tarball is part of what a fresh
  # bootstrap installs — include it so a gateway-only code change is detected as
  # STALE and (with --refresh-index) replaces the instance. Absent (backend-only
  # deploy) → "none", stable, so it doesn't perturb the signature.
  gw="$(QS head-object --bucket "$BUCKET" --key bot-gateway.tar.gz --query ETag --output text 2>/dev/null || echo none)"
  # S3 returns ETags WITH literal surrounding double-quotes (e.g. "abc123"). They
  # must be stripped before this value lands in the run-instances
  # --tag-specifications SHORTHAND: a Value= starting with `"` makes the shorthand
  # parser terminate the string at the closing quote, then choke on the `|`
  # separator (ParamValidation: Expected ','), which under set -e aborts the whole
  # fresh launch. Strip quotes so the joined signature is a plain, parseable,
  # human-readable tag value. Comparison stays consistent (both sides quote-free).
  idx="${idx//\"/}"
  repo="${repo//\"/}"
  gw="${gw//\"/}"
  echo "${idx}|${repo}|${gw}"
}

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
# A reused instance does NOT re-run bootstrap.sh (that's EC2 user-data, fires
# only on first boot), so it will NOT pick up index-service code or repo changes
# re-staged to S3 this run. The single-writer invariant (exactly one instance may
# ever build graph.db on its local disk) forbids just launching a second one. So:
#   - compute the current artifact signature (S3 ETags) and compare to the tag we
#     stamped on the instance when it last bootstrapped;
#   - if they match → genuine reuse, fast-path;
#   - if they differ and REFRESH=true → terminate it so a fresh instance
#     re-bootstraps from the new artifacts (sequential — the old one is gone
#     before the new one builds, preserving single-writer);
#   - if they differ and REFRESH=false → LOUD WARN and reuse anyway, so the green
#     deploy is never a SILENT no-op (the operator is told their changes aren't
#     live and how to apply them).
CURRENT_SIG="$(artifact_signature)"
# RECONCILE a stale blue-green leftover — CAREFULLY. INDEX_OLD_INSTANCE is the prior
# instance recorded during a --refresh-index, normally terminated LAST by deploy-all
# after the new one is healthy + DNS cut over. If that refresh FAILED the health gate,
# deploy-all exits before the terminate, leaving the marker set. CRITICAL: on a failed
# refresh the recorded instance is the OLD one that is STILL SERVING (DNS still points
# at it) — so we must NOT blindly terminate it (that re-introduces the very
# terminate-first outage blue-green exists to prevent). Only GC it when it's safe:
# i.e. it is NOT the instance the stable DNS name currently resolves to (so a healthy
# replacement is already serving). Otherwise leave it running (it's the live host) and
# let a normal --refresh-index replace it via the make-before-break path. Best-effort.
if [[ -n "${INDEX_OLD_INSTANCE:-}" ]]; then
  st="$(Q describe-instances --instance-ids "$INDEX_OLD_INSTANCE" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "")"
  old_ip="$(Q describe-instances --instance-ids "$INDEX_OLD_INSTANCE" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || echo "")"
  dns_ip="$(aws route53 list-resource-record-sets --hosted-zone-id "${INDEX_DNS_ZONE_ID:-}" --query "ResourceRecordSets[?Name=='${INDEX_DNS_NAME:-none}.'].ResourceRecords[0].Value | [0]" --output text 2>/dev/null || echo "")"
  if [[ ( "$st" == "running" || "$st" == "pending" || "$st" == "stopping" ) && -n "$old_ip" && "$old_ip" != "$dns_ip" ]]; then
    log warn "reconcile: terminating stale blue-green leftover $INDEX_OLD_INSTANCE ($old_ip, state=$st; DNS points elsewhere at ${dns_ip:-?} so it's safe)"
    Q terminate-instances --instance-ids "$INDEX_OLD_INSTANCE" >/dev/null 2>&1 || true
    update_env "$CONFIG" INDEX_OLD_INSTANCE ""
  elif [[ "$st" != "running" && "$st" != "pending" && "$st" != "stopping" ]]; then
    update_env "$CONFIG" INDEX_OLD_INSTANCE ""  # already gone — just clear the marker
  else
    log info "reconcile: leftover $INDEX_OLD_INSTANCE is the LIVE host DNS still points at ($old_ip) — leaving it; a --refresh-index will replace it safely"
  fi
fi
# SINGLE-INSTANCE GUARD: keep exactly one index-service alive at a time. An
# instance still in a TRANSIENT shutdown state (stopping / shutting-down) isn't
# seen by the reuse filter below (which only matches running/pending), so without
# this a fresh launch could briefly run alongside a draining peer. Each instance
# holds its OWN local repo copy + graph now (no shared EFS), so this is no longer
# a corruption risk — just hygiene to avoid two paid instances. Wait for any such
# peer to fully terminate first.
DRAINING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=stopping,shutting-down,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
if [[ "$DRAINING" != "None" && -n "$DRAINING" ]]; then
  log warn "an index-service instance ($DRAINING) is still draining (stopping/shutting-down); waiting for it to terminate before launching, to avoid running two paid instances"
  Q wait instance-terminated --instance-ids "$DRAINING" 2>/dev/null || true
fi
# DETERMINISTIC selection: if two index instances are briefly running (blue-green
# overlap, or a stale leftover the reconcile above didn't catch), a blind
# Reservations[0].Instances[0] could pick the WRONG (old-artifact) one. Prefer the
# instance whose ArtifactSig matches CURRENT_SIG (the correct/current build); only if
# none match, fall back to any running/pending one (the genuine "needs refresh" case).
EXISTING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=tag:ArtifactSig,Values=$CURRENT_SIG" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
if [[ "$EXISTING" == "None" || -z "$EXISTING" ]]; then
  EXISTING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
fi
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  BOOTED_SIG="$(Q describe-instances --instance-ids "$EXISTING" --query "Reservations[0].Instances[0].Tags[?Key=='ArtifactSig'].Value | [0]" --output text 2>/dev/null)"
  if [[ "$BOOTED_SIG" != "$CURRENT_SIG" ]]; then
    if [[ "$REFRESH" == "true" ]]; then
      # BLUE-GREEN: do NOT terminate the old instance here. Terminating up-front
      # (before the new one is healthy + DNS re-pointed) leaves the stable name
      # index.source-truth.internal resolving to a DEAD host for the whole multi-
      # minute cold bootstrap → warm agent microVMs get connection-refused → empty
      # codegraph → empty answer cards (the residual we observed). And if the new
      # build fails health, the old (working) instance is already gone = total
      # outage. So we RECORD the old id for deploy-all to terminate LAST (after the
      # new instance is /health-green and DNS is cut over + TTL-drained), and fall
      # through to launch the new one alongside it. Two instances briefly coexist —
      # SAFE: each holds its OWN local graph.db (no shared writer), only paid-cost.
      log warn "index-service artifacts changed since $EXISTING booted (sig: ${BOOTED_SIG:-none} → $CURRENT_SIG); --refresh-index set → blue-green: launching a fresh instance, old ($EXISTING) terminated AFTER new is healthy + DNS cut over"
      update_env "$CONFIG" INDEX_OLD_INSTANCE "$EXISTING"
      EXISTING="None"  # fall through to fresh launch below (old left running)
    else
      log warn "STALE index-service: instance $EXISTING booted from older artifacts (sig ${BOOTED_SIG:-none}, current $CURRENT_SIG)."
      log warn "  → This deploy re-staged index-service code/repo to S3 but reuse does NOT re-bootstrap, so those changes are NOT live."
      log warn "  → Re-run with --refresh-index to replace the instance, or terminate $EXISTING manually, then re-run."
    fi
  fi
fi
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  IP="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  if [[ -z "$IP" || "$IP" == "None" ]]; then
    log err "reuse: instance $EXISTING has no private IP yet"; exit 1
  fi
  SG="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)"
  # If the operator asked for a DIFFERENT instance type than the reused instance
  # actually runs, the reuse path silently ignores --instance-type (no relaunch), so
  # they'd think the machine changed when it didn't. WARN with the actionable flag
  # rather than silently honor the stale type (cross-review).
  RUNNING_TYPE="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo "")"
  if [[ -n "$RUNNING_TYPE" && "$RUNNING_TYPE" != "None" && "$RUNNING_TYPE" != "$ITYPE" ]]; then
    log warn "reused instance $EXISTING runs $RUNNING_TYPE, not the requested $ITYPE; instance-type change needs --refresh-index to relaunch"
  fi
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

# Latest Ubuntu 24.04 ARM AMI (Canonical owner id 099720109477).
AMI="$(Q describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)"
# `--output text` with NO match returns the literal "None" (and an empty result is
# ""), which would otherwise flow into run-instances as `--image-id None` → an opaque
# InvalidAMIID failure. Canonical's owner id is global, but a brand-new / GovCloud /
# China region may not carry this noble-arm64 image (or uses a different owner). Fail
# with an ACTIONABLE message naming the cause + the SSM-parameter alternative.
if [ -z "$AMI" ] || [ "$AMI" = "None" ]; then
  say err "no Ubuntu 24.04 arm64 AMI found from Canonical (owner 099720109477) in $REGION."
  say err "this region may not carry that image (or uses a different owner, e.g. GovCloud/China)."
  say err "set an explicit AMI via the SSM public parameter, e.g.:"
  say err "  aws ssm get-parameter --region $REGION --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
  # exit, NOT return: this script is EXECUTED (deploy-all runs it via $(...)), not sourced.
  # `return` outside a function then fails with rc=2 + a confusing "can only return from a
  # function" message that buries the actionable AMI guidance above (cross-review LOW).
  exit 1
fi

# user-data: write env file, FETCH bootstrap.sh from S3 via curl, run it. We stage
# bootstrap.sh to S3 and pass a PRESIGNED URL (no creds/awscli needed on the fresh
# instance — the base Ubuntu AMI has curl but no aws CLI yet) rather than
# base64-embedding the script in user-data: EC2 caps the encoded user-data blob at
# 25600 bytes, which the growing bootstrap.sh blew past (the embed double-encodes).
# A tiny fetch-and-run user-data is size-stable regardless of bootstrap.sh length.
aws s3 cp "$ROOT/index-service/bootstrap.sh" "s3://$BUCKET/bootstrap.sh" --region "$REGION" >&2
# Presign with a long expiry so a delayed cloud-init (or a retry) can still fetch.
BOOT_URL="$(aws s3 presign "s3://$BUCKET/bootstrap.sh" --region "$REGION" --expires-in 3600)"
# bootstrap.sh now consumes REPO_MANIFEST_JSON (the project's repo set in ONE JSON value,
# multi-repo 阶段2) instead of REPO_SUBDIR/ARTIFACT_SIG. Today's single-repo deploy is that
# manifest with ONE entry — built here from REPO_SUBDIR + this repo's S3 ETag (the same value
# the artifact signature already strips quotes from). JSON lives inside SINGLE quotes in the
# env file, so its double-quotes and a multipart ETag's `|` are inert (no shell reparse — the
# lesson behind using one JSON var, not per-repo shell vars). Build it with python's json so a
# subdir/ETag with a metacharacter can never break out of the string.
REPO_ETAG="$(QS head-object --bucket "$BUCKET" --key "${REPO_SUBDIR}.tar.gz" --query ETag --output text 2>/dev/null || echo "")"
REPO_ETAG="${REPO_ETAG//\"/}"
# Build the manifest via render_manifest --build — the SINGLE manifest-construction authority
# (same parser the instance validates with), so an invalid subdir fails LOUD here at deploy,
# not silently later at bootstrap. One TAB-separated row: subdir<TAB>source<TAB>sig.
REPO_MANIFEST_JSON="$(printf '%s\t%s\t%s\n' "$REPO_SUBDIR" "s3://staged" "$REPO_ETAG" \
  | python3 "$SCRIPT_DIR/render_manifest.py" --build)" \
  || { log err "failed to build REPO_MANIFEST_JSON (invalid repo_subdir=$REPO_SUBDIR?)"; exit 1; }
UD="$(cat <<EOF
#!/bin/bash
set -e
cat > /etc/index-service.env <<ENV
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
REPO_MANIFEST_JSON='$REPO_MANIFEST_JSON'
ENV
for i in 1 2 3 4 5 6; do curl -fsSL "$BOOT_URL" -o /opt/bootstrap.sh && break || sleep 10; done
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
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=source-truth-index-service},{Key=ArtifactSig,Value=$CURRENT_SIG}]" \
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
