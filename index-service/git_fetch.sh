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

# Protect the codegraph state dirs from `git reset --hard`. The live graph.db / HOME live INSIDE
# the worktree (.codegraph/ and .home/ under $DEST). They're normally untracked, so reset leaves
# them alone — but if the upstream repo ever TRACKED a path named .codegraph/.home, `reset --hard`
# (run every refresh) would overwrite/destroy the live graph.db with no signal. Two guards:
#  1. mark them in .git/info/exclude so git always treats them as untracked (idempotent);
#  2. FAIL LOUD if upstream actually tracks such a path — that repo is unsupported here, and
#     silently clobbering its graph every 5 min would be far worse than a clear error.
guard_graph_dirs() {  # $1 = repo dir (must contain .git)
  local d="$1" exclude="$1/.git/info/exclude"
  if [ -f "$exclude" ] && ! grep -qxF "/.codegraph/" "$exclude" 2>/dev/null; then
    { echo "/.codegraph/"; echo "/.home/"; } >> "$exclude" 2>/dev/null || true
  fi
  # Check EACH path separately with plain ls-files (non-empty output = upstream tracks something
  # under it). NOT `--error-unmatch .codegraph .home` together: that returns non-zero if EITHER is
  # unmatched, so a repo tracking only .codegraph (but not .home) would be missed.
  if [ -n "$(git -C "$d" ls-files .codegraph .home 2>/dev/null)" ]; then
    fail "upstream repo tracks a .codegraph/.home path — unsupported (would clobber the live graph on reset)"
  fi
}

if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --quiet --prune origin || fail "fetch failed"
  guard_graph_dirs "$DEST"
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
  guard_graph_dirs "$DEST"
fi

HEAD_SHA="$(git -C "$DEST" rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "git_fetch ok: $SUBDIR @ $HEAD_SHA"
