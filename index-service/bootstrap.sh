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
#   BUCKET, REGION, MAX_FILES, REPO_MANIFEST_JSON
#   REPO_MANIFEST_JSON is the project's repo set in ONE JSON value (multi-repo 阶段2):
#     {"repos":[{"subdir":"<name>","source":"...","sig":"<etag>"}, ...]}
#   ONE JSON var (not per-repo shell vars) because a per-repo S3 ETag can contain `|`
#   (multipart) which a sourced env file parses as a shell pipe → bootstrap crash.
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
# The serve unit's full --workspace/--local-workspace argv (one pair per repo).
SERVE_ARGS="$(python3 "$RENDER_MANIFEST" --serve-args "$LOCAL_REPO_ROOT" /etc/index-manifest.json)" \
  || { echo "BOOTSTRAP_FAILED: could not render serve args from manifest"; exit 1; }

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
require_disk_headroom() {   # $1 = tarball path; budget 4x tarball + 1GiB on /data
  local tb_kb avail_kb need_kb
  tb_kb="$(du -k "$1" 2>/dev/null | cut -f1 || echo 0)"
  avail_kb="$(df -Pk /data | awk 'NR==2{print $4}')"
  need_kb=$(( tb_kb * 4 + 1048576 ))
  if [ "${avail_kb:-0}" -lt "$need_kb" ]; then
    echo "BOOTSTRAP_FAILED: insufficient /data space: avail=${avail_kb}KiB need>=${need_kb}KiB (tarball ${tb_kb}KiB). Grow the root volume."
    exit 1
  fi
}

# Per-repo BUILD template. %i = the subdir (instance name). Each instance derives its
# graph.db from HOME=/data/<subdir>/.codegraph and holds /data/<subdir>/.codegraph/.writer.lock.
# Mirrors the single-repo unit's THREE guards (non-empty check, disk headroom, 64KiB
# floor) but per-repo. NO `Conflicts=` (same systemd-silent-drop footgun as before).
cat > /etc/systemd/system/index-build@.service <<UNIT
[Unit]
Description=CodeGraph index build for repo %i (single-writer per graph)
After=network-online.target remote-fs.target
Wants=network-online.target
Before=index-bridge.service
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

# Extract each repo (freshness-stamped per repo) and build its graph. The per-repo
# `: "\${SUBDIR:?}"` is implicit: render_manifest already rejected an empty/invalid
# subdir, and we iterate ONLY its validated output — but guard again before any rm -rf.
while IFS= read -r SUBDIR; do
  : "${SUBDIR:?BOOTSTRAP_FAILED: empty subdir from manifest (refusing rm -rf on repo root)}"
  WS="$LOCAL_REPO_ROOT/$SUBDIR"
  # Per-repo sig (S3 ETag) for the freshness stamp — look it up by subdir from the manifest
  # using the SHIPPED parser (PYTHONPATH=$APP so `import render_manifest` resolves).
  WANT_SIG="$(PYTHONPATH="$APP" python3 -c 'import sys; from render_manifest import parse_manifest; repos=parse_manifest(open("/etc/index-manifest.json").read()); print(next((r["sig"] for r in repos if r["subdir"]==sys.argv[1]), "") or "unset")' "$SUBDIR" 2>/dev/null || echo unset)"
  SIG_STAMP="$WS/.artifact_sig"
  HAVE_SIG="$(cat "$SIG_STAMP" 2>/dev/null || echo none)"
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
  # SOURCE PRESENT? = any entry under $WS that is NOT our scaffolding (.codegraph/.home/
  # .artifact_sig). find -quit stops at the first hit (cheap). Re-extract when: no source
  # tree, or the staged snapshot changed.
  HAS_SOURCE="$(find "$WS" -mindepth 1 -maxdepth 1 \
    ! -name .codegraph ! -name .home ! -name .artifact_sig -print -quit 2>/dev/null)"
  if [ -z "$HAS_SOURCE" ] || [ "$HAVE_SIG" != "$WANT_SIG" ]; then
    retry_net aws s3 cp "s3://$BUCKET/${SUBDIR}.tar.gz" /tmp/repo.tar.gz --region "$REGION"
    require_disk_headroom /tmp/repo.tar.gz
    # The tarball's top-level dir IS <subdir>; extract into LOCAL_REPO_ROOT so it lands
    # at $WS. Drop only the stale SOURCE tree, NOT .codegraph/.home/.artifact_sig (preserve
    # the graph dirs; the extract overwrites the source files).
    find "$WS" -mindepth 1 -maxdepth 1 \
      ! -name .codegraph ! -name .home ! -name .artifact_sig -exec rm -rf {} +
    tar xzf /tmp/repo.tar.gz -C "$LOCAL_REPO_ROOT"
    echo "$WANT_SIG" > "$SIG_STAMP"
    rm -f /tmp/repo.tar.gz
  fi
done <<< "$SUBDIRS"

# Install ripgrep for fast, .gitignore-aware search (apt has it on Ubuntu 24.04).
command -v rg >/dev/null || apt-get install -y ripgrep || true

# --- serve unit: ONE bridge process loading ALL repos (per-project topology) ------
# Holds EVERY repo's writer flock for its whole life (the resident --mcp process opens
# each graph.db read-write). build_bridge re-takes each per-workspace flock internally;
# the serve unit also flocks each so a stray build@<repo> fails fast. No --mount-root:
# paths are REPO-RELATIVE, prefixed <repo>/ by the multi-repo bridge.
SERVE_FLOCKS=""
for SUBDIR in $SUBDIRS; do
  SERVE_FLOCKS="$SERVE_FLOCKS /usr/bin/flock $LOCAL_REPO_ROOT/$SUBDIR/.codegraph/.writer.lock"
done
cat > /etc/systemd/system/index-bridge.service <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge (resident, all project repos)
After=network-online.target remote-fs.target
Wants=network-online.target
[Service]
Environment=HOME=$INDEX_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=$MAX_FILES
WorkingDirectory=$APP
ExecStart=$SERVE_FLOCKS /usr/bin/python3 -m http_bridge $SERVE_ARGS --host 0.0.0.0 --port 8080 --mount-root ""
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
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
systemctl enable --now index-bridge.service  # the resident reader serves all repos

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
