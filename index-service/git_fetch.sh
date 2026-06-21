#!/usr/bin/env bash
# git_fetch.sh <subdir> <git_url> <ref> <dest_dir>
#
# Idempotent per-repo code fetch for the index host (multi-project + git refresh):
#   - dest absent  → git clone (at <ref> if given, else the remote's default branch)
#   - dest present → git fetch + hard-reset the working tree to <ref> (or origin's default)
#
# In-place working-tree update — the spec accepts the brief mid-pull transient state, because
# codegraph-server's resident --mcp process has its own file-watcher that re-indexes
# incrementally a few seconds after files settle. We deliberately do NOT do a .new+rename
# atomic swap (spec §5.4 / §8.1). The timer that calls this NEVER spawns a second codegraph
# process, so the "one writer per graph.db" invariant is untouched.
#
# On ANY failure prints a greppable `GIT_FETCH_FAILED: <subdir> <reason>` line to stderr and
# exits non-zero — refresh must alarm, never silently serve stale code (spec §5.4 / design §8.4).
#
# Credentials: a read-only token is provided host-side via GIT_ASKPASS (set by bootstrap from
# Secrets Manager) for https remotes; ssh remotes use the host's key. This script reads no secret.
set -uo pipefail

SUBDIR="${1:-}"; URL="${2:-}"; REF="${3:-}"; DEST="${4:-}"
if [ -z "$SUBDIR" ] || [ -z "$URL" ] || [ -z "$DEST" ]; then
  echo "GIT_FETCH_FAILED: ${SUBDIR:-?} usage: git_fetch.sh <subdir> <git_url> <ref> <dest_dir>" >&2
  exit 2
fi
fail() { echo "GIT_FETCH_FAILED: $SUBDIR $*" >&2; exit 1; }

# Non-interactive: never block on a credential/host-key prompt (would hang the timer).
export GIT_TERMINAL_PROMPT=0

if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --quiet --prune origin || fail "fetch failed"
  if [ -n "$REF" ]; then
    # Prefer the remote-tracking ref (branch); fall back to a tag/sha of the same name.
    git -C "$DEST" reset --hard --quiet "origin/$REF" 2>/dev/null \
      || git -C "$DEST" reset --hard --quiet "$REF" \
      || fail "reset to ref '$REF' failed"
  else
    # No ref pinned → reset to the remote's default branch HEAD.
    DEF="$(git -C "$DEST" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
    [ -n "$DEF" ] || DEF="$(git -C "$DEST" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    [ -n "$DEF" ] || fail "cannot determine origin default branch"
    git -C "$DEST" reset --hard --quiet "origin/$DEF" || fail "reset to default branch '$DEF' failed"
  fi
else
  mkdir -p "$(dirname "$DEST")" || fail "mkdir parent of dest failed"
  if [ -n "$REF" ]; then
    # Try a shallow-ish clone at the branch; if --branch doesn't match a branch (e.g. a tag or
    # sha), fall back to a plain clone then checkout the ref.
    if git clone --quiet --branch "$REF" "$URL" "$DEST" 2>/dev/null; then
      :
    else
      git clone --quiet "$URL" "$DEST" || fail "clone failed"
      git -C "$DEST" checkout --quiet "$REF" || fail "checkout ref '$REF' after clone failed"
    fi
  else
    git clone --quiet "$URL" "$DEST" || fail "clone failed"
  fi
fi

HEAD_SHA="$(git -C "$DEST" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "git_fetch ok: $SUBDIR @ $HEAD_SHA"
