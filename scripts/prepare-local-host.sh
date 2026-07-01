#!/usr/bin/env bash
# prepare-local-host.sh — bring a fresh EC2 up to the point where install.sh can run, for --local.
#
# launch-host.sh scp's this onto the instance and runs it (the repo is private, so it can't be
# curl'd from raw.githubusercontent). It installs the deps install.sh checks for (aws / docker / git),
# logs gh in with the token stashed in Secrets Manager (so a private clone works), clones the repo,
# and hands off to the interactive installer. Idempotent — safe to re-run.
#
#   REGION=us-east-1 bash /tmp/prepare-local-host.sh
#
# Env: REGION (required) · REPO_URL (default the public HTTPS URL) · TOKEN_SECRET (default
# source-truth/deploy-github-token) · REPO_DIR (default source-truth).
set -euo pipefail

REGION="${REGION:-}"
[ -n "$REGION" ] || { echo "✗ REGION is required (e.g. REGION=us-east-1 bash $0)" >&2; exit 2; }
REPO_URL="${REPO_URL:-https://github.com/ddpie/source-truth.git}"
TOKEN_SECRET="${TOKEN_SECRET:-source-truth/deploy-github-token}"
REPO_DIR="${REPO_DIR:-source-truth}"

step() { printf '\n▶ %s\n' "$*"; }

# --- 1. AWS CLI v2 (needed to read the token from Secrets Manager, and by install/deploy) --------
# Refresh the apt index once up front — a fresh image may have a stale/empty one, and the bare
# `apt-get install` calls below (unzip / git) would otherwise fail with "Unable to locate package".
step "apt update"
sudo apt-get update

step "AWS CLI"
if command -v aws >/dev/null; then
  echo "• already present: $(aws --version 2>&1)"
else
  command -v unzip >/dev/null || sudo apt-get install -y unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  ( cd /tmp && unzip -oq awscliv2.zip && sudo ./aws/install --update )
  rm -rf /tmp/aws /tmp/awscliv2.zip
  echo "• installed: $(aws --version 2>&1)"
fi

# --- 2. git (clone needs it; fresh minimal images may lack it) ----------------------------------
step "git"
command -v git >/dev/null && echo "• already present" || sudo apt-get install -y git

# --- 3. docker + buildx (install.sh's Phase 4 builds the ARM64 image locally) -------------------
step "docker"
if command -v docker >/dev/null; then
  echo "• already present"
else
  sudo apt-get update && sudo apt-get install -y docker.io docker-buildx
fi
sudo systemctl enable --now docker
# Let this user drive docker without sudo. The new group only applies to NEW logins, so we run
# install.sh below inside `sg docker` rather than expecting it live in this same session.
sudo usermod -aG docker "$USER"

# --- 4. gh + login (so the private clone + gh release download carry credentials) ---------------
step "GitHub credentials"
T="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$TOKEN_SECRET" --query SecretString --output text 2>/dev/null || true)"
if [ -n "$T" ]; then
  if ! command -v gh >/dev/null; then
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update && sudo apt-get install -y gh
  fi
  gh auth login --with-token <<<"$T"       # here-string, not argv — token never hits the process list
  gh auth setup-git
  echo "• gh logged in; git configured to use it"
else
  echo "• no token in $TOKEN_SECRET — treating the repo as public (plain clone)"
fi

# --- 5. clone or update the repo ----------------------------------------------------------------
step "repo"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$REPO_DIR"
fi

# --- 6. hand off to the installer, inside the docker group (usermod above needs a new login else) -
step "installer"
cd "$REPO_DIR"
exec sg docker -c './scripts/install.sh'
