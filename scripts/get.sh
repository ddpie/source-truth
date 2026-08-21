#!/usr/bin/env bash
# get.sh — one-line bootstrap for source-truth.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/aws-samples/sample-code-qa-on-agentcore/main/scripts/get.sh)
#
# It clones this repo into ./source-truth (in the current directory) and hands off to the
# interactive installer (scripts/install.sh). The codegraph-server binary is NOT fetched here —
# deploy-all.sh downloads it from CODEGRAPH_SERVER_URL when it's neither local nor in S3, so the
# bootstrap stays small and there's a single source of truth for that logic.
#
# Re-runnable: if ./source-truth already exists it is reused (fetched + fast-forwarded to the target
# ref), not re-cloned. Override the clone target with SOURCE_TRUTH_DIR, the repo with
# SOURCE_TRUTH_REPO, the branch with SOURCE_TRUTH_REF. SOURCE_TRUTH_ALLOW_STALE=1 downgrades a failed
# refresh from an error to a warning (install from the tree exactly as it is).
set -euo pipefail

SLUG="${SOURCE_TRUTH_SLUG:-aws-samples/sample-code-qa-on-agentcore}"      # owner/repo, for `gh repo clone`
REPO="${SOURCE_TRUTH_REPO:-https://github.com/$SLUG.git}"
REF="${SOURCE_TRUTH_REF:-main}"
DIR="${SOURCE_TRUTH_DIR:-source-truth}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }

bold "▶ source-truth bootstrap"

# Hard dep: git (the only thing this script itself needs; install.sh checks the rest —
# aws/python3/docker — and fails with its own actionable message).
if ! command -v git >/dev/null 2>&1; then
  err "git not found — install git and re-run."
  exit 1
fi

# Clone helper. Prefer `gh repo clone` when gh is installed + authenticated: it carries the
# operator's token, so a PRIVATE repo clones without an interactive password prompt. Fall back
# to plain `git clone` (works for a public repo, or when the user has git credentials cached).
# Full clone (not shallow): this checkout is long-lived — upgrades pull into it with `git pull`,
# and a shallow history can trip that up. The one-time clone cost is negligible for a host we keep.
do_clone() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    bold "• cloning $SLUG ($REF) via gh → $DIR"
    gh repo clone "$SLUG" "$DIR" -- --branch "$REF"
  else
    bold "• cloning $REPO ($REF) → $DIR"
    git clone --branch "$REF" "$REPO" "$DIR"
  fi
}

# Refresh an existing checkout, else clone fresh.
#
# fetch → checkout → merge --ff-only, NOT `git pull --ff-only origin "$REF"`. A bare pull
# fast-forwards whatever is currently checked out: on a checkout parked on another branch it merged
# origin/main INTO that branch, silently rewriting the operator's working branch and then installing
# from a tree that is neither. Checking $REF out first makes the target explicit.
#
# A refresh failure is an ERROR by default. The old code warned, slept 3s "Ctrl-C now if you need the
# latest" and continued from a possibly stale tree — but the documented entry point is
# `bash <(curl …)`, which has no tty to interrupt, so the prompt was unreachable and a stale deploy
# went ahead unnoticed. Set SOURCE_TRUTH_ALLOW_STALE=1 to deliberately install from the tree as-is
# (offline / air-gapped / deliberately pinned local commits).
if [[ -d "$DIR/.git" ]]; then
  bold "• reusing existing checkout $DIR (fetch + ff-only merge of $REF)"
  refresh_ok=1
  git -C "$DIR" fetch --tags origin "$REF" || refresh_ok=0
  if [[ "$refresh_ok" == 1 ]]; then
    git -C "$DIR" checkout "$REF" || refresh_ok=0
  fi
  if [[ "$refresh_ok" == 1 ]]; then
    # A tag or a raw sha has no origin/<ref> to merge — the checkout above IS the refresh there.
    if git -C "$DIR" rev-parse --verify --quiet "refs/remotes/origin/$REF" >/dev/null; then
      git -C "$DIR" merge --ff-only "origin/$REF" || refresh_ok=0
    fi
  fi
  if [[ "$refresh_ok" != 1 ]]; then
    if [[ "${SOURCE_TRUTH_ALLOW_STALE:-}" == 1 ]]; then
      err "could not refresh $DIR to $REF — SOURCE_TRUTH_ALLOW_STALE=1, continuing with the"
      err "  EXISTING (possibly STALE) tree: $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    else
      err "could not refresh $DIR to $REF (local commits / dirty tree / detached HEAD / no network?)."
      err "  Fix the checkout — e.g.  git -C $DIR status  then  git -C $DIR stash  — and re-run."
      err "  To install from the tree exactly as it is, re-run with SOURCE_TRUTH_ALLOW_STALE=1."
      exit 1
    fi
  fi
elif [[ -e "$DIR" ]]; then
  err "$DIR exists but is not a git checkout — move it aside or set SOURCE_TRUTH_DIR, then re-run."
  exit 1
else
  do_clone
fi

# Hand off to the interactive installer. exec so signals (Ctrl-C) go straight to it and
# its exit code is ours.
bold "• launching installer"
cd "$DIR"
exec bash scripts/install.sh "$@"
