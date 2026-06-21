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
# Sets up the BASE host only — NO project is bound here. user-data runs once at first boot, so
# it cannot add a project to a running host; projects are attached (and added/removed over the
# host's life) by index-service/activate_project.sh, invoked per project over SSM by
# deploy_project.sh. Code source is git-only (R1): activate_project.sh git-clones each repo to
# /data/repo/<subdir>, writes that project's concrete bridge + per-repo refresh units, and a
# read-only git credential is fetched host-side from Secrets Manager. codegraph's resident
# file-watcher re-indexes in-place after each scheduled git pull (no second writer, no blip).
#
# Inputs via environment (deploy-all.sh writes /etc/index-service.env first):
#   BUCKET, REGION, MAX_FILES
set -euxo pipefail
exec > /var/log/index-svc-bootstrap.log 2>&1

# shellcheck disable=SC1091
source /etc/index-service.env

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

# --- per-repo BUILD systemd template (base; NO projects bound yet) ----------------------
# bootstrap sets up the BASE host only — code, deps, the build template, gateway, telemetry.
# It binds NO project: projects are attached LATER (and added/removed over the host's life) by
# activate_project.sh, invoked per project over SSM by deploy_project.sh. This is required
# because user-data runs only ONCE at first boot, so it cannot add a project to a running host.
#
# The build is a per-repo systemd TEMPLATE unit (index-build@<subdir>); a project's concrete
# bridge unit (index-bridge-<projectId>, written by activate_project.sh) opens that project's
# repos' graph.db read-write and holds each repo's flock, so a stray `systemctl restart
# index-build@<subdir>` while the bridge is up fails fast on that repo's flock (clean failure,
# never a 2nd concurrent writer). SINGLE-WRITER (不变量2): build flock + bridge flock lock the
# SAME file per repo (/data/repo/<subdir>/.codegraph/.writer.lock). NO `Conflicts=` (systemd
# silently drops a contradictory transaction on reboot; the flock is the real guard).
ripgrep_install() { command -v rg >/dev/null || apt-get install -y ripgrep || true; }
ripgrep_install   # fast, .gitignore-aware search the bridge's file tools use
cat > /etc/systemd/system/index-build@.service <<UNIT
[Unit]
Description=CodeGraph index build for repo %i (single-writer per graph)
After=network-online.target remote-fs.target
Wants=network-online.target
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

systemctl daemon-reload
# Per-repo refresh units are CONCRETE (index-refresh-<subdir>), written by activate_project.sh
# with that repo's git url/ref baked in (non-secret) — simpler + more debuggable than a template
# that re-derives them. Bootstrap installs only the build@ template above; projects attach later.
mkdir -p /etc/index-projects   # activate_project.sh drops each project's manifest here
echo "base host ready (build template installed; no project bound yet — attach via activate_project.sh)"

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

  # PER-PROJECT gateway TEMPLATE: bot-gateway@<projectId>. %i = projectId. One gateway process
  # per project, each connected to its OWN Feishu app (long-connection, NOT an HTTP listener — so
  # no port collision), reading its own /etc/bot-gateway-%i.env (RUNTIME_ARN + FEISHU_SECRET_ID +
  # PROJECT_ID for that project). activate_gateway.sh writes that env file + starts the instance.
  # Multiple projects on one host = multiple bot-gateway@<id> instances.
  cat > /etc/systemd/system/bot-gateway@.service <<UNIT
[Unit]
Description=source-truth Feishu bot-gateway for project %i (long-connection event subscriber)
After=network-online.target
Wants=network-online.target
# Only starts once this project's env file exists (deploy writes it after the runtime is ready).
# ConditionPathExists makes a premature boot a clean no-op, not a crash-loop.
ConditionPathExists=/etc/bot-gateway-%i.env
[Service]
WorkingDirectory=$GW_APP
# run.sh reads BOT_GATEWAY_ENV (this project's env file) and fetches the Feishu app credentials
# from Secrets Manager into the process env (never written to disk).
Environment=BOT_GATEWAY_ENV=/etc/bot-gateway-%i.env
ExecStart=$GW_APP/run.sh
Restart=always
RestartSec=5
# Per-project log file (the CloudWatch agent tails the glob /var/log/bot-gateway*.log). append:
# (not truncate:) so a Restart=always restart doesn't wipe the in-flight log between agent reads.
StandardOutput=append:/var/log/bot-gateway-%i.log
StandardError=append:/var/log/bot-gateway-%i.log
# OOM ISOLATION: cap each gateway's memory so a gateway leak triggers ITS OWN OOM-kill (systemd
# restarts it) instead of the kernel picking the codegraph writer and corrupting graph.db.
MemoryHigh=768M
MemoryMax=1G
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo "bot-gateway@ template installed (per-project instances started by activate_gateway.sh)"

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
            "file_path": "/var/log/bot-gateway*.log",
            "log_group_name": "/source-truth/bot-gateway",
            "log_stream_name": "{instance_id}-{file_path_basename}",
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
      echo "cloudwatch-agent shipping /var/log/bot-gateway*.log → /source-truth/bot-gateway"
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
