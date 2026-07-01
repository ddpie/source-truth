#!/usr/bin/env bash
# prepare-local-host.sh — bring a fresh EC2 up to the point where install.sh can run, for --local.
#
# launch-host.sh scp's this onto the instance and runs it (the repo is private, so it can't be
# curl'd from raw.githubusercontent). It installs the deps install.sh checks for (aws / docker / git),
# logs gh in with the token stashed in Secrets Manager (so a private clone works), clones the repo,
# and hands off to the interactive installer. Idempotent — safe to re-run.
#
#   bash /tmp/prepare-local-host.sh                 # region auto-detected from IMDS
#   REGION=us-east-1 bash /tmp/prepare-local-host.sh # or pass it explicitly
#
# Env: REGION (default: this instance's own region via IMDS) · REPO_URL (default the public HTTPS URL) · REPO_REF (git branch/tag/sha to
# check out, default main — launch-host passes YOUR current branch so the EC2 runs the SAME code as
# the launch-host/prepare scripts, not a mismatched main) · TOKEN_SECRET (default
# source-truth/deploy-github-token) · REPO_DIR (default source-truth).
set -euo pipefail

# REGION: default to THIS instance's own region from IMDS — we run on the EC2, so its region is
# knowable; making the operator type it is redundant and error-prone. Honor an explicit REGION if
# given (override / non-EC2 testing). Only used to read the token secret below.
REGION="${REGION:-}"
if [ -z "$REGION" ]; then
  _tok="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  REGION="$(curl -fsS ${_tok:+-H "X-aws-ec2-metadata-token: $_tok"} "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null || true)"
fi
[ -n "$REGION" ] || { echo "✗ could not detect region from IMDS — pass REGION=<r> explicitly." >&2; exit 2; }
REPO_URL="${REPO_URL:-https://github.com/ddpie/source-truth.git}"
REPO_REF="${REPO_REF:-main}"
TOKEN_SECRET="${TOKEN_SECRET:-source-truth/deploy-github-token}"
REPO_DIR="${REPO_DIR:-source-truth}"

step() { printf '\n▶ %s\n' "$*"; }
# apt-get wrapper: wait up to 5 min for the dpkg lock. A freshly-booted EC2 usually has
# unattended-upgrades / cloud-init holding it; a bare apt-get fails instantly on "Could not get lock".
apti() { sudo apt-get -o DPkg::Lock::Timeout=300 "$@"; }

# --- 1. AWS CLI v2 (needed to read the token from Secrets Manager, and by install/deploy) --------
# Refresh the apt index once up front — a fresh image may have a stale/empty one, and the bare
# `apt-get install` calls below (unzip / git) would otherwise fail with "Unable to locate package".
step "apt update"
apti update

step "AWS CLI"
if command -v aws >/dev/null; then
  echo "• already present: $(aws --version 2>&1)"
else
  command -v unzip >/dev/null || apti install -y unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  ( cd /tmp && unzip -oq awscliv2.zip && sudo ./aws/install --update )
  rm -rf /tmp/aws /tmp/awscliv2.zip
  echo "• installed: $(aws --version 2>&1)"
fi

# --- 2. git (clone needs it; fresh minimal images may lack it) ----------------------------------
step "git"
command -v git >/dev/null && echo "• already present" || apti install -y git

# --- 2b. boto3/botocore recent enough for AgentCore ---------------------------------------------
# deploy-all Phase 5 drives AgentCore via boto3 (lib/deploy_runtime.py); an old apt/pip botocore
# lacks the 'bedrock-agentcore-control' service and deploy-all's preflight HARD-fails. Ubuntu 24.04
# is PEP-668 externally-managed, so --break-system-packages (same as bootstrap.sh's pip install).
step "boto3/botocore (for AgentCore)"
command -v pip3 >/dev/null || apti install -y python3-pip
if python3 -c 'import boto3,sys; sys.exit(0 if "bedrock-agentcore-control" in boto3.Session().get_available_services() else 1)' 2>/dev/null; then
  echo "• already recent enough"
else
  sudo pip3 install --break-system-packages -q -U boto3 botocore
  echo "• upgraded boto3/botocore"
fi

# --- 3. docker + buildx (install.sh's Phase 4 builds the ARM64 image locally) -------------------
step "docker"
if command -v docker >/dev/null; then
  echo "• already present"
else
  apti update && apti install -y docker.io docker-buildx
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
    apti update && apti install -y gh
  fi
  gh auth login --with-token <<<"$T"       # here-string, not argv — token never hits the process list
  gh auth setup-git
  echo "• gh logged in; git configured to use it"
else
  echo "• no token in $TOKEN_SECRET — treating the repo as public (plain clone)"
fi

# --- 5. clone or update the repo, on the requested ref ------------------------------------------
# Check out REPO_REF (the branch launch-host is on) so the EC2 runs the SAME code as the scripts
# that got us here — not a stale main. On an existing checkout, fetch + hard-checkout the ref.
step "repo ($REPO_REF)"
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch origin "$REPO_REF"
  git -C "$REPO_DIR" checkout "$REPO_REF"
  git -C "$REPO_DIR" pull --ff-only origin "$REPO_REF"
else
  git clone "$REPO_URL" "$REPO_DIR"
  git -C "$REPO_DIR" checkout "$REPO_REF"
fi

# --- 6. hand off to the installer in --local mode, inside the docker group -----------------------
# --local tells install.sh (and the deploy-all it calls) to deploy onto THIS EC2 and reuse its
# VPC/role, instead of creating a separate index host. sg docker -c makes the freshly-added docker
# group live in this same session (usermod alone would need a new login).
step "installer (--local)"
cd "$REPO_DIR"
exec sg docker -c './scripts/install.sh --local'
