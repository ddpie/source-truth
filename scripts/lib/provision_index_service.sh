#!/usr/bin/env bash
# provision_index_service.sh <region> <config> <bucket> <max_files> <instance_type> [root_volume_gb] [model] [glossary_max_files]
# Provisions the BASE index host only — an idempotent ARM EC2 (Ubuntu 24.04, glibc 2.39 for
# codegraph-server) in the private subnet running index-service/bootstrap.sh as user-data. Binds
# NO project (projects are attached later by activate_project.sh over SSM). Prints the instance's
# private IP on stdout (the only stdout line; logs go to stderr).
#
# Security: index-svc SG accepts the bridge port RANGE (8080-8099) from the VPC — one port per
# project (multiple projects share this host, each bridge on its own port). The runtime reaches
# its project's bridge over the private network. No EFS (each repo copy is local to this instance).
#
# IN-PLACE UPDATES ONLY — 只做原地更新，不再做蓝绿替换 (blue-green replacement REMOVED).
# An existing instance is NEVER terminated and NEVER replaced: when the staged base-code
# artifacts differ from what it booted from, we re-run bootstrap.sh ON THAT INSTANCE over SSM
# (idempotent — the same thing local mode does on every run) and re-stamp its ArtifactSig tag.
# The only remaining run-instances is a genuinely empty account (first deploy / someone
# terminated the host). This is the single note about the removed path — it was a mis-kill risk
# (the "which box is safe to terminate" decision hinged on a Route53 lookup plus an
# INDEX_OLD_INSTANCE config marker) and it leaked paid instances whenever a refresh aborted.
# INDEX_OLD_INSTANCE is now a DEAD KEY: nothing writes it, nothing reads it, a leftover is ignored.
#
# BREAK-BEFORE-MAKE on the in-place path (see rebootstrap_in_place): bootstrap.sh rewrites
# /opt/bot-gateway and /opt/idx/app, and its `npm ci` deletes node_modules outright — under a live
# process that is a MODULE_NOT_FOUND crash loop on the next lazy require(). So the re-bootstrap
# STOPS the active bot-gateway@* / index-bridge-* units, runs, then starts exactly that captured
# list. The host is deliberately DOWN for the length of the run (minutes); the alternative was new
# code on disk that no process had loaded — and on --skip-projects nothing restarted at all.
#
# Env knobs: INDEX_REBOOTSTRAP_TIMEOUT_SECS (default 1800) bounds the in-place SSM run — raise it
# for a slow host (cold apt + npm on a small ARM box can exceed 30 min). Must be a positive
# integer; anything else falls back to the default with a warning instead of aborting on an
# arithmetic error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; BUCKET="$3"; MAX_FILES="$4"; ITYPE="$5"; ROOT_VOLUME_GB="${6:-30}"; MODEL="${7:-global.anthropic.claude-opus-4-8}"; GLOSSARY_MAX_FILES="${8:-400}"
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
# index-service code tarball + the bot-gateway tarball in S3, PLUS a hash of bootstrap.sh
# itself. Repos are NO LONGER part of this — they arrive via git (activate_project.sh
# git-clones + a refresh timer git-pulls), so a repo change is picked up live and never touches
# the host. The signature therefore tracks the BASE CODE only (bridge / gateway / their deps /
# the script that installs them); when it changes we re-bootstrap the existing host IN PLACE
# — 只重跑 bootstrap，不换机器. ETag is S3's content hash, so it changes iff the code changed.
#
# bootstrap.sh IS a component (M10). It carries the systemd unit templates, the CloudWatch
# config, the Node version and the install steps, and since the host is never replaced any more
# the in-place re-bootstrap is the ONLY channel by which an edit to it ever reaches a running
# host: left out of the signature, such an edit was staged to S3 and then silently skipped as
# "already on the current base artifacts". Hashed LOCALLY (not via its S3 ETag) so the value
# does not depend on whether the upload happened before or after this call. NOTE: adding this
# third component changes the signature FORMAT, so every existing host re-bootstraps once on
# the next deploy — that is the intended catch-up, not a bug.
#
# ABSENT vs FAILED (C2). Both head-object calls used to end in `|| echo none`, so any throttle,
# expired credential or network blip collapsed the signature to "none|none" — which reads as
# "artifacts changed" and triggered a multi-minute MUTATING re-bootstrap of a perfectly healthy
# host, then stamped ArtifactSig=none|none so every later deploy mismatched and re-bootstrapped
# again. A swallowed READ error must never cause a repeated WRITE action, so: a genuine 404 maps
# to "none", and anything else is fatal with the AWS message attached.
head_object_etag() { # <key> — prints the quote-free ETag, or "none" iff the key genuinely 404s
  local key="$1" out
  # 2>&1 folds the AWS error into $out on failure; on success head-object writes nothing to
  # stderr, so the captured value stays clean.
  if out="$(QS head-object --bucket "$BUCKET" --key "$key" --query ETag --output text 2>&1)"; then
    # S3 returns ETags WITH literal surrounding double-quotes (e.g. "abc123"). Strip them before
    # this lands in the run-instances --tag-specifications SHORTHAND: a Value= starting with `"`
    # makes the shorthand parser terminate at the closing quote, then choke on the `|` separator
    # (ParamValidation), aborting the launch under set -e. Quote-free keeps comparisons consistent.
    printf '%s' "${out//\"/}"
    return 0
  fi
  case "$out" in
    *404*|*"Not Found"*|*NotFound*|*NoSuchKey*) printf 'none'; return 0 ;;
  esac
  log err "head-object s3://$BUCKET/$key failed and it is NOT a 404 — refusing to guess the"
  log err "  artifact signature (a wrong guess re-bootstraps a healthy host and poisons its tag):"
  log err "  → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 1
}
artifact_signature() {
  local idx gw bs cg
  idx="$(head_object_etag index-service.tar.gz)" || return 1
  # The artifacts phase ALWAYS stages this one, so "absent" means the deploy ran out of order or
  # points at the wrong bucket — fatal, never a legitimate "none".
  [[ "$idx" != none ]] || {
    log err "index-service.tar.gz is absent from s3://$BUCKET — run the artifacts phase (deploy-all.sh) first"
    return 1
  }
  # bot-gateway runs ON this instance, so its tarball is part of what a bootstrap run installs —
  # include it so a gateway-only code change is detected as STALE and triggers the in-place
  # re-bootstrap. Genuinely absent on a backend-only deploy → "none" (see effective_sig: a "none"
  # is never stamped over a real ETag).
  gw="$(head_object_etag bot-gateway.tar.gz)" || return 1
  bs="$(sha256sum "$ROOT/index-service/bootstrap.sh" 2>/dev/null | cut -c1-16)"
  [[ -n "$bs" ]] || { log err "cannot hash $ROOT/index-service/bootstrap.sh — incomplete checkout?"; return 1; }
  # codegraph-server: bootstrap.sh installs this binary, and since the host is never replaced a
  # bootstrap run is the ONLY channel that reaches an existing one. Omitting it meant bumping
  # CODEGRAPH_SERVER_TAG re-staged the binary to S3, the comparison saw no change, and the new
  # binary never landed — the same silent no-op the bootstrap.sh component was added to close,
  # left open for the largest artifact. Absent → "none" (a host may predate the staged layout).
  cg="$(head_object_etag bin/codegraph-server)" || return 1
  echo "${idx}|${gw}|${bs}|${cg}"
}

# Never DOWNGRADE a signature component to "none" (C2, second half). "none" means the key is
# genuinely absent from the bucket THIS run — legitimate for bot-gateway.tar.gz on a backend-only
# deploy. Stamping it over a real ETag would both trigger a pointless re-bootstrap and leave a tag
# that mismatches on every future deploy. So for the comparison AND for the stamp we keep whatever
# component the host already booted from when this run has nothing to say about it.
_sig_component() { # <current> <booted>
  if [[ "$1" == none && -n "${2:-}" && "$2" != none && "$2" != None ]]; then
    log warn "artifact absent from the bucket this run — keeping the component the host booted from ($2)"
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}
effective_sig() { # <booted-sig> — the signature to COMPARE against and to STAMP
  local cur=() boot=() out=() i
  IFS='|' read -r -a cur <<< "$CURRENT_SIG"
  IFS='|' read -r -a boot <<< "${1:-}"
  # Iterate over however many components CURRENT_SIG has, rather than a fixed printf. The fixed
  # three-slot form silently DROPPED any component added later, which would have made adding the
  # codegraph-server component a no-op — the same class of miss the component was closing.
  for (( i = 0; i < ${#cur[@]}; i++ )); do
    out+=( "$(_sig_component "${cur[$i]:-none}" "${boot[$i]:-}")" )
  done
  local IFS='|'
  printf '%s' "${out[*]}"
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

# Reuse strategy for a running index-service host: see the block after the local-mode branch,
# where the artifact signature is computed (local mode never needs it — it runs bootstrap.sh
# directly on this box on every invocation).

# --- EC2 auto-recovery + termination protection (C2: runtime reliability) --------
# System status-check failures (underlying hardware / hypervisor) are unrecoverable
# without migrating the instance. A CloudWatch alarm triggers EC2 auto-recovery
# (live-migrates to healthy hardware, preserving instance-id / IP / EBS). Idempotent:
# put-metric-alarm overwrites, modify-instance-attribute is a no-op when already set.
#
# Called from BOTH provisioning paths — local mode (this host) and the two-machine
# path (the instance we just launched). It MUST stay a function rather than an inline
# tail block: local mode returns early (`echo "$SELF_IP"; exit 0`), so anything placed
# after the two-machine run-instances never runs for a single-host deploy. All output
# goes through `log` (stderr) and AWS output is discarded, so this never pollutes the
# stdout the caller captures as the host IP.
arm_instance_resilience() {
  local iid="$1"
  local alarm_name="source-truth-index-auto-recover-${REGION}"
  local err

  # Capture stderr rather than discarding it: an opaque "failed" line cost a live
  # debugging round (the real cause was an IAM AccessDenied on the service-linked
  # role) — a non-fatal warning must still say WHY.
  if err="$(aws cloudwatch put-metric-alarm --region "$REGION" \
    --alarm-name "$alarm_name" \
    --namespace AWS/EC2 --metric-name StatusCheckFailed_System \
    --dimensions "Name=InstanceId,Value=$iid" \
    --statistic Maximum --period 60 --evaluation-periods 2 \
    --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
    --alarm-actions "arn:aws:automate:${REGION}:ec2:recover" \
    --alarm-description "Auto-recover source-truth index-service on system status-check failure" \
    2>&1 >/dev/null)"; then
    log info "auto-recovery alarm '$alarm_name' armed for $iid"
  else
    log warn "failed to create auto-recovery alarm (non-fatal — instance runs, but won't auto-heal on HW failure)"
    log warn "  → $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)"
  fi

  # Termination protection: prevent accidental termination via console / CLI.
  if err="$(aws ec2 modify-instance-attribute --region "$REGION" \
    --instance-id "$iid" --disable-api-termination 2>&1 >/dev/null)"; then
    log info "termination protection enabled for $iid"
  else
    log warn "failed to enable termination protection (non-fatal)"
    log warn "  → $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)"
  fi

  # IMDSv2 — enforce on EVERY run, not just at launch. run-instances defaults to
  # HttpTokens=optional, so a host provisioned before that flag was added still answers
  # unauthenticated IMDSv1 requests, and this script never replaces an instance: without a
  # reconcile here those hosts would stay on v1 forever. IMDSv1 is one unauthenticated GET away
  # from this instance's role credentials, and the same host runs an unauthenticated bridge.
  #
  # Do NOT pass --http-endpoint: an operator who disabled IMDS entirely is in the STRICTEST
  # state, and a hardening reconcile must never widen it back open.
  #
  # And do NOT trust the call's exit status as proof: this needs
  # ec2:ModifyInstanceMetadataOptions, which was missing from every policy in this repo, so the
  # call AccessDenied'd on every run in --local mode and the non-fatal warning made "attempted"
  # indistinguishable from "enforced". Read the value back.
  aws ec2 modify-instance-metadata-options --region "$REGION" \
    --instance-id "$iid" --http-tokens required --http-put-response-hop-limit 1 >/dev/null 2>&1 || true
  local tokens
  tokens="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text 2>/dev/null || echo "")"
  if [[ "$tokens" == "required" ]]; then
    log info "IMDSv2 enforced for $iid (verified)"
  else
    log warn "IMDSv2 NOT enforced for $iid — HttpTokens reads '${tokens:-unknown}', so the instance"
    log warn "  role is reachable over unauthenticated IMDSv1 from anything running on this host."
    log warn "  Most likely cause: the deploy identity lacks ec2:ModifyInstanceMetadataOptions."
  fi

  # Root-volume encryption cannot be changed in place, so a host launched before the Encrypted
  # flag existed keeps an unencrypted root disk permanently. Say so loudly rather than letting it
  # drift silently — the remediation is a snapshot-and-replace, an operator decision.
  local root_vol enc
  root_vol="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text 2>/dev/null || echo "")"
  if [[ -n "$root_vol" && "$root_vol" != "None" ]]; then
    enc="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$root_vol" \
      --query 'Volumes[0].Encrypted' --output text 2>/dev/null || echo "")"
    # Normalise the case: --output text renders a JSON boolean as "False" on some AWS CLI
    # versions and "false" on others. Comparing against one spelling made this warning a no-op
    # against the other — and this is the ONLY place the condition is ever reported, since root
    # encryption cannot be enabled in place.
    if [[ "${enc,,}" == "false" ]]; then
      log warn "root volume $root_vol of $iid is NOT encrypted — encryption cannot be enabled in place;"
      log warn "  remediate by snapshot → encrypted copy → replace, or enable EBS encryption by default account-wide"
    fi
  fi
}

# Where the HOST records the units it stopped for us, so a recovery run (below) can start exactly
# that list even if the remote shell was killed before its own trap fired. /run is tmpfs: a reboot
# clears it, and a reboot also brings the units back on its own (they are WantedBy=multi-user).
REBOOT_UNITS_FILE=/run/source-truth-rebootstrap-units

# Send an AWS-RunShellScript document to one instance; prints the CommandId on success.
# Captures the AWS error instead of discarding it (M11): with stderr dropped, an InvalidInstanceId
# (SSM agent unregistered / no NAT egress) is indistinguishable from an AccessDeniedException on
# ssm:SendCommand — which is the actual first-deploy-on-a-fresh-account failure.
ssm_send_shell() { # <instance-id> <script>
  local iid="$1" script="$2" param_file out
  # --parameters as a JSON FILE, one array element per LINE (the shape SSM expects; a single
  # element containing literal \n runs the lines glued together). Same helper the gateway /
  # project activation steps use.
  param_file="$(mktemp /tmp/idx-rebootstrap-ssm.XXXXXX)"  # X's at end (BSD/macOS-safe)
  printf '%s' "$script" | python3 -c 'import sys,json; print(json.dumps({"commands": sys.stdin.read().split("\n")}))' > "$param_file"
  if out="$(aws ssm send-command --region "$REGION" --instance-ids "$iid" \
      --document-name AWS-RunShellScript --parameters "file://$param_file" \
      --query Command.CommandId --output text 2>&1)"; then
    rm -f "$param_file"
    printf '%s' "$out"
    return 0
  fi
  rm -f "$param_file"
  log err "ssm send-command failed for $iid:"
  log err "  → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  log err "  (read the message above — it distinguishes an unregistered SSM agent / missing NAT"
  log err "   egress / an instance profile without ssm:* from an AccessDenied on the DEPLOY identity)"
  return 1
}

# Best-effort: ask the host to start whatever it recorded in $REBOOT_UNITS_FILE.
# The remote payload already restarts its own captured units from an EXIT trap, but a cancel that
# escalates to SIGKILL (or an SSM-agent restart) can kill the shell before the trap runs — which
# would leave EVERY gateway and bridge stopped. So every failure path also asks from here. Never
# fails the deploy any harder than it already has; `systemctl start` on a live unit is a no-op.
restart_captured_units() { # <instance-id>
  local iid="$1" cid st script deadline
  script="$(cat <<REMOTE
UNITS=$REBOOT_UNITS_FILE
if [ ! -s "\$UNITS" ]; then echo "recover: no captured unit list at \$UNITS — nothing to start"; exit 0; fi
while read -r u; do
  [ -n "\$u" ] || continue
  if systemctl start "\$u"; then echo "recover: started \$u"; else echo "recover: FAILED to start \$u" >&2; fi
done < "\$UNITS"
systemctl list-units --type=service --state=active,activating --plain --no-legend 'bot-gateway@*.service' 'index-bridge-*.service' 2>/dev/null || true
exit 0
REMOTE
)"
  log warn "attempting to restart the units the failed re-bootstrap had stopped on $iid ..."
  cid="$(ssm_send_shell "$iid" "$script")" || {
    log err "could not send the unit-restart recovery command to $iid — the host may have its"
    log err "  gateways/bridges STOPPED. Recover by hand: aws ssm start-session --target $iid ;"
    log err "  while read -r u; do systemctl start \"\$u\"; done < $REBOOT_UNITS_FILE"
    return 0
  }
  deadline=$(( SECONDS + 180 ))
  while (( SECONDS < deadline )); do
    sleep 5
    st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" \
      --query Status --output text 2>/dev/null || echo "")"
    case "$st" in
      Success) log ok "units restarted on $iid after the failed re-bootstrap"; return 0 ;;
      Failed|Cancelled|TimedOut)
        log err "unit-restart recovery $st on $iid — the host may still have services down;"
        log err "  inspect: aws ssm start-session --target $iid ; systemctl --failed"
        return 0 ;;
    esac
  done
  log warn "unit-restart recovery on $iid did not confirm within 180s — verify with: systemctl --failed"
  return 0
}

# Re-run bootstrap.sh ON AN EXISTING instance, over SSM: the base code (bridge / gateway / their
# deps) is brought up to date on the machine that is already serving, keeping its instance id,
# private IP, EBS volume and already-built graph.db. 原地重跑 bootstrap，机器不动。
#
# BREAK-BEFORE-MAKE, all inside ONE SSM run (C1). Order is capture → stop → bootstrap → start:
#   1. the host lists the ACTIVE bot-gateway@* / index-bridge-* units and records them;
#   2. it stops exactly those (bootstrap's `npm ci` deletes node_modules under them — a live
#      process then dies on its next lazy require() and Restart=always turns that into a crash
#      loop; and the Feishu long-connection is a global singleton per app, so the old process
#      must be positively dropped before a new one can hold it);
#   3. bootstrap.sh runs;
#   4. it starts exactly the captured list — never more (a project deliberately stopped stays
#      stopped) and never fewer (this is also what fixes --skip-projects leaving new code on
#      disk that no process had loaded).
# Steps 2-4 live in the remote payload ON PURPOSE rather than as three SSM round-trips: if the
# deploy machine loses the network between round-trips, a three-call version leaves the host with
# everything stopped and nobody to start it. Here the host's own EXIT trap restarts the units and
# rolls the env file back, and the deploy side additionally retries the restart from outside.
#
# HARD-FAILS instead of falling back to "reuse the stale box" — a deploy that re-staged code must
# apply it. The caller stamps ArtifactSig only after this returns 0, so a failed run leaves the tag
# stale and the next deploy retries.
rebootstrap_in_place() { # <instance-id>
  local iid="$1" cid st err out rc remote_cmd deadline timeout_secs

  # L16: an unvalidated override made `deadline=$(( ... ))` an arithmetic error that set -e turned
  # into an opaque abort. Fall back to the default instead — a bad knob must not kill the deploy.
  timeout_secs="${INDEX_REBOOTSTRAP_TIMEOUT_SECS:-1800}"
  if ! printf '%s' "$timeout_secs" | grep -Eq '^[1-9][0-9]*$'; then
    log warn "INDEX_REBOOTSTRAP_TIMEOUT_SECS='$timeout_secs' is not a positive integer — using 1800"
    timeout_secs=1800
  fi

  # Stage the CURRENT bootstrap.sh so the host pulls this run's copy (the fresh-launch path
  # does the same upload for its user-data). The instance already has the aws CLI + an
  # instance profile from its first bootstrap, so it can read S3 itself — no presign needed.
  aws s3 cp "$ROOT/index-service/bootstrap.sh" "s3://$BUCKET/bootstrap.sh" --region "$REGION" >&2

  # Remote payload. Written for /bin/sh (the SSM agent's shell): no arrays, no [[ ]], no ${x//}.
  # Deploy-side values interpolate here; every HOST-side expansion is escaped as \$.
  remote_cmd="$(cat <<REMOTE
set -e
UNITS=$REBOOT_UNITS_FILE
ENV_FILE=/etc/index-service.env
ENV_BAK=/etc/index-service.env.rebootstrap-bak

# H5: serialize. A deploy-side timeout used to abandon the SSM command while the remote bash kept
# running, so the NEXT deploy started a SECOND concurrent bootstrap on the same tree (two
# apt-get → dpkg lock, two tar xzf into /opt/bot-gateway, two npm ci in one node_modules).
# Deliberately NOT the lock file bootstrap.sh itself may take: this wrapper CALLS bootstrap.sh, so
# sharing one lock would deadlock against it. flock missing (non-Ubuntu base?) → proceed unlocked
# rather than refuse to deploy.
LOCK=/var/lock/source-truth-rebootstrap.lock
if command -v flock >/dev/null 2>&1; then
  exec 9>"\$LOCK"
  flock -n 9 || { echo "FATAL: another in-place re-bootstrap already holds \$LOCK on this host — refusing to run a second, concurrent bootstrap" >&2; exit 75; }
fi

# C1 step 1 — capture the units this run is about to break.
systemctl list-units --type=service --state=active,activating --plain --no-legend 'bot-gateway@*.service' 'index-bridge-*.service' 2>/dev/null | awk '{print \$1}' > "\$UNITS" || true
echo "re-bootstrap: active units to stop and restart: \$(tr '\n' ' ' < "\$UNITS")"

start_captured() {
  rc=0
  while read -r u; do
    [ -n "\$u" ] || continue
    if systemctl start "\$u"; then echo "re-bootstrap: restarted \$u"; else echo "re-bootstrap: FAILED to restart \$u" >&2; rc=1; fi
  done < "\$UNITS"
  return \$rc
}

on_failure() {
  echo "re-bootstrap: FAILED — rolling back \$ENV_FILE and restarting the units we stopped" >&2
  if [ -f "\$ENV_BAK" ]; then mv -f "\$ENV_BAK" "\$ENV_FILE" || true; fi
  start_captured || true
}
# Never leave the host fully down: any non-zero exit (bootstrap failure, or the SIGTERM an
# \`ssm cancel-command\` delivers) restarts what we stopped before propagating the failure.
trap 'rc=\$?; if [ \$rc -ne 0 ]; then on_failure; fi; exit \$rc' EXIT
trap 'echo "re-bootstrap: SIGTERM/SIGINT (deploy-side cancel?) — unwinding" >&2; exit 143' TERM INT

# C1 step 2 — stop them.
while read -r u; do
  [ -n "\$u" ] || continue
  echo "re-bootstrap: stopping \$u"
  systemctl stop "\$u" || echo "re-bootstrap: WARN 'systemctl stop \$u' returned non-zero" >&2
done < "\$UNITS"

# M12 — the env file must carry the NEW values for this run to mean anything (bootstrap.sh READS
# MAX_FILES / MODEL / GLOSSARY_MAX_FILES from it), so it is written BEFORE the run and rolled back
# by on_failure. Deferring the write instead would have run bootstrap against the OLD values; a
# backup+rollback keeps both properties — new values applied, no NEW-env-over-OLD-code residue.
cp -a "\$ENV_FILE" "\$ENV_BAK" 2>/dev/null || true
cat > "\$ENV_FILE" <<'ENV'
BUCKET='$BUCKET'
REGION='$REGION'
MAX_FILES='$MAX_FILES'
MODEL='$MODEL'
GLOSSARY_MAX_FILES='$GLOSSARY_MAX_FILES'
ENV

# C1 step 3 — the update itself.
aws s3 cp s3://${BUCKET}/bootstrap.sh /opt/bootstrap.sh --region ${REGION}
bash /opt/bootstrap.sh

# C1 step 4 — start exactly the captured list. Past this point the env is committed and the
# failure trap is disarmed: what remains is bringing the services back, and a unit that refuses to
# start must be a LOUD deploy failure (the tag stays stale, so the next deploy retries).
rm -f "\$ENV_BAK"
trap - EXIT
if start_captured; then
  echo "re-bootstrap: all captured units are back up"
else
  echo "FATAL: bootstrap succeeded but some captured units failed to restart (see above)" >&2
  exit 1
fi
REMOTE
)"

  cid="$(ssm_send_shell "$iid" "$remote_cmd")" || exit 1

  # Bootstrap installs apt/pip deps and rebuilds the gateway — minutes, not seconds. The gateways
  # and bridges are DOWN for that window by design (break-before-make); say so, because an
  # operator watching Feishu will notice.
  log warn "re-running bootstrap.sh in place on $iid — its bot-gateway@* / index-bridge-* units are"
  log warn "  STOPPED for the duration (break-before-make) and restarted at the end; bounded ${timeout_secs}s"
  deadline=$(( SECONDS + timeout_secs ))
  while (( SECONDS < deadline )); do
    sleep 10
    st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" \
      --query Status --output text 2>/dev/null || echo "")"
    case "$st" in
      Success) log ok "in-place re-bootstrap finished on $iid (units restarted)"; return 0 ;;
      Failed|Cancelled|TimedOut)
        err="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" \
          --query StandardErrorContent --output text 2>/dev/null || echo "")"
        out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" \
          --query StandardOutputContent --output text 2>/dev/null || echo "")"
        rc="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$iid" \
          --query ResponseCode --output text 2>/dev/null || echo "")"
        log err "in-place re-bootstrap $st on $iid — ${err:0:300}"
        printf '%s\n' "$out" | tail -20 >&2
        log err "  → inspect: aws ssm start-session --target $iid ; tail -100 /var/log/index-svc-bootstrap.log"
        if [[ "$rc" == "75" ]]; then
          # The payload refused the lock: ANOTHER re-bootstrap owns this host right now and will
          # restart those units itself when it finishes. Starting them from here would race it
          # (a gateway launched mid-`npm ci` just crash-loops), so leave them alone.
          log err "  another in-place re-bootstrap is already running on $iid — this deploy did NOT touch it;"
          log err "  wait for that run to finish, then re-run this deploy"
        else
          restart_captured_units "$iid"
        fi
        exit 1 ;;
    esac
  done
  # H5: CANCEL the abandoned command instead of walking away from it — otherwise the remote
  # bootstrap keeps running and the next deploy adds a second concurrent one on the same tree.
  log err "in-place re-bootstrap timed out on $iid after ${timeout_secs}s — cancelling the SSM command"
  aws ssm cancel-command --region "$REGION" --command-id "$cid" --instance-ids "$iid" >/dev/null 2>&1 \
    || log warn "  cancel-command failed (it may have just finished); the host lock still prevents a second run"
  # Give the remote shell a moment to take the SIGTERM and unwind its own trap, then make sure
  # from out here that the services are back up.
  sleep 10
  restart_captured_units "$iid"
  log err "  raise INDEX_REBOOTSTRAP_TIMEOUT_SECS if this host is simply slow (cold apt/npm cache)"
  exit 1
}

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
  arm_instance_resilience "$SELF_ID"
  log info "local mode: index host ready at $SELF_IP (instance $SELF_ID, dedicated sg $SG)"
  echo "$SELF_IP"; exit 0
fi

# Reuse a running index-service instance if present — ALWAYS reuse, never replace.
# A reused instance does NOT re-run bootstrap.sh by itself (that's EC2 user-data, which fires only
# on first boot), so on its own it would NOT pick up index-service / gateway code re-staged to S3
# this run. So:
#   - compute the current artifact signature and compare it to the tag we stamped on the instance
#     when it last bootstrapped;
#   - if they match → nothing to do, fast-path reuse (idempotent: no re-bootstrap,
#     签名一致就直接复用，不做任何多余动作);
#   - if they differ → re-run bootstrap.sh IN PLACE on that same instance over SSM (stopping and
#     restarting its gateways/bridges around the run), then re-stamp the tag. The instance id /
#     private IP / EBS volume / graph.db all survive, so index.source-truth.internal keeps
#     resolving to a host that exists throughout.
# Computed HERE rather than at the top of the script: local mode returns before this point and
# never uses the value, so an S3 hiccup (or a role that can list the bucket but not head an
# object) must not be able to fail a single-host deploy that does not depend on it.
# Abort on an unreadable bucket rather than guessing: this value decides whether we MUTATE a live
# host (C2).
CURRENT_SIG="$(artifact_signature)" || {
  log err "cannot determine the base-artifact signature — aborting before touching the live host"
  exit 1
}

# SINGLE-INSTANCE GUARD (detection here, enforcement at the launch block below) — keep exactly one
# index-service alive. The existing-instance filter below only matches running/pending, so a host
# in any other state is invisible to it and a fresh launch would run alongside it: two paid hosts,
# two graph.db copies, and INDEX_SERVICE_INSTANCE silently re-pointed at the new EMPTY one. This
# script never terminates or stops anything, so such a host can only come from an operator action.
#
# H4 — `stopped` and `stopping/shutting-down` are NOT the same case and must not share one wait:
#   stopping / shutting-down → genuinely on its way out; wait (bounded) for it to disappear.
#   stopped                  → it will NEVER terminate on its own, so `wait instance-terminated`
#                              burned its full 600s (15s × 40) and the swallowed timeout then fell
#                              through to a DUPLICATE launch. Termination protection is armed on
#                              our hosts, so it cannot be cleaned up automatically either. The
#                              resize advice further down (stop → modify-instance-attribute →
#                              start) actively produces this state, so it is a normal operator
#                              situation: refuse to LAUNCH and say exactly what to do. Starting it
#                              ourselves would silently undo a deliberate stop (cost saving,
#                              mid-resize, debugging), so we don't.
# Both checks gate the LAUNCH only: when a running host exists we update THAT one in place and
# never get here, so a leftover stopped box must not block an otherwise healthy deploy.
mapfile -t STOPPED_HOSTS < <(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^i-' || true)
if [[ ${#STOPPED_HOSTS[@]} -gt 0 ]]; then
  log warn "index-service host(s) ${STOPPED_HOSTS[*]} are STOPPED — they never terminate on their own and you keep paying for their EBS; this deploy will not launch a peer beside them"
fi
# DETERMINISTIC selection: if more than one index instance is somehow running (a hand-launched
# box, or a leftover from a much older deploy), a blind Reservations[0].Instances[0] could pick the
# WRONG (old-artifact) one. Prefer the instance whose ArtifactSig already matches CURRENT_SIG (no
# work to do); only if none match, fall back to any running/pending one — that one gets
# re-bootstrapped in place below.
EXISTING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=tag:ArtifactSig,Values=$CURRENT_SIG" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
if [[ "$EXISTING" == "None" || -z "$EXISTING" ]]; then
  EXISTING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
fi
if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  BOOTED_SIG="$(Q describe-instances --instance-ids "$EXISTING" --query "Reservations[0].Instances[0].Tags[?Key=='ArtifactSig'].Value | [0]" --output text 2>/dev/null)"
  [[ "$BOOTED_SIG" != "None" ]] || BOOTED_SIG=""
  # Compare (and later stamp) the EFFECTIVE signature: identical to CURRENT_SIG except that a
  # component absent from the bucket this run keeps whatever the host booted from, so a
  # backend-only deploy neither re-bootstraps for a missing gateway tarball nor writes a "none"
  # over a real ETag that every future deploy would then mismatch (C2).
  TARGET_SIG="$(effective_sig "$BOOTED_SIG")"
  if [[ "$BOOTED_SIG" != "$TARGET_SIG" ]]; then
    # The base code this host booted from is out of date: re-run bootstrap.sh on THIS host over
    # SSM (stopping its gateways/bridges first and starting them again after — see
    # rebootstrap_in_place) and re-stamp the tag. No terminate, no replacement launch, no DNS
    # cutover: the id/IP/EBS/graph.db are preserved.
    # 签名不一致 → 原地重跑 bootstrap 把 bridge/gateway 依赖更新到位，再写回新签名。
    log warn "index-service base artifacts changed since $EXISTING booted (sig: ${BOOTED_SIG:-none} → $TARGET_SIG) — updating IN PLACE on $EXISTING (no instance replacement)"
    rebootstrap_in_place "$EXISTING"
    # Stamp only AFTER a successful run (rebootstrap_in_place exits on failure), so a failed
    # update leaves the tag stale and the NEXT deploy retries instead of assuming the host is
    # current. create-tags overwrites the existing key → idempotent.
    Q create-tags --resources "$EXISTING" --tags "Key=ArtifactSig,Value=$TARGET_SIG" >/dev/null
    log info "recorded ArtifactSig=$TARGET_SIG on $EXISTING"
  else
    log info "index-service $EXISTING already on the current base artifacts (sig $TARGET_SIG) — skipping re-bootstrap"
  fi
  IP="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  if [[ -z "$IP" || "$IP" == "None" ]]; then
    log err "existing instance $EXISTING has no private IP yet"; exit 1
  fi
  # L17: pick the SG BY NAME, never SecurityGroups[0]. This value is persisted as
  # INDEX_SERVICE_SG and handed to the AgentCore runtime (deploy_project.sh), and it is also the
  # group whose 8080-8099 rule gets reconciled below. On a host with more than one SG attached
  # (hand-attached, or local mode's additive attach) the array order is not guaranteed, so
  # trusting [0] can put the runtime in a group with NO bridge ingress — invisible to every
  # downstream gate, because the bridge /health probe is loopback-only. Fail loud instead: our own
  # launch path always attaches this SG, so its absence is a real misconfiguration.
  SG="$(Q describe-instances --instance-ids "$EXISTING" \
    --query "Reservations[0].Instances[0].SecurityGroups[?GroupName=='source-truth-index-svc'].GroupId | [0]" \
    --output text 2>/dev/null || echo "")"
  if [[ -z "$SG" || "$SG" == "None" ]]; then
    log err "existing instance $EXISTING has no 'source-truth-index-svc' security group attached."
    log err "  That SG is what carries the bridge-port (8080-8099) ingress and what the AgentCore"
    log err "  runtime is launched into, so guessing another of its groups would silently leave the"
    log err "  runtime unable to reach the bridge. Attach it and re-run:"
    log err "    aws ec2 describe-security-groups --region $REGION --filters Name=group-name,Values=source-truth-index-svc"
    log err "    aws ec2 modify-instance-attribute --region $REGION --instance-id $EXISTING --groups <existing sg ids> <that sg id>"
    exit 1
  fi
  # If the operator asked for a DIFFERENT instance type than the existing instance
  # actually runs, we do NOT act on it: this script never replaces an instance, and
  # resizing needs a stop/modify/start (a deliberate, disruptive operator action).
  # WARN rather than silently pretending --instance-type took effect (cross-review).
  RUNNING_TYPE="$(Q describe-instances --instance-ids "$EXISTING" --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo "")"
  if [[ -n "$RUNNING_TYPE" && "$RUNNING_TYPE" != "None" && "$RUNNING_TYPE" != "$ITYPE" ]]; then
    log warn "existing instance $EXISTING runs $RUNNING_TYPE, not the requested $ITYPE — this script updates IN PLACE and never relaunches; resize it yourself (stop → modify-instance-attribute --instance-type → start) if you really want $ITYPE"
  fi
  # Repair the :8080 ingress on the existing instance's SG too — otherwise a
  # missing/dropped rule on a running instance would never be re-added (this
  # path exits before the fresh-instance reconcile below).
  reconcile_index_sg_ingress "$SG"
  # Persist the same state the new-instance path does, so deploy-all's health
  # gate runs and the runtime gets a valid SG (not skipped/unset).
  update_env "$CONFIG" INDEX_SERVICE_SG "$SG"
  update_env "$CONFIG" INDEX_SERVICE_INSTANCE "$EXISTING"
  # Arm resilience on the REUSED host as well, not just on a freshly launched one. A host
  # provisioned before these guards existed would otherwise never get auto-recovery or
  # termination protection no matter how many times it was redeployed — the same
  # unreachable-path bug the fresh-launch-only placement originally had. Idempotent.
  arm_instance_resilience "$EXISTING"
  log info "using existing index-service $EXISTING ($IP, sg=$SG)"
  echo "$IP"; exit 0
fi

# ── No live instance at all → FIRST-DEPLOY provisioning ──────────────────────────────
# describe-instances found nothing running/pending: a first deploy, or someone terminated the
# host. This is the only run-instances in the script.
# 到这里说明确实没有实例（首次部署或被人销毁），这才 launch 新机器。
#
# H4 enforcement — never launch a peer beside a host that is stopped or still on its way out.
if [[ ${#STOPPED_HOSTS[@]} -gt 0 ]]; then
  log err "index-service host(s) ${STOPPED_HOSTS[*]} are STOPPED and there is no running one. Refusing to"
  log err "  launch a replacement beside a stopped host: you would pay for two instances, the built"
  log err "  graph.db would stay on the stopped one, and this deploy would point at a fresh EMPTY box."
  log err "  → resume it:    aws ec2 start-instances --region $REGION --instance-ids ${STOPPED_HOSTS[0]}"
  log err "                  (then re-run this deploy — it updates that host in place)"
  log err "  → or retire it: aws ec2 modify-instance-attribute --region $REGION --instance-id ${STOPPED_HOSTS[0]} --no-disable-api-termination"
  log err "                  aws ec2 terminate-instances --region $REGION --instance-ids ${STOPPED_HOSTS[0]}"
  exit 1
fi
DRAINING="$(Q describe-instances --filters "Name=tag:Name,Values=source-truth-index-service" "Name=instance-state-name,Values=stopping,shutting-down" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
if [[ "$DRAINING" != "None" && -n "$DRAINING" ]]; then
  log warn "an index-service instance ($DRAINING) is still terminating (stopping/shutting-down); waiting for it to go away before launching, to avoid running two paid instances"
  Q wait instance-terminated --instance-ids "$DRAINING" 2>/dev/null || true
  # The waiter's timeout used to be swallowed, and control then fell through to a duplicate launch
  # (for a `stopped` instance it NEVER succeeds). Confirm the state instead: anything other than
  # `terminated` means we must not launch a peer.
  DRAIN_STATE="$(Q describe-instances --instance-ids "$DRAINING" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
  if [[ "$DRAIN_STATE" != "terminated" ]]; then
    log err "index-service $DRAINING is still '$DRAIN_STATE' after the terminate wait — refusing to launch"
    log err "  a second instance beside it. Resolve that host's state (it may have stopped rather than"
    log err "  terminated), then re-run."
    exit 1
  fi
fi
# index-service security group: bridge ports in from SG members.
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
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
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

# EC2 auto-recovery + termination protection for the instance just launched
# (local mode arms its own host earlier, before its early return).
arm_instance_resilience "$IID"

echo "$IP"
