#!/usr/bin/env bash
# test_artifact_signature.sh — the artifact-signature comparison in provision_index_service.sh.
#
# Why this is worth a test: since blue-green replacement was removed, a signature MISMATCH triggers
# an in-place re-bootstrap, which stops every bot-gateway@* and index-bridge-* on the host for
# minutes. So a wrong answer here is either an outage on every deploy, or a code change that
# silently never reaches the host. Both have already happened once:
#   * a transient S3 error collapsed a component to "none", which read as "changed" and then got
#     stamped, so every subsequent deploy re-bootstrapped forever;
#   * effective_sig had a fixed three-slot printf, so a fourth component added later was silently
#     dropped and the addition became a no-op.
#
# The functions are extracted rather than invoked through the script (which would need AWS), the
# same idiom test_provision_local_mode.sh uses.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/scripts/lib/provision_index_service.sh"

ran=0; failed=0
ok()   { ran=$((ran+1)); printf '  ok   %s\n' "$1"; }
bad()  { ran=$((ran+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — got [$2] want [$3]"; fi; }

# log() is a no-op here: the real one writes to stderr (deliberately, so it cannot pollute the
# captured signature on stdout). If that ever changes, the equality assertions below break loudly.
log() { :; }
eval "$(sed -n '/^_sig_component() {/,/^}$/p' "$SRC")"
eval "$(sed -n '/^effective_sig() {/,/^}$/p' "$SRC")"

echo "test_artifact_signature:"

# --- never DOWNGRADE a real component to "none" -------------------------------------------------
CURRENT_SIG="A|B|C|D"
check "all components fresh → passed through unchanged" "$(effective_sig 'W|X|Y|Z')" "A|B|C|D"

CURRENT_SIG="A|none|C|D"
check "absent gateway keeps the booted component" "$(effective_sig 'A|REAL|C|D')" "A|REAL|C|D"

CURRENT_SIG="A|B|C|none"
check "absent codegraph binary keeps the booted component" "$(effective_sig 'A|B|C|CGREAL')" "A|B|C|CGREAL"

CURRENT_SIG="none|none|none|none"
check "a total read failure never overwrites a healthy tag" "$(effective_sig 'A|B|C|D')" "A|B|C|D"

# --- component count must not be truncated ------------------------------------------------------
# This is the assertion that keeps adding a component from becoming a silent no-op.
CURRENT_SIG="A|B|C|D"
check "4th component survives (not truncated to 3)" "$(effective_sig 'A|B|C|OLD')" "A|B|C|D"
CURRENT_SIG="A|B|C|D|E"
check "a 5th component would survive too" "$(effective_sig 'A|B|C|D|OLD')" "A|B|C|D|E"

# --- first deploy -------------------------------------------------------------------------------
CURRENT_SIG="A|B|C|D"
check "no booted tag yet → current signature stands" "$(effective_sig '')" "A|B|C|D"

# --- the signature builder must include every channel that reaches a live host -------------------
# The host is never replaced, so a bootstrap run is the ONLY way these reach an existing box.
# Each of these was missing once, and each miss meant a change that silently never landed.
for key in 'index-service.tar.gz' 'bot-gateway.tar.gz' 'bootstrap.sh' 'bin/codegraph-server'; do
  if sed -n '/^artifact_signature() {/,/^}$/p' "$SRC" | grep -qF "$key"; then
    ok "signature covers $key"
  else
    bad "signature does NOT cover $key — a change to it would never reach an existing host"
  fi
done

# artifact_signature must FAIL, not emit a partial signature, when the index tarball is absent:
# the artifacts phase always stages it, so absent means wrong bucket or wrong order.
if sed -n '/^artifact_signature() {/,/^}$/p' "$SRC" | grep -q 'return 1'; then
  ok "artifact_signature fails rather than returning a partial signature"
else
  bad "artifact_signature has no failure path"
fi

echo "  ran=$ran failed=$failed"
[[ "$failed" -eq 0 ]]
