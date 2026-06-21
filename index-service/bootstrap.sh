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
#   BUCKET, REGION, MAX_FILES, REPO_MANIFEST_JSON, GIT_SECRET_ID (optional)
#   REPO_MANIFEST_JSON is ONE project's repo set in ONE JSON value (multi-project + git refresh):
#     {"projectId":"<id>","port":<int>,
#      "repos":[{"subdir":"<name>","git":"<url>","ref":"<branch?>","refreshIntervalSec":<int?>}, ...]}
#   ONE JSON var (not per-repo shell vars) because a git URL/ref can carry `@`/`:` that a sourced
#   env file would mangle (and the project hit `|`-in-env crashes before adopting one JSON var).
#   Code source is git-only (R1): each repo is `git clone`d to /data/repo/<subdir> using a
#   read-only credential fetched host-side from Secrets Manager (GIT_SECRET_ID), then refreshed
#   on a per-repo systemd timer (git pull); codegraph's resident file-watcher re-indexes in-place.
set -euxo pipefail
exec > /var/log/index-svc-bootstrap.log 2>&1

# shellcheck disable=SC1091
source /etc/index-service.env

: "${REPO_MANIFEST_JSON:?BOOTSTRAP_FAILED: REPO_MANIFEST_JSON must be set and non-empty}"

export DEBIAN_FRONTEND=noninteractive
INDEX_HOME=/data                       # per-repo graph.db lives under /data/<subdir> (LOCAL disk)
APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
LOCAL_REPO_ROOT=/data/repo

mkdir -p "$INDEX_HOME" /opt/idx/bin "$APP" "$LOCAL_REPO_ROOT"

# retry a network-dependent command with backoff. On a FRESH account the instance
# can boot in the private subnet BEFORE the NAT gateway's default route has fully
# converged into the private route table — so the first apt/curl/S3 calls may fail
# with no route to host for tens of seconds. A thin "3×10s on apt-get update only"
# left every other network op (apt install, the awscli download, S3 copies)
# unguarded, so a fresh deploy intermittently died here and surfaced as a confusing
# 15-min index-build health-gate timeout instead of a network error. ~6×20s ≈ 2min
# covers realistic NAT-route convergence. (cross-review HIGH)
retry_net() {
  local n=0 max=6
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      echo "BOOTSTRAP_FAILED: network command failed after ${max} attempts: $*" >&2
      return 1
    fi
    echo "retry_net: attempt ${n}/${max} failed, sleeping 20s: $*" >&2
    sleep 20
  done
}

# --- base packages (retry: apt mirrors flap AND the NAT route may not be up yet) ---
retry_net apt-get update -y
retry_net apt-get install -y python3-pip python3-venv unzip curl
# awscli v2 (Ubuntu 24.04 has no apt awscli)
if ! command -v aws >/dev/null; then
  retry_net curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q -o awscliv2.zip && ./aws/install --update)
fi
export PATH=/usr/local/bin:$PATH

# --- artifacts from S3 ---
retry_net aws s3 cp "s3://$BUCKET/bin/codegraph-server" "$BIN" --region "$REGION"
chmod +x "$BIN"
ln -sf "$BIN" /usr/local/bin/codegraph-server
# SMOKE-TEST the binary NOW (fail loud + early) instead of letting a wrong-arch /
# wrong-glibc / S3-truncated binary surface 10 min later as an opaque index-build
# health-gate timeout. A bad binary can't exec → `--version` fails → we exit with a
# greppable marker the SSM health probe / journalctl can pinpoint.
"$BIN" --version >/dev/null 2>&1 || { echo "BOOTSTRAP_FAILED: codegraph-server binary not executable (wrong arch/glibc or truncated S3 object)"; exit 1; }
retry_net aws s3 cp "s3://$BUCKET/index-service.tar.gz" /tmp/idx.tar.gz --region "$REGION"
tar xzf /tmp/idx.tar.gz -C "$APP"
# Install from the shipped requirements.txt — the SINGLE source of truth for
# deps — not a hand-typed list (which had drifted: it installed the unrelated
# standalone `fastmcp`, never imported, while the bridge uses the FastMCP class
# bundled in `mcp`). `mcp` pulls starlette/sse-starlette transitively.
retry_net pip3 install --break-system-packages -q --ignore-installed -r "$APP/requirements.txt"
# Verify the RESOLVED dependency set is self-consistent. Top-level deps are ==-pinned,
# but mcp's transitive closure (starlette/pydantic/anyio/httpx) is not — a breaking
# transitive major resolved on a fresh install months later would otherwise only
# surface as a bridge import crash → Restart=always crash-loop → /health never 200 →
# the deploy health-gate burns its full timeout with no clear cause. `pip check`
# turns that into a loud, greppable bootstrap failure here.
python3 -m pip check >/dev/null 2>&1 || { echo "BOOTSTRAP_FAILED: pip dependency conflict (incompatible transitive deps) — pin the transitive closure in requirements.txt"; exit 1; }

# --- validate the manifest with the SHIPPED parser (same one deploy/tests use) ----
# render_manifest.py is staged into the app dir (deploy-all stages it alongside the
# bridge). Fail loud here on a bad manifest — never half-provision repos.
RENDER_MANIFEST="$APP/render_manifest.py"
[ -f "$RENDER_MANIFEST" ] || { echo "BOOTSTRAP_FAILED: render_manifest.py not in app bundle ($RENDER_MANIFEST)"; exit 1; }
printf '%s' "$REPO_MANIFEST_JSON" > /etc/index-manifest.json
SUBDIRS="$(python3 "$RENDER_MANIFEST" --field subdir /etc/index-manifest.json)" \
  || { echo "BOOTSTRAP_FAILED: invalid REPO_MANIFEST_JSON (see render_manifest error above)"; exit 1; }
# Top-level scalars: this project's id (→ systemd instance name index-bridge@<id>) and its bridge
# port. render_manifest validates the whole manifest, so a bad projectId/port fails loud here.
PROJECT_ID="$(python3 "$RENDER_MANIFEST" --field projectId /etc/index-manifest.json)" \
  || { echo "BOOTSTRAP_FAILED: manifest missing/invalid projectId"; exit 1; }
BRIDGE_PORT="$(python3 "$RENDER_MANIFEST" --field port /etc/index-manifest.json)" \
  || { echo "BOOTSTRAP_FAILED: manifest missing/invalid port"; exit 1; }
# The serve unit's full --workspace/--local-workspace argv (one pair per repo).
SERVE_ARGS="$(python3 "$RENDER_MANIFEST" --serve-args "$LOCAL_REPO_ROOT" /etc/index-manifest.json)" \
  || { echo "BOOTSTRAP_FAILED: could not render serve args from manifest"; exit 1; }

# --- git credential (R-cred-1): one read-only token in Secrets Manager, fetched HOST-SIDE -----
# Never passed through user-data / SSM command bodies (those land in CloudTrail). For https
# remotes we expose it via a GIT_ASKPASS helper; ssh remotes use the host key (out of scope here).
# Best-effort at bootstrap (public repos need no token); the refresh timer units reference the
# same askpass via GIT_CRED_ENV_LINES below.
GIT_CRED_ENV_LINES=""
if [ -n "${GIT_SECRET_ID:-}" ]; then
  GIT_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$GIT_SECRET_ID" \
    --query SecretString --output text 2>/dev/null || echo "")"
  if [ -n "$GIT_TOKEN" ]; then
    # askpass prints the token on any git credential prompt (username or password); a read-only
    # PAT works as the password and most hosts accept any/empty username with a PAT.
    printf '#!/bin/sh\nexec echo "%s"\n' "$GIT_TOKEN" > /opt/idx/git-askpass.sh
    chmod 700 /opt/idx/git-askpass.sh
    export GIT_ASKPASS=/opt/idx/git-askpass.sh GIT_TERMINAL_PROMPT=0
    GIT_CRED_ENV_LINES=$'Environment=GIT_ASKPASS=/opt/idx/git-askpass.sh\nEnvironment=GIT_TERMINAL_PROMPT=0'
    unset GIT_TOKEN   # don't keep the plaintext in the shell env
  else
    echo "WARN: GIT_SECRET_ID set but secret empty/unreadable — git clone will work only for public repos"
  fi
fi

# --- per-repo extract to LOCAL disk + per-repo BUILD unit (single-writer per graph) ---
# NO EFS: each repo lives only on LOCAL disk at /data/repo/<subdir>. codegraph indexes
# it; the bridge reads/greps/globs it there; the agent reads over HTTP. The bridge
# returns REPO-RELATIVE paths prefixed with <repo>/ (--mount-root "" + multi-repo).
#
# SINGLE-WRITER PER GRAPH (不变量2): each repo gets its OWN graph.db, HOME, and flock
# under /data/<subdir> — so building/refreshing one repo never touches another's graph.
# The build is a per-repo systemd TEMPLATE unit (index-build@<subdir>); the ONE serve
# unit (index-bridge) opens ALL repos' graph.db read-write and holds EACH repo's flock,
# so a stray `systemctl restart index-build@<subdir>` while the bridge is up fails fast
# on that repo's flock (clean failure, never a 2nd concurrent writer).
# Per-repo BUILD template. %i = the subdir (instance name). Each instance derives its
# graph.db from HOME=/data/<subdir>/.home/.codegraph and holds /data/<subdir>/.codegraph/.writer.lock.
# Mirrors the single-repo unit's THREE guards (non-empty check, disk headroom, 64KiB
# floor) but per-repo. NO `Conflicts=` (same systemd-silent-drop footgun as before).
# SINGLE-WRITER (不变量2): this build flock and the serve unit's SERVE_FLOCKS lock the SAME
# file per repo (/data/<subdir>/.codegraph/.writer.lock) — so a build and the resident serve
# can NEVER open one repo's graph.db concurrently. (The bridge's OWN python .bridge.lock is a
# DIFFERENT, orthogonal guard: it stops a 2nd bridge PROCESS / gunicorn workers>1, not the
# build — so the two lock files are intentionally distinct, not a mismatch.)
cat > /etc/systemd/system/index-build@.service <<UNIT
[Unit]
Description=CodeGraph index build for repo %i (single-writer per graph)
After=network-online.target remote-fs.target
Wants=network-online.target
Before=index-bridge@.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=$LOCAL_REPO_ROOT/%i/.home
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStartPre=/bin/bash -c '[ -n "\$(ls -A $LOCAL_REPO_ROOT/%i 2>/dev/null)" ] || { echo "FATAL: $LOCAL_REPO_ROOT/%i is empty — refusing to build a 0-node graph"; exit 1; }'
ExecStartPre=/bin/bash -c 'need=\$(( \$(du -sk $LOCAL_REPO_ROOT/%i 2>/dev/null | cut -f1) * 5 / 2 + 1048576 )); avail=\$(df -Pk $INDEX_HOME | awk "NR==2{print \\\$4}"); [ "\${avail:-0}" -ge "\$need" ] || { echo "FATAL: insufficient $INDEX_HOME space for %i graph build: avail=\${avail}KiB need>=\${need}KiB"; exit 1; }'
ExecStart=/usr/bin/flock -n $LOCAL_REPO_ROOT/%i/.codegraph/.writer.lock $BIN --graph-only --workspace $LOCAL_REPO_ROOT/%i \\
  --exclude node_modules --exclude .venv --exclude .git --max-files $MAX_FILES \\
  --run-tool codegraph_symbol_search --tool-args '{"query":"__build__"}'
ExecStartPost=/bin/bash -c 'sz=\$(du -sb $LOCAL_REPO_ROOT/%i/.home/.codegraph/graph.db 2>/dev/null | cut -f1); [ "\${sz:-0}" -ge 65536 ] || { echo "FATAL: %i graph.db is \${sz:-0} bytes (<64KiB) — empty/corrupt graph"; exit 1; }'
UNIT

# Clone each repo to LOCAL disk via git (R1: git is the only source). git_fetch.sh is idempotent
# (clone if absent, fetch+reset if present) and prints GIT_FETCH_FAILED on failure. The per-repo
# `: "${SUBDIR:?}"` guards again before git touches a path, even though render_manifest already
# rejected an empty/invalid subdir. Graph dirs (.codegraph/.home) are git's siblings under $WS,
# NOT inside the cloned tree, so they survive a re-clone.
GIT_FETCH="$APP/git_fetch.sh"
[ -f "$GIT_FETCH" ] || { echo "BOOTSTRAP_FAILED: git_fetch.sh not in app bundle ($GIT_FETCH)"; exit 1; }
while IFS= read -r SUBDIR; do
  : "${SUBDIR:?BOOTSTRAP_FAILED: empty subdir from manifest (refusing git op on repo root)}"
  WS="$LOCAL_REPO_ROOT/$SUBDIR"
  GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" /etc/index-manifest.json)" \
    || { echo "BOOTSTRAP_FAILED: no git url for $SUBDIR"; exit 1; }
  GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" /etc/index-manifest.json || echo "")"
  # git_fetch clones into $WS (must be empty/absent on first boot; idempotent fetch+reset after).
  # Graph dirs live INSIDE $WS (.codegraph/.home) — the proven single-repo layout that the build
  # and serve units already reference. They're created AFTER the clone (clone needs an empty dir)
  # and are git-untracked, so `git reset --hard` on refresh never removes them. codegraph indexes
  # $WS with HOME=$WS/.home; it tolerates its own graph dir living under the workspace (verified).
  retry_net bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
    || { echo "BOOTSTRAP_FAILED: git fetch $SUBDIR"; exit 1; }
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
done <<< "$SUBDIRS"

# Install ripgrep for fast, .gitignore-aware search (apt has it on Ubuntu 24.04).
command -v rg >/dev/null || apt-get install -y ripgrep || true

# --- serve unit: ONE bridge process loading ALL repos (per-project topology) ------
# Holds EVERY repo's writer flock for its whole life (the resident --mcp process opens
# each graph.db read-write). build_bridge re-takes each per-workspace flock internally;
# the serve unit also flocks each so a stray build@<repo> fails fast. No --mount-root:
# paths are REPO-RELATIVE, prefixed <repo>/ by the multi-repo bridge.
SERVE_FLOCKS=""
BUILD_UNITS=""
for SUBDIR in $SUBDIRS; do
  SERVE_FLOCKS="$SERVE_FLOCKS /usr/bin/flock $LOCAL_REPO_ROOT/$SUBDIR/.codegraph/.writer.lock"
  BUILD_UNITS="$BUILD_UNITS index-build@${SUBDIR}.service"
done
# REBOOT ORDERING (cross-review CRITICAL): the serve unit MUST start AFTER every per-repo
# build on a reboot too (bootstrap's enable-loop only orders the FIRST boot). Without this,
# on reboot systemd could start the bridge before a build finishes — the serve flock then
# blocks until the build releases it (so NO corruption — the flock is the real guard), but
# the bridge would sit wedged on the lock instead of cleanly waiting. After=+Wants= the build
# instances fixes the ordering. Deliberately Wants= NOT Requires= (the original single-repo
# design's lesson: Requires= + a build failure cascades the bridge down; the warmup health
# gate + 64KiB floor already refuse to serve a bad graph, so ordering is enough).
# PER-PROJECT serve unit (template): index-bridge@<projectId>. %i = projectId. Each project's
# bridge serves ONLY its own repos (SERVE_ARGS, built from this project's manifest) on its OWN
# port (BRIDGE_PORT) — so project A's process has no handle to project B's graph (A 档逻辑隔离).
# Multiple projects on one host = multiple index-bridge@<id> instances on distinct ports.
cat > /etc/systemd/system/index-bridge@.service <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge for project %i (resident)
After=network-online.target remote-fs.target$BUILD_UNITS
Wants=network-online.target$BUILD_UNITS
[Service]
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=$MAX_FILES
WorkingDirectory=$APP
ExecStart=$SERVE_FLOCKS /usr/bin/python3 -m http_bridge $SERVE_ARGS --host 0.0.0.0 --port $BRIDGE_PORT --mount-root ""
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

# --- per-repo refresh timer: git pull on a schedule; codegraph's file-watcher re-indexes ------
# The timer's service does ONE thing: git pull this repo's working tree (git_fetch.sh). It NEVER
# spawns a codegraph process — the resident index-bridge@<projectId> has its own file-watcher that
# picks up the changed files and incrementally re-indexes the in-memory graph within seconds
# (verified spike). So the single-writer-per-graph invariant is untouched, and there is no blip.
# OnUnitActiveSec is per-repo (manifest refreshIntervalSec, default 300s). GIT_CRED_ENV_LINES
# injects the same host-side askpass the initial clone used.
cat > /etc/systemd/system/index-refresh@.service <<UNIT
[Unit]
Description=Scheduled git pull for repo %i (codegraph watcher re-indexes in-place)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin
$GIT_CRED_ENV_LINES
ExecStart=/bin/bash -c '$APP/git_fetch.sh %i "\$(python3 $RENDER_MANIFEST --repo-field git %i /etc/index-manifest.json)" "\$(python3 $RENDER_MANIFEST --repo-field ref %i /etc/index-manifest.json)" $LOCAL_REPO_ROOT/%i'
UNIT

systemctl daemon-reload
# Build each repo first (sole writer per graph). enable --now blocks until each oneshot
# exits; verify Result=success per repo and fail loudly if any graph didn't build.
for SUBDIR in $SUBDIRS; do
  systemctl enable --now "index-build@${SUBDIR}.service" || true
  R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
  if [ "$R" != "success" ]; then
    echo "BOOTSTRAP_FAILED: index-build@${SUBDIR} Result=$R"
    journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -40 || true
    exit 1
  fi
done
systemctl enable --now "index-bridge@${PROJECT_ID}.service"  # resident reader for THIS project's repos

# Per-repo refresh timers: OnUnitActiveSec = that repo's refreshIntervalSec (manifest), default 300.
for SUBDIR in $SUBDIRS; do
  IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" /etc/index-manifest.json 2>/dev/null || echo "")"
  [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300
  cat > "/etc/systemd/system/index-refresh@${SUBDIR}.timer" <<TIMER
[Unit]
Description=Refresh timer for repo ${SUBDIR}
[Timer]
OnBootSec=${IV}s
OnUnitActiveSec=${IV}s
Unit=index-refresh@${SUBDIR}.service
[Install]
WantedBy=timers.target
TIMER
  systemctl enable --now "index-refresh@${SUBDIR}.timer"
done

# --- bot-gateway: co-located Feishu long-connection gateway -----------------
# The gateway runs ON this same host (a second resident service alongside the
# index bridge). It is BUILT + INSTALLED here but deliberately NOT started: it
# hard-requires RUNTIME_ARN, which doesn't exist until the AgentCore runtime is
# created in a LATER deploy phase. deploy-all.sh writes /etc/bot-gateway.env and
# starts bot-gateway.service AFTER the runtime is ready (via SSM). On a REBOOT the
# unit (WantedBy=multi-user.target) restarts on its own — by then the env file
# persists on disk, so it comes straight back up.
#
# Backend-only deploys (no gateway tarball staged) skip this gracefully.
GW_APP=/opt/bot-gateway
if aws s3api head-object --bucket "$BUCKET" --key bot-gateway.tar.gz --region "$REGION" >/dev/null 2>&1; then
  echo "setting up bot-gateway (build now, start later when runtime env is written)"
  # Node 24 — same major as the agent container's CLI subprocess. Pin the MAJOR
  # only (setup_24.x): NodeSource GCs old patch debs, so an exact patch pin would
  # break the build later. Skip if a compatible node is already present (reboot/rerun).
  if ! command -v node >/dev/null 2>&1; then
    retry_net curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesetup.sh
    bash /tmp/nodesetup.sh
    retry_net apt-get install -y nodejs
  fi
  mkdir -p "$GW_APP"
  retry_net aws s3 cp "s3://$BUCKET/bot-gateway.tar.gz" /tmp/gw.tar.gz --region "$REGION"
  tar xzf /tmp/gw.tar.gz -C "$GW_APP"
  rm -f /tmp/gw.tar.gz
  # The gateway resolves card copy at __dirname/../../config/i18n.json — from
  # /opt/bot-gateway/dist that is /opt/config. The tarball ships config/ under the gateway
  # dir, so relocate it to /opt/config (parent of GW_APP) where the runtime path expects it.
  if [ -d "$GW_APP/config" ]; then
    rm -rf /opt/config
    mv "$GW_APP/config" /opt/config
  fi
  # Install ALL deps (typescript/@types live in devDependencies and `npm run build`
  # = `tsc` needs them), compile TS → dist/, THEN prune devDeps so the resident
  # service runs on prod-only modules. A bare `npm ci --omit=dev` would skip tsc and
  # make `npm run build` fail with "tsc: not found" (cross-review HIGH).
  ( cd "$GW_APP" && retry_net npm ci && npm run build && npm prune --omit=dev ) \
    || { echo "BOOTSTRAP_FAILED: bot-gateway npm ci / build / prune failed"; exit 1; }
  chmod +x "$GW_APP/run.sh"
  # Sanity: the compiled entrypoint must exist, else the unit would crash-loop later.
  [ -f "$GW_APP/dist/index.js" ] || { echo "BOOTSTRAP_FAILED: bot-gateway build produced no dist/index.js"; exit 1; }

  cat > /etc/systemd/system/bot-gateway.service <<UNIT
[Unit]
Description=source-truth Feishu bot-gateway (long-connection event subscriber)
After=network-online.target
Wants=network-online.target
# Only starts once /etc/bot-gateway.env exists (deploy writes it after the runtime
# is ready). ConditionPathExists makes a premature boot a clean no-op, not a crash-
# loop: systemd marks the unit "condition failed" and moves on; the deploy's
# later start re-evaluates it.
ConditionPathExists=/etc/bot-gateway.env
[Service]
WorkingDirectory=$GW_APP
# run.sh sources /etc/bot-gateway.env (non-secret config) and fetches the Feishu
# app credentials from Secrets Manager into the process env (never written to disk).
ExecStart=$GW_APP/run.sh
Restart=always
RestartSec=5
# Mirror the gateway's structured JSON logs (incl. metric:true telemetry lines) to a file
# the CloudWatch agent tails (configured below). journald keeps them too (journalctl -u
# bot-gateway still works); the file is the CloudWatch source. append: (not truncate:) so a
# Restart=always restart doesn't wipe the in-flight log between agent reads.
StandardOutput=append:/var/log/bot-gateway.log
StandardError=append:/var/log/bot-gateway.log
# OOM ISOLATION: the gateway shares this host with the resident codegraph index
# (the system's reason for existing). Cap the gateway's memory via cgroup so a
# gateway leak/spike triggers ITS OWN OOM-kill (systemd restarts it) instead of
# letting the kernel pick the codegraph writer and corrupt/empty graph.db
# (cross-review). Tunable via CODEGRAPH_MAX_FILES-class sizing; 1G is ample for a
# Node long-connection + bounded concurrent invokes (MAX_CONCURRENT_INVOKES).
MemoryHigh=768M
MemoryMax=1G
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  # enable (start on future boots) but do NOT start now — the env file isn't written
  # yet. The deploy starts it explicitly once the runtime exists.
  systemctl enable bot-gateway.service || true
  echo "bot-gateway installed (not started — awaiting /etc/bot-gateway.env)"

  # --- CloudWatch agent: ship the gateway's metric:true / health lines to CloudWatch ----
  # Telemetry plan 阶段0 gate 2/3 + the monitoring plan's §0 front gate: the gateway's
  # structured logs must reach a CloudWatch log group so Logs-Insights / metric-filters /
  # dashboards can read them. The index instance role already has the logs perms (gate 1/3,
  # provision_iam.sh cloudwatch-logs policy) SCOPED to /source-truth/* — so the log group
  # name MUST start with that leading-slash prefix or every PutLogEvents AccessDenies.
  # Best-effort: a CloudWatch-agent failure must NOT fail the bootstrap (the gateway still
  # works; only telemetry shipping is degraded). Install the official agent .deb from S3's
  # regional bucket, write a minimal config tailing the gateway log file, start it.
  CW_DEB=/tmp/amazon-cloudwatch-agent.deb
  if retry_net curl -fsSL "https://amazoncloudwatch-agent-${REGION}.s3.${REGION}.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb" -o "$CW_DEB"; then
    dpkg -i -E "$CW_DEB" || apt-get install -f -y || true
    rm -f "$CW_DEB"
    mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
    # collect_list tails the gateway log → /source-truth/bot-gateway (leading slash: matches
    # the IAM scope). instance-id stream so multiple hosts (blue-green) don't interleave.
    cat > /opt/aws/amazon-cloudwatch-agent/etc/cw-config.json <<CWCFG
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/bot-gateway.log",
            "log_group_name": "/source-truth/bot-gateway",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90
          }
        ]
      }
    }
  }
}
CWCFG
    # fetch-config (not append-config) so a re-run replaces, not duplicates, the input.
    if /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/cw-config.json; then
      echo "cloudwatch-agent shipping /var/log/bot-gateway.log → /source-truth/bot-gateway"
    else
      echo "WARN: cloudwatch-agent fetch-config failed — gateway runs, telemetry shipping degraded"
    fi
  else
    echo "WARN: cloudwatch-agent download failed — gateway runs, telemetry shipping degraded"
  fi
else
  echo "no bot-gateway.tar.gz staged — skipping gateway setup (backend-only deploy)"
fi

echo "BOOTSTRAP_DONE"
