#!/usr/bin/env bash
# provision_index_service.sh <region> <config> <bucket> <max_files> <instance_type> [refresh] [root_volume_gb] [model] [glossary_max_files]
# Provisions the BASE index host only — an idempotent ARM EC2 (Ubuntu 24.04, glibc 2.39 for
# codegraph-server) in the private subnet running index-service/bootstrap.sh as user-data. Binds
# NO project (projects are attached later by activate_project.sh over SSM). Prints the instance's
# private IP on stdout (the only stdout line; logs go to stderr).
#
# Security: index-svc SG accepts the bridge port RANGE (8080-8099) from the VPC — one port per
# project (multiple projects share this host, each bridge on its own port). The runtime reaches
# its project's bridge over the private network. No EFS (each repo copy is local to this instance).
#
# refresh (7th arg, "true"/"false", default false): when true, a reused instance
# whose bootstrapped artifacts are STALE (S3 tarballs re-staged since it booted)
# is terminated so a fresh one re-bootstraps the new code/repo. When false, a
# stale reuse only WARNs (loudly) — it never silently serves old code as "green".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; BUCKET="$3"; MAX_FILES="$4"; ITYPE="$5"; REFRESH="${6:-false}"; ROOT_VOLUME_GB="${7:-30}"; MODEL="${8:-global.anthropic.claude-opus-4-8}"; GLOSSARY_MAX_FILES="${9:-400}"
safe_source_env "$CONFIG"
Q() { aws ec2 "$@" --region "$REGION"; }
QS() { aws s3api "$@" --region "$REGION"; }
log() { say "$@" >&2; }

LOCAL_MODE="${ST_LOCAL_MODE:-false}"

# IMDSv2 helpers (token-first). Used ONLY in local mode to learn THIS instance's id; VPC/subnet/SG
# are then read via describe-instances (authoritative, no fragile mac-path scraping).
imds_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo ""
}
imds_field() {
  local tok; tok="$(imds_token)"
  curl -fsS -H "X-aws-ec2-metadata-token: $tok" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
}

# A signature of the BASE-HOST artifacts an instance bootstraps from: the ETags of the
# index-service code tarball + the bot-gateway tarball in S3. Repos are NO LONGER part of
# this — they arrive via git (activate_project.sh git-clones + a refresh timer git-pulls),
# so a repo change is picked up live and never requires replacing the host. The host is
# replaced (--refresh-index) only when the BASE CODE (bridge / gateway / its deps) changes.
# ETag is S3's content hash, so this changes iff the staged base code changed.
artifact_signature() {
  local idx gw
  idx="$(QS head-object --bucket "$BUCKET" --key index-service.tar.gz --query ETag --output text 2>/dev/null || echo none)"
  # bot-gateway runs ON this instance, so its tarball is part of what a fresh bootstrap
  # installs — include it so a gateway-only code change is detected as STALE and (with
  # --refresh-index) replaces the instance. Absent (backend-only) → "none", stable.
  gw="$(QS head-object --bucket "$BUCKET" --key bot-gateway.tar.gz --query ETag --output text 2>/dev/null || echo none)"
  # S3 returns ETags WITH literal surrounding double-quotes (e.g. "abc123"). Strip them
  # before this lands in the run-instances --tag-specifications SHORTHAND: a Value= starting
  # with `"` makes the shorthand parser terminate at the closing quote, then choke on the `|`
  # separator (ParamValidation), aborting the launch under set -e. Quote-free both sides keeps
  # the comparison consistent.
  idx="${idx//\"/}"
  gw="${gw//\"/}"
  echo "${idx}|${gw}"
}

# Authorize an ingress rule idempotently: tolerate ONLY the benign "rule already
# exists" (InvalidPermission.Duplicate) error, and HARD-FAIL on anything else
# (throttling, bad CIDR, IAM denial). A blanket `|| true` would silently swallow
# a real failure and leave the rule missing — which no downstream gate catches
# (the bridge health checks curl :8080 over loopback, never crossing the SG), so
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

# Reconcile the index-service SG's bridge-port-RANGE ingress rule. One port per project
# (8080-8099), so the rule is a range. Source is the index SG ITSELF (self-referencing), NOT the
# whole VPC CIDR: the AgentCore runtimes are launched INTO this same SG (deploy_project.sh passes
# INDEX_SERVICE_SG as the runtime SG), so SG members reach each other's bridge ports, but an
# arbitrary VPC host can't — the bridge has no MCP authn, so VPC-wide ingress would let any VPC
# peer (or a compromised peer runtime) read another project's indexed source (cross-review MEDIUM).
# Run on EVERY invocation and BOTH paths (reuse + fresh): the rule's absence is invisible to every
# downstream gate (the /health probe is loopback-only). Idempotent (Duplicate ok).
reconcile_index_sg_ingress() { # <sg>
  authorize_ingress ":8080-8099 from SG members on $1" \
    --group-id "$1" --protocol tcp --port 8080-8099 --source-group "$1"
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

if [[ "$LOCAL_MODE" == "true" ]]; then
  log step "local mode: this host IS the index host — provisioning in place"
  SELF_ID="$(imds_field instance-id)"
  [[ -n "$SELF_ID" ]] || { log err "local mode: IMDS unavailable (need an EC2 with IMDSv2 reachable)"; exit 1; }
  read -r SELF_IP SELF_VPC SELF_SUBNET < <(Q describe-instances --instance-ids "$SELF_ID" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,VpcId,SubnetId]' --output text)
  [[ -n "$SELF_IP" && "$SELF_VPC" != None && -n "$SELF_SUBNET" ]] \
    || { log err "local mode: could not read IP/VPC/subnet for $SELF_ID"; exit 1; }

  # VPC DNS attributes MUST be on, or index.source-truth.internal (the Route53 private zone the
  # runtime resolves for CODEGRAPH_MCP_URL) returns NXDOMAIN → empty codegraph on EVERY question.
  # launch-host's provision_network.sh sets these, but deploy-all --local does NOT re-run that phase
  # (it derives VPC/subnet from this instance), so a host placed in a VPC by other means could have
  # them off. Assert it here, in the phase that owns local mode — idempotent, closes the silent hole.
  Q modify-vpc-attribute --vpc-id "$SELF_VPC" --enable-dns-support >/dev/null
  Q modify-vpc-attribute --vpc-id "$SELF_VPC" --enable-dns-hostnames >/dev/null

  # DEDICATED SG (NOT the operator's primary SG): self-referencing 8080-8099 only, so only SG
  # members (this host + the runtimes we launch into it) reach the bridge — the bridge has no MCP
  # authn. Attach it ADDITIVELY to this instance (keep the operator's existing SGs).
  SG="$(Q describe-security-groups --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=$SELF_VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [[ "$SG" == "None" || -z "$SG" ]]; then
    SG="$(Q create-security-group --group-name source-truth-index-svc --description "index-service codegraph bridge" --vpc-id "$SELF_VPC" --query GroupId --output text)"
  fi
  reconcile_index_sg_ingress "$SG"
  # Collect the instance's current SGs into an ARRAY and filter "None"/empty, so --groups is never
  # malformed. modify-instance-attribute --groups is REPLACE-semantics → pass existing + new together
  # to ADD without dropping any. Skip entirely if the dedicated SG is already attached (idempotent).
  mapfile -t CUR_SGS < <(Q describe-instances --instance-ids "$SELF_ID" \
    --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | grep -E '^sg-')
  # GUARD: a running instance ALWAYS has ≥1 SG. An empty read means an IAM/throttle/race glitch —
  # bail rather than call modify-instance-attribute with just "$SG" (which would STRIP the operator's
  # existing SGs — the opposite of the additive intent).
  [[ ${#CUR_SGS[@]} -gt 0 ]] || { log err "local mode: read 0 current SGs for $SELF_ID (transient API glitch?) — refusing to modify groups; re-run"; exit 1; }
  _has_sg=false; for g in "${CUR_SGS[@]}"; do [[ "$g" == "$SG" ]] && _has_sg=true; done
  if [[ "$_has_sg" != true ]]; then
    Q modify-instance-attribute --instance-id "$SELF_ID" --groups "${CUR_SGS[@]}" "$SG"
  fi

  # INSTANCE-ROLE PRECHECK (A2 — else gateway 403s every answer, glossary silently empty, no logs).
  # We do NOT grant IAM here (that needs the deploy identity to hold iam:PutRolePolicy on the
  # operator's role); the runbook lists the policies the role must carry. Just fail loud if the box
  # has no role or can't read the artifact bucket — before bootstrap dies opaquely on the S3 pull.
  SELF_ROLE="$(Q describe-instances --instance-ids "$SELF_ID" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text 2>/dev/null || echo None)"
  if [[ -z "$SELF_ROLE" || "$SELF_ROLE" == None ]]; then
    log err "local mode: this EC2 has NO IAM instance profile — it cannot read S3 artifacts, invoke"
    log err "  Bedrock, or invoke the AgentCore runtime. Attach the role from the runbook spec and re-run."
    exit 1
  fi
  if ! sudo aws s3 ls "s3://${BUCKET}/" --region "$REGION" >/dev/null 2>&1; then
    log err "local mode: this instance's role cannot read s3://${BUCKET} — check the instance role"
    log err "  created via scripts/lib/create-iam.sh (see runbook), then re-run."
    exit 1
  fi
  log info "local mode: instance role present + S3 artifact read OK ($SELF_ROLE)"

  sudo tee /etc/index-service.env >/dev/null <<ENV
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
MODEL='$MODEL'
GLOSSARY_MAX_FILES='$GLOSSARY_MAX_FILES'
ENV
  # Synchronous bootstrap, but bounded: a hung apt/pip must not wedge the deploy forever.
  log info "local mode: running bootstrap.sh in place (bounded 1800s) ..."
  # --foreground: GNU timeout normally puts the command in a NEW process group (to kill the whole
  # tree on expiry) — but a background process group that touches the controlling tty gets
  # SIGTTIN/SIGTTOU and is STOPPED by the kernel. With bootstrap now streaming to the operator's
  # terminal (tee), apt's post-install steps (needrestart) hit exactly that and hung forever in
  # do_signal_stop. --foreground keeps the command in OUR (foreground) process group so tty access
  # is legal; </dev/null belts-and-suspenders any stray stdin read.
  timeout --foreground 1800 sudo -E bash "$ROOT/index-service/bootstrap.sh" </dev/null >&2 \
    || { log err "local-mode bootstrap.sh failed/timed out — see /var/log/index-svc-bootstrap.log"; exit 1; }

  # PRIVATE_SUBNET feeds the AgentCore runtime ENI (deploy_project.sh → deploy_runtime.py). It must
  # be a PRIVATE subnet with NAT egress, NOT this host's own subnet: a VPC-mode runtime ENI gets no
  # public IP, so it can't reach Bedrock via an IGW — only via NAT. This host itself may sit in a
  # public subnet (it has a public IP for SSH). Take the source-truth-private subnet that
  # launch-host's network step (provision_network.sh) created in this VPC.
  mapfile -t PRIV_SUBNETS < <(Q describe-subnets --filters "Name=tag:Name,Values=source-truth-private" \
    "Name=vpc-id,Values=$SELF_VPC" --query 'Subnets[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^subnet-')
  if [[ ${#PRIV_SUBNETS[@]} -eq 0 ]]; then
    log err "local mode: no source-truth-private subnet in $SELF_VPC — the AgentCore runtime needs a"
    log err "  private subnet with NAT egress to reach Bedrock. Run scripts/launch-host.sh (it builds"
    log err "  the network), or create the source-truth network in this VPC, then re-run."
    exit 1
  fi
  PRIV_SUBNET="${PRIV_SUBNETS[0]}"
  # provision_network.sh creates exactly one. >1 means a hand-built VPC with duplicate tags — we
  # can't tell which has the NAT route, so warn rather than silently pick one that may have none.
  [[ ${#PRIV_SUBNETS[@]} -gt 1 ]] && log warn "local mode: ${#PRIV_SUBNETS[@]} subnets tagged source-truth-private in $SELF_VPC — using $PRIV_SUBNET; verify it routes 0.0.0.0/0 → NAT"
  update_env "$CONFIG" PRIVATE_SUBNET "$PRIV_SUBNET"
  update_env "$CONFIG" VPC_ID "$SELF_VPC"
  update_env "$CONFIG" INDEX_SERVICE_SG "$SG"
  update_env "$CONFIG" INDEX_SERVICE_INSTANCE "$SELF_ID"
  log info "local mode: index host ready at $SELF_IP (instance $SELF_ID, dedicated sg $SG)"
  echo "$SELF_IP"; exit 0
fi

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
  [[ "$dns_ip" == "None" ]] && dns_ip=""
  # FAIL-CLOSED on an EMPTY dns_ip: a Route53 query that errored (throttle / transient /
  # missing INDEX_DNS_ZONE_ID) is swallowed to "" above — that means "couldn't look", NOT
  # "DNS points elsewhere". Terminating on unknown would kill the live host the DNS may
  # still point at (the terminate-first outage this reconcile exists to prevent). Only GC
  # when the lookup POSITIVELY returned a different IP.
  if [[ ( "$st" == "running" || "$st" == "pending" || "$st" == "stopping" ) && -n "$old_ip" && -n "$dns_ip" && "$old_ip" != "$dns_ip" ]]; then
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
# bootstrap.sh sets up the BASE host only (no project). Projects are attached later over SSM by
# deploy_project.sh → activate_project.sh, so user-data carries NO manifest — just the base env.
UD="$(cat <<EOF
#!/bin/bash
set -e
cat > /etc/index-service.env <<ENV
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
MODEL='$MODEL'
GLOSSARY_MAX_FILES='$GLOSSARY_MAX_FILES'
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
