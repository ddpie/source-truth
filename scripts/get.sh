#!/usr/bin/env bash
# get.sh — one-line bootstrap for source-truth.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)
#
# It clones this repo into ./source-truth (in the current directory) and hands off to the
# interactive installer (scripts/install.sh). The codegraph-server binary is NOT fetched here —
# deploy-all.sh downloads it from CODEGRAPH_SERVER_URL when it's neither local nor in S3, so the
# bootstrap stays small and there's a single source of truth for that logic.
#
# Re-runnable: if ./source-truth already exists it is reused (git pull to refresh), not re-cloned.
# Override the clone target with SOURCE_TRUTH_DIR, the repo with SOURCE_TRUTH_REPO, the branch
# with SOURCE_TRUTH_REF.
set -euo pipefail

SLUG="${SOURCE_TRUTH_SLUG:-ddpie/source-truth}"      # owner/repo, for `gh repo clone`
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
if [[ -d "$DIR/.git" ]]; then
  bold "• reusing existing checkout $DIR (git pull)"
  if ! git -C "$DIR" pull --ff-only origin "$REF"; then
    err "pull failed (local commits / dirty tree / detached HEAD?) — continuing with the EXISTING"
    err "  checkout, which may be STALE. Ctrl-C now if you need the latest; else it proceeds in 3s."
    sleep 3
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
