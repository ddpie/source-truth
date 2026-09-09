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

# SERIALIZE PER REPO. Two callers touch the same worktree: activate_project.sh runs this directly,
# and index-refresh-<subdir>.timer runs it via glossary_refresh.sh — the timer can fire DURING an
# activation. Concurrent `git fetch` / `reset --hard` on one worktree collide on .git/index.lock and
# can leave a partially-reset tree that the codegraph watcher then indexes. The lock lives NEXT to
# the repo (not inside it) so it also covers the clone case, where $DEST does not exist yet.
# Blocking with a bound, not `-n`: an overlapping refresh should WAIT for the activation, not fail
# the timer. 900s is longer than any clone/fetch we expect; hitting it means something is wedged and
# a loud failure is correct.
mkdir -p "$(dirname "$DEST")" || fail "mkdir parent of dest failed"
FETCH_LOCK="$(dirname "$DEST")/.$(basename "$DEST").git-fetch.lock"
exec 8>"$FETCH_LOCK" || fail "cannot open fetch lock $FETCH_LOCK"
flock -w 900 8 || fail "timed out waiting for the per-repo git lock ($FETCH_LOCK) — another fetch/clone is stuck"

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

# Record the HEAD BEFORE the reset so the caller can diff old..new and rebuild only the
# changed files (the glossary's incremental path). Empty on a fresh clone → caller does a
# full build. Full sha (not --short) so `git diff old..new` is unambiguous.
OLD_SHA=""
# A dest that EXISTS but is NOT a git repo used to fall through to `git clone <url> "$DEST"`, which
# refuses a non-empty destination — failing every 300s forever with "clone failed". That happens on
# a source:local → source:git flip and after a half-failed clone. Converge in place instead:
# init + remote add, then the normal fetch/reset path below. In place, NOT moved aside: the live
# graph (.codegraph/ and .home/, including graph.db) lives INSIDE $DEST and the project's bridge has
# it open read-write — moving the directory would pull the store out from under the writer. `reset
# --hard` only touches tracked paths, so the graph dirs survive (and guard_graph_dirs re-excludes
# them right after).
if [ -d "$DEST" ] && [ ! -d "$DEST/.git" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "git_fetch: $SUBDIR — $DEST exists but is not a git repo; initializing it in place (keeps the live graph dirs)"
  git -C "$DEST" init --quiet || fail "git init on existing non-repo dest failed"
  git -C "$DEST" remote add origin "$URL" 2>/dev/null \
    || git -C "$DEST" remote set-url origin "$URL" \
    || fail "could not set origin on initialized dest"
fi
if [ -d "$DEST/.git" ]; then
  # --verify --quiet: on an UNBORN HEAD (a dir we just `git init`ed above, or a half-failed clone)
  # a plain `rev-parse HEAD` prints the literal string "HEAD" on stdout and exits non-zero, so the
  # `|| echo ''` fallback never runs and OLD_SHA becomes "HEAD" — which the caller would then feed
  # to `git diff HEAD..<sha>` instead of treating it as "no previous state → full build".
  OLD_SHA="$(git -C "$DEST" rev-parse --verify --quiet HEAD 2>/dev/null || echo '')"
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
  # `reset --hard` only rewrites TRACKED paths, so files that were untracked in a previous state
  # (or left by a killed clone) stayed in the worktree forever and codegraph kept indexing them —
  # the graph then answers with code that is no longer in the repo. Remove them.
  # NO -x, and an explicit -e for each graph dir: the live graph (.codegraph/, .home/ with graph.db
  # and .build-ok) is IGNORED via .git/info/exclude, and `clean -fd` without -x never touches
  # ignored paths — the -e flags are the belt to that suspenders. .snapshot-time is ops state written
  # by reindex_local_repo.sh. Non-fatal: a failed cleanup must not fail an otherwise good refresh.
  git -C "$DEST" clean -fdq \
      -e '/.codegraph/' -e '/.home/' -e '/.snapshot-time' \
    || echo "git_fetch: WARN $SUBDIR — git clean reported an error (stale untracked files may remain)" >&2
else
  mkdir -p "$(dirname "$DEST")" || fail "mkdir parent of dest failed"
  if [ -n "$REF" ]; then
    # FULL clone at the branch (the old comment said "shallow-ish" — it never was: there is no
    # --depth / --filter here, so this pulls COMPLETE history). Kept full ON PURPOSE: the
    # incremental glossary path diffs OLD_SHA..NEW_SHA on every refresh, and a shallow or
    # blobless clone can lose OLD_SHA (or need a network round trip per blob), which silently
    # degrades every refresh into a full rebuild. COST, unbudgeted and worth watching: full
    # history for N repos shares one 30GiB root volume with every graph.db. If disk becomes the
    # binding constraint, the change is `--filter=blob:none` + sparse checkout AND a matching
    # change to the diff path — not a bare --depth 1.
    # If --branch doesn't match a branch (e.g. a tag or sha), fall back to a plain clone then
    # checkout the ref.
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

HEAD_SHA="$(git -C "$DEST" rev-parse --verify --quiet --short HEAD 2>/dev/null || echo '?')"
echo "git_fetch ok: $SUBDIR @ $HEAD_SHA"
# Machine-parseable line for the refresh unit: old (pre-reset) + new (post-reset) full shas.
# OLD empty => fresh clone => caller should do a FULL glossary build; OLD==NEW => no-op.
NEW_SHA="$(git -C "$DEST" rev-parse --verify --quiet HEAD 2>/dev/null || echo '')"
echo "git_fetch_shas: $SUBDIR OLD=$OLD_SHA NEW=$NEW_SHA"
