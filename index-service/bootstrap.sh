#!/usr/bin/env bash
# bootstrap.sh — index-service host bootstrap (runs as EC2 user-data).
#
# Codifies the reliability lessons from POC bring-up into one idempotent script:
#   - Ubuntu 24.04 ARM base (glibc 2.39 — codegraph-server needs >= 2.38;
#     Amazon Linux 2023's glibc 2.34 is too old, verified failing).
#   - codegraph-server + bridge code pulled from S3 (artifacts staged by deploy).
#   - SINGLE-WRITER discipline: exactly one codegraph process ever touches
#     graph.db. The BUILD phase (oneshot) holds an flock while it creates the
#     graph. The SERVE phase (the bridge's resident --mcp session) does NOT hold
#     the flock — its single-writer guarantee rests on (a) systemd ordering
#     (index-bridge After=/Requires= index-build, so build has fully exited before
#     serve starts), (b) `Conflicts=` so systemd refuses to run a second build
#     oneshot while the bridge is live (closes the `systemctl restart index-build`
#     footgun), and (c) the bridge's in-process restart join-guard. Concurrent
#     writers corrupt RocksDB → 0-node graph (the #1 failure we hit). graph.db
#     lives on LOCAL disk, so this is per-instance — the deploy provisions exactly
#     ONE index-service instance (provision_index_service.sh reuses an existing
#     one). Running a second instance against the same EFS is unsupported in the
#     MVP (would need an EFS-resident or DynamoDB lock for HA).
#   - PATH baked into the unit (codegraph-server lives in /usr/local/bin; systemd
#     has no login PATH — a bare "codegraph-server" spawn fails otherwise).
#
# Inputs via environment (deploy-all.sh writes /etc/index-service.env first):
#   BUCKET, REGION, EFS_ID, REPO_SUBDIR (e.g. code-5x), MAX_FILES
set -euxo pipefail
exec > /var/log/index-svc-bootstrap.log 2>&1

# shellcheck disable=SC1091
source /etc/index-service.env

export DEBIAN_FRONTEND=noninteractive
INDEX_HOME=/data                       # codegraph graph.db lives here (LOCAL disk, never EFS)
APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
# We mount the EFS *filesystem root* at /mnt/efs; the repo tree lives under the
# access-point root /repo, i.e. /mnt/efs/repo/<subdir>. The runtime mounts the
# /repo access point at /mnt/repo, so its matching path is /mnt/repo/<subdir>
# (that's the --mount-root passed to the bridge below).
EFS_MNT=/mnt/efs
REPO_ROOT="$EFS_MNT/repo"
WORKSPACE="$REPO_ROOT/$REPO_SUBDIR"
LOCK=/data/.codegraph/.writer.lock

mkdir -p "$INDEX_HOME/.codegraph" /opt/idx/bin "$APP" "$EFS_MNT"

# --- base packages (retry: apt mirrors can flap on fresh hosts) ---
for i in 1 2 3; do apt-get update -y && break || sleep 10; done
apt-get install -y nfs-common python3-pip python3-venv unzip curl
# awscli v2 (Ubuntu 24.04 has no apt awscli)
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q -o awscliv2.zip && ./aws/install --update)
fi
export PATH=/usr/local/bin:$PATH

# --- artifacts from S3 ---
aws s3 cp "s3://$BUCKET/bin/codegraph-server" "$BIN" --region "$REGION"
chmod +x "$BIN"
ln -sf "$BIN" /usr/local/bin/codegraph-server
aws s3 cp "s3://$BUCKET/index-service.tar.gz" /tmp/idx.tar.gz --region "$REGION"
tar xzf /tmp/idx.tar.gz -C "$APP"
# Install from the shipped requirements.txt — the SINGLE source of truth for
# deps — not a hand-typed list (which had drifted: it installed the unrelated
# standalone `fastmcp`, never imported, while the bridge uses the FastMCP class
# bundled in `mcp`). `mcp` pulls starlette/sse-starlette transitively.
pip3 install --break-system-packages -q --ignore-installed -r "$APP/requirements.txt"

# --- mount EFS (access-point root) read-write so the build can land the repo ---
# CRITICAL: the mount MUST succeed. If it silently failed we'd extract + index
# the repo onto the local root disk instead of EFS; the runtime (which mounts
# the same EFS at /mnt/repo) would then see nothing → 0-node graph → garbage.
# So: retry the initial mount (EFS targets accept connections a few seconds
# after reaching 'available'), then HARD-FAIL the bootstrap if it isn't mounted.
EFS_DNS="${EFS_ID}.efs.${REGION}.amazonaws.com"
grep -q "$EFS_MNT" /etc/fstab || \
  echo "${EFS_DNS}:/ $EFS_MNT nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab
if ! mountpoint -q "$EFS_MNT"; then
  for attempt in $(seq 1 10); do
    mount "$EFS_MNT" && break
    echo "EFS mount attempt $attempt failed; retrying in 6s ..."
    sleep 6
  done
fi
if ! mountpoint -q "$EFS_MNT"; then
  echo "BOOTSTRAP_FAILED: EFS ($EFS_DNS) not mounted at $EFS_MNT after retries"
  exit 1
fi

# --- ensure the repo is on EFS (deploy stages <repo>.tar.gz in S3) ---
# Extract under the access-point root /repo so the path matches what the runtime
# sees at /mnt/repo/<subdir>.
mkdir -p "$REPO_ROOT"
if [ ! -d "$WORKSPACE" ]; then
  aws s3 cp "s3://$BUCKET/${REPO_SUBDIR}.tar.gz" /tmp/repo.tar.gz --region "$REGION"
  tar xzf /tmp/repo.tar.gz -C "$REPO_ROOT"
fi

# --- ALSO extract the repo to LOCAL disk for fast file search ---------------
# Grep over the EFS/NFS copy is catastrophically slow: a single whole-repo grep
# measured 47s on NFS vs 0.21s on local disk (225x — NFS pays a network round-
# trip per file open for 18k files). The agent's builtin Grep hits /mnt/repo
# (EFS) and dominated end-to-end latency (~20s per broad grep). So we keep a
# LOCAL-disk copy here and expose a fast search tool (http_bridge codegraph_
# search_files) that greps it. It is the SAME deploy-time tarball snapshot as the
# EFS copy — NOT a live mirror of main — so it is exactly as fresh as EFS, just
# fast. Extracting from the already-local /tmp/repo.tar.gz costs no NFS I/O.
LOCAL_REPO_ROOT=/data/repo
LOCAL_WORKSPACE="$LOCAL_REPO_ROOT/$REPO_SUBDIR"
mkdir -p "$LOCAL_REPO_ROOT"
if [ ! -d "$LOCAL_WORKSPACE" ]; then
  if [ ! -f /tmp/repo.tar.gz ]; then
    aws s3 cp "s3://$BUCKET/${REPO_SUBDIR}.tar.gz" /tmp/repo.tar.gz --region "$REGION"
  fi
  tar xzf /tmp/repo.tar.gz -C "$LOCAL_REPO_ROOT"
fi
# Install ripgrep for fast, .gitignore-aware search (apt has it on Ubuntu 24.04).
command -v rg >/dev/null || apt-get install -y ripgrep || true

# --- systemd units: build (oneshot, sole writer) THEN serve (resident reader) ---
cat > /etc/systemd/system/index-build.service <<UNIT
[Unit]
Description=CodeGraph index build (single-writer, runs to completion before serve)
After=network-online.target remote-fs.target
Wants=network-online.target
# Hard requirement on the EFS mount (not just After= ordering): on a REBOOT the
# user-data bootstrap does NOT re-run, so its mount hard-fail guard is absent.
# RequiresMountsFor makes systemd fail this unit if /mnt/efs isn't mounted,
# rather than indexing an empty local dir into a 0-node graph.
RequiresMountsFor=$EFS_MNT
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# Belt-and-suspenders: refuse to build unless EFS is actually mounted AND the
# workspace exists — so a late/failed mount fails loudly instead of building
# garbage (Requires=index-build then keeps the bridge from serving it).
ExecStartPre=/usr/bin/mountpoint -q $EFS_MNT
ExecStartPre=/usr/bin/test -d $WORKSPACE
# flock guarantees only ONE codegraph process writes graph.db at a time.
ExecStart=/usr/bin/flock $LOCK $BIN --graph-only --workspace $WORKSPACE \\
  --exclude node_modules --exclude .venv --exclude .git --max-files $MAX_FILES \\
  --run-tool codegraph_symbol_search --tool-args '{"query":"__build__"}'
UNIT

cat > /etc/systemd/system/index-bridge.service <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge (resident single session)
After=index-build.service
Requires=index-build.service
# Also bind the bridge to the EFS mount: if /mnt/efs drops, don't keep serving
# (or restart-loop) against a vanished workspace.
RequiresMountsFor=$EFS_MNT
[Service]
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=$MAX_FILES
WorkingDirectory=$APP
ExecStart=/usr/bin/python3 -m http_bridge --workspace $WORKSPACE --host 0.0.0.0 --port 8080 --mount-root /mnt/repo/$REPO_SUBDIR --local-workspace $LOCAL_WORKSPACE
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
# Build first (sole writer). enable --now blocks until the oneshot exits, but the
# exit STATUS isn't surfaced by enable — so verify Result=success explicitly and
# fail the bootstrap loudly if the graph didn't build (don't serve a broken index).
systemctl enable --now index-build.service || true
BUILD_RESULT="$(systemctl show index-build.service --value -p Result 2>/dev/null || echo unknown)"
if [ "$BUILD_RESULT" != "success" ]; then
  echo "BOOTSTRAP_FAILED: index-build Result=$BUILD_RESULT"
  journalctl -u index-build.service --no-pager | tail -40 || true
  exit 1
fi
systemctl enable --now index-bridge.service  # then the resident reader comes up
echo "BOOTSTRAP_DONE"
