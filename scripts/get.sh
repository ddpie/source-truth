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

REPO="${SOURCE_TRUTH_REPO:-https://github.com/ddpie/source-truth.git}"
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

# Clone (or refresh an existing checkout). Shallow clone keeps the one-liner fast; the
# installer never needs history.
if [[ -d "$DIR/.git" ]]; then
  bold "• reusing existing checkout $DIR (git pull)"
  git -C "$DIR" pull --ff-only origin "$REF" || err "pull failed — using the existing checkout as-is"
elif [[ -e "$DIR" ]]; then
  err "$DIR exists but is not a git checkout — move it aside or set SOURCE_TRUTH_DIR, then re-run."
  exit 1
else
  bold "• cloning $REPO ($REF) → $DIR"
  git clone --depth 1 --branch "$REF" "$REPO" "$DIR"
fi

# Hand off to the interactive installer. exec so signals (Ctrl-C) go straight to it and
# its exit code is ours.
bold "• launching installer"
cd "$DIR"
exec bash scripts/install.sh "$@"
