#!/usr/bin/env bash
# bootstrap.sh — index-service host bootstrap (runs as EC2 user-data).
#
# Codifies the reliability lessons from POC bring-up into one idempotent script:
#   - Ubuntu 24.04 ARM base (glibc 2.39 — codegraph-server needs >= 2.38;
#     Amazon Linux 2023's glibc 2.34 is too old, verified failing).
#   - codegraph-server + bridge code pulled from S3 (artifacts staged by deploy).
#   - SINGLE-WRITER discipline: exactly one codegraph process ever touches
#     graph.db. BOTH writers — the BUILD oneshot AND the resident SERVE --mcp
#     session (which opens graph.db read-write, so it IS a writer) — hold the SAME
#     `flock $LOCK`. The build uses `flock -n` (fail-fast): if the bridge is up it
#     refuses immediately rather than opening a second concurrent writer. This is
#     OS-enforced mutual exclusion, backed by THREE layers:
#       (a) flock $LOCK held by BOTH units (the ACTUAL guarantee): a `systemctl
#           restart index-build` while the bridge holds the lock makes the build's
#           `flock -n` fail fast — a clean failure, never a second concurrent writer;
#       (b) systemd ordering: index-build `Before=index-bridge`, index-bridge
#           `After=/Requires= index-build` — so on boot/reconcile the build runs
#           first. (Deliberately NO `Conflicts=` — with the bridge's Requires= it
#           forms a contradictory transaction systemd silently drops on reboot,
#           bricking the service; the flock is the real guard, see the unit below.)
#       (c) the bridge's in-process restart join-guard (refuses to spawn a second
#           worker until the old one's subprocess is confirmed dead).
#     Concurrent writers corrupt RocksDB -> 0-node graph (the #1 failure we hit);
#     codegraph-server additionally self-quarantines a corrupt graph + detects a
#     stale LOCK on open. graph.db and the repo copy both live on LOCAL disk, so
#     this is per-instance — the deploy provisions exactly ONE index-service
#     instance (provision_index_service.sh reuses an existing one). Horizontal
#     scale-out (multiple instances) is unsupported in the MVP; each instance just
#     holds its own independent local copy + graph (no shared state to corrupt).
#   - PATH baked into the unit (codegraph-server lives in /usr/local/bin; systemd
#     has no login PATH — a bare "codegraph-server" spawn fails otherwise).
#   - NO EFS: index-service is self-contained on LOCAL disk. The repo is extracted
#     from the S3 tarball to /data/repo/<subdir>; codegraph indexes it and the
#     bridge reads/greps/globs it there. The agent microVM mounts no filesystem
#     and reads code over the HTTP bridge (read_file/glob_files/search_files), so
#     there is no shared EFS to populate. graph.db + repo copy both live on the
#     single root volume (size it via provision_index_service's root volume).
#
# Inputs via environment (deploy-all.sh writes /etc/index-service.env first):
#   BUCKET, REGION, REPO_SUBDIR (e.g. code-5x), MAX_FILES
set -euxo pipefail
exec > /var/log/index-svc-bootstrap.log 2>&1

# shellcheck disable=SC1091
source /etc/index-service.env

# REPO_SUBDIR MUST be non-empty before any path is built from it: LOCAL_WORKSPACE
# is "$LOCAL_REPO_ROOT/$REPO_SUBDIR", and the freshness re-extract does
# `rm -rf "$LOCAL_WORKSPACE"`. set -u does NOT catch an empty-but-set var, so an
# empty REPO_SUBDIR would make that path the repo ROOT and `rm -rf` would wipe the
# whole tree. The :? form errors on unset OR empty — abort loudly before building paths.
: "${REPO_SUBDIR:?BOOTSTRAP_FAILED: REPO_SUBDIR must be set and non-empty}"

export DEBIAN_FRONTEND=noninteractive
INDEX_HOME=/data                       # codegraph graph.db lives here (LOCAL disk)
APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
LOCK=/data/.codegraph/.writer.lock

mkdir -p "$INDEX_HOME/.codegraph" /opt/idx/bin "$APP"

# --- base packages (retry: apt mirrors can flap on fresh hosts) ---
for i in 1 2 3; do apt-get update -y && break || sleep 10; done
apt-get install -y python3-pip python3-venv unzip curl
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
# SMOKE-TEST the binary NOW (fail loud + early) instead of letting a wrong-arch /
# wrong-glibc / S3-truncated binary surface 10 min later as an opaque index-build
# health-gate timeout. A bad binary can't exec → `--version` fails → we exit with a
# greppable marker the SSM health probe / journalctl can pinpoint.
"$BIN" --version >/dev/null 2>&1 || { echo "BOOTSTRAP_FAILED: codegraph-server binary not executable (wrong arch/glibc or truncated S3 object)"; exit 1; }
aws s3 cp "s3://$BUCKET/index-service.tar.gz" /tmp/idx.tar.gz --region "$REGION"
tar xzf /tmp/idx.tar.gz -C "$APP"
# Install from the shipped requirements.txt — the SINGLE source of truth for
# deps — not a hand-typed list (which had drifted: it installed the unrelated
# standalone `fastmcp`, never imported, while the bridge uses the FastMCP class
# bundled in `mcp`). `mcp` pulls starlette/sse-starlette transitively.
pip3 install --break-system-packages -q --ignore-installed -r "$APP/requirements.txt"
# Verify the RESOLVED dependency set is self-consistent. Top-level deps are ==-pinned,
# but mcp's transitive closure (starlette/pydantic/anyio/httpx) is not — a breaking
# transitive major resolved on a fresh install months later would otherwise only
# surface as a bridge import crash → Restart=always crash-loop → /health never 200 →
# the deploy health-gate burns its full timeout with no clear cause. `pip check`
# turns that into a loud, greppable bootstrap failure here.
python3 -m pip check >/dev/null 2>&1 || { echo "BOOTSTRAP_FAILED: pip dependency conflict (incompatible transitive deps) — pin the transitive closure in requirements.txt"; exit 1; }

# --- extract the repo to LOCAL disk (deploy stages <repo>.tar.gz in S3) ------
# NO EFS: the repo lives only on LOCAL disk at /data/repo/<subdir>. codegraph
# indexes it, and the bridge reads/greps/globs it there; the agent reads code
# over the HTTP bridge, so there is no shared filesystem to populate. The bridge
# rewrites paths to REPO-RELATIVE form via path_align (--mount-root "" below), so
# the agent sees plain repo-relative paths like Assets/Foo.cs (no mount prefix).
#
# FRESHNESS: the local copy is fresh per instance, but a reused instance may hold
# an OLD snapshot. We stamp the deploy's ARTIFACT_SIG (S3 ETag of the staged
# tarball, passed in the env) under the repo root and RE-EXTRACT whenever the
# stamp differs (or is missing, or the dir is empty).
LOCAL_REPO_ROOT=/data/repo
LOCAL_WORKSPACE="$LOCAL_REPO_ROOT/$REPO_SUBDIR"
WORKSPACE="$LOCAL_WORKSPACE"               # codegraph indexes the local copy
SIG_STAMP="$LOCAL_REPO_ROOT/.artifact_sig"
WANT_SIG="${ARTIFACT_SIG:-unset}"
HAVE_SIG="$(cat "$SIG_STAMP" 2>/dev/null || echo none)"
# DISK-FULL GUARD: graph.db (RocksDB) does NOT fail cleanly on ENOSPC — a partial
# write yields a corrupt/truncated graph that the 64KiB floor can't catch (it's
# well over 64KiB). The local repo copy + graph.db + the downloaded tarball all
# live on the single root volume under /data, so check headroom BEFORE extracting
# and fail LOUDLY rather than silently corrupting. Budget ≈ 4× the tarball
# (tarball + local tree + graph.db growth); /data free space must exceed it.
require_disk_headroom() {
  local tarball_kb avail_kb need_kb
  tarball_kb="$(du -k /tmp/repo.tar.gz 2>/dev/null | cut -f1 || echo 0)"
  avail_kb="$(df -Pk /data | awk 'NR==2{print $4}')"
  need_kb=$(( tarball_kb * 4 + 1048576 ))   # 4x tarball + 1GiB base headroom
  if [ "${avail_kb:-0}" -lt "$need_kb" ]; then
    echo "BOOTSTRAP_FAILED: insufficient /data space: avail=${avail_kb}KiB need>=${need_kb}KiB (tarball ${tarball_kb}KiB). Grow the root volume."
    exit 1
  fi
}
mkdir -p "$LOCAL_REPO_ROOT"
# Re-extract if: never extracted, empty tree, or the staged snapshot changed.
if [ ! -d "$LOCAL_WORKSPACE" ] || [ -z "$(ls -A "$LOCAL_WORKSPACE" 2>/dev/null)" ] || [ "$HAVE_SIG" != "$WANT_SIG" ]; then
  aws s3 cp "s3://$BUCKET/${REPO_SUBDIR}.tar.gz" /tmp/repo.tar.gz --region "$REGION"
  require_disk_headroom                     # fail loud if /data can't hold the extract + graph
  rm -rf "$LOCAL_WORKSPACE"                 # drop the stale snapshot so the new one is clean
  tar xzf /tmp/repo.tar.gz -C "$LOCAL_REPO_ROOT"
  echo "$WANT_SIG" > "$SIG_STAMP"           # stamp AFTER a successful extract
fi
# Reclaim the downloaded tarball now that the copy is extracted — it is a dead
# ~18MB+ file on the size-constrained root volume otherwise (a re-run re-downloads
# it cheaply when a sig change requires re-extract).
rm -f /tmp/repo.tar.gz
# Install ripgrep for fast, .gitignore-aware search (apt has it on Ubuntu 24.04).
command -v rg >/dev/null || apt-get install -y ripgrep || true

# --- systemd units: build (oneshot, sole writer) THEN serve (resident reader) ---
cat > /etc/systemd/system/index-build.service <<UNIT
[Unit]
Description=CodeGraph index build (single-writer, runs to completion before serve)
After=network-online.target remote-fs.target
Wants=network-online.target
# Order the build BEFORE the bridge so on boot/reconcile the build completes first.
# NOTE: deliberately NO `Conflicts=index-bridge` — it looks like it would close the
# `systemctl restart index-build` footgun, but combined with the bridge's
# Requires=index-build + WantedBy=multi-user.target it forms a contradictory
# start+stop transaction that systemd SILENTLY drops on every reboot (empirically
# reproduced on systemd 255 / Ubuntu 24.04: after the first reboot neither unit
# starts). The single-writer guarantee does NOT need it: the flock below is the
# real, OS-enforced guard — a `systemctl restart index-build` while the bridge holds
# the lock just makes the build's `flock -n` fail fast (clean failure), never a
# second concurrent writer. Before= alone gives the boot ordering we want.
Before=index-bridge.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# Belt-and-suspenders: refuse to build unless the LOCAL workspace exists AND is
# NON-EMPTY — so a partial/empty extract fails loudly instead of building a 0-node
# graph that would then serve wrong "not found" answers (Requires=index-build
# keeps the bridge from serving a failed build). `test -d` alone only proves the
# dir exists, not that it has code. On a REBOOT the user-data bootstrap does NOT
# re-run, but the local copy persists on the root volume, so this check still holds.
ExecStartPre=/bin/bash -c '[ -n "\$(ls -A $WORKSPACE 2>/dev/null)" ] || { echo "FATAL: $WORKSPACE is empty — refusing to build a 0-node graph"; exit 1; }'
# DISK HEADROOM before the WRITER runs (not just at extract time): RocksDB does not
# fail cleanly on ENOSPC — a partial write yields an oversized-but-corrupt graph the
# 64KiB floor below cannot catch. On a REBOOT this unit re-runs (bridge Requires=)
# while the cloud-init headroom check does NOT, so guard the writer itself. Budget
# ~2.5x the on-disk repo (graph ≈ repo-order-of-magnitude) + 1GiB.
ExecStartPre=/bin/bash -c 'need=\$(( \$(du -sk $WORKSPACE 2>/dev/null | cut -f1) * 5 / 2 + 1048576 )); avail=\$(df -Pk $INDEX_HOME | awk "NR==2{print \\\$4}"); [ "\${avail:-0}" -ge "\$need" ] || { echo "FATAL: insufficient $INDEX_HOME space for graph build: avail=\${avail}KiB need>=\${need}KiB — grow the root volume"; exit 1; }'
# flock -n: take the EXCLUSIVE writer lock or FAIL FAST. The resident bridge holds
# this same lock for its whole life (see index-bridge ExecStart), so if the bridge
# is up this build refuses immediately (clean failure) instead of opening graph.db
# as a SECOND concurrent writer → RocksDB 0-node corruption (the #1 failure). On a
# normal boot/redeploy the bridge isn't up yet (ordering Before=/After= sequences
# the build ahead of it), so the lock is free and the build proceeds. Build is in-place (codegraph derives
# graph.db from \$HOME/.codegraph and also keeps a projects/<hash>/memory dir there);
# a partial/corrupt result is caught THREE ways: the size floor below, the bridge's
# warmup health-gate (refuses to serve a 0-node graph), and codegraph-server's own
# stale-LOCK detection + corrupt-graph quarantine on the next open.
ExecStart=/usr/bin/flock -n $LOCK $BIN --graph-only --workspace $WORKSPACE \\
  --exclude node_modules --exclude .venv --exclude .git --max-files $MAX_FILES \\
  --run-tool codegraph_symbol_search --tool-args '{"query":"__build__"}'
# Post-build floor: a real build of a non-empty repo produces a graph.db well
# above an empty-RocksDB baseline. If it's trivially small the build silently
# produced ~0 nodes (corrupt/empty) — FAIL the unit so the bridge (Requires=)
# never serves it, instead of relying solely on the bridge's warmup string-match.
ExecStartPost=/bin/bash -c 'sz=\$(du -sb $INDEX_HOME/.codegraph/graph.db 2>/dev/null | cut -f1); [ "\${sz:-0}" -ge 65536 ] || { echo "FATAL: graph.db is \${sz:-0} bytes (<64KiB) — build produced an empty/corrupt graph"; exit 1; }'
UNIT

cat > /etc/systemd/system/index-bridge.service <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge (resident single session)
After=index-build.service
Requires=index-build.service
[Service]
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=$MAX_FILES
WorkingDirectory=$APP
# Hold the SAME writer lock for the bridge's whole life: the resident --mcp process
# opens graph.db read-write, so it IS a writer. Holding $LOCK makes the build's
# flock -n fail fast if anyone tries to run it while we're up — OS-enforced single
# writer, not just systemd policy. flock keeps the lock until python exits (and
# propagates SIGTERM on stop), so Restart=always re-acquires cleanly.
# No --mount-root: the agent has no filesystem mount, so paths are returned
# REPO-RELATIVE (e.g. Assets/Foo.cs), which is the honest representation.
ExecStart=/usr/bin/flock $LOCK /usr/bin/python3 -m http_bridge --workspace $WORKSPACE --host 0.0.0.0 --port 8080 --mount-root "" --local-workspace $LOCAL_WORKSPACE
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
