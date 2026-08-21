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
# Sets up the BASE host only — NO project is bound here. This script runs BOTH as EC2 user-data on
# a brand-new host AND as an in-place RE-BOOTSTRAP over SSM on the existing host (provision_index_
# service.sh re-runs it when the staged base-code artifacts no longer match what the host booted
# from — the host is never replaced). Every step below is therefore written to be idempotent and
# must never assume a blank disk or an idle host: it installs/refreshes base code and unit files
# only, and does not touch a running project's bridge.
#
# HOW AN IN-PLACE UPDATE STAYS SAFE (the host serves OTHER projects while this runs):
#   - Nothing is ever untarred, npm-ci'd or rm -rf'd on top of a tree a live process is running
#     from. Every artifact is STAGED (extract + build in a scratch dir), VERIFIED, and only then
#     published with `rsync -a --delay-updates --delete-after`: rsync writes each file to a temp
#     name and rename(2)s it, so updates are atomic per file, already-open fds keep the OLD inode
#     (a running `bash` never reads a changed file at a stale offset), no file is ever missing or
#     half-written, and files dropped upstream are removed AFTER the new set is in place.
#     /opt/config in particular is never absent for an instant — the old `rm -rf /opt/config; mv`
#     took every project's card copy away for the duration and destroyed operator files if the mv
#     then failed.
#   - RESTART OWNERSHIP — bootstrap.sh starts and stops NOTHING, by design:
#       * provision_index_service.sh (rebootstrap_in_place) owns stopping the affected units
#         before this script runs and starting them after it succeeds;
#       * activate_gateway.sh owns its own project's bot-gateway@<projectId>;
#       * activate_project.sh (via deploy_project.sh) owns index-bridge-<projectId>.
#     Where this script leaves code on disk NEWER than a process still running the old code, it
#     prints a `CODE_NEWER_THAN_RUNNING:` line naming the unit, so the owner (and the operator
#     reading the log) can see exactly what still needs cycling. Starting a gateway from here is
#     doubly forbidden: two live processes for one Feishu app fight over the long-connection.
# It also cannot add a project to the host;
# projects are attached (and added/removed over the host's life) by
# index-service/activate_project.sh, invoked per project over SSM by
# deploy_project.sh. Each repo is a git source or a local source: activate_project.sh git-clones a
# git repo to /data/repo/<subdir> (read-only credential fetched host-side from Secrets Manager) and
# writes its per-repo refresh unit; a local repo is pushed in via push-local-repo.sh + applied by
# reindex_local_repo.sh (no refresh unit). Either way codegraph's resident file-watcher re-indexes
# in-place after the working tree changes (no second writer, no blip).
#
# Inputs via environment (deploy-all.sh writes /etc/index-service.env first):
#   BUCKET, REGION, MAX_FILES
#   optional: CW_AGENT_VERSION (pin the CloudWatch agent .deb; default "latest"),
#             REFRESH_CLAUDE_CLI=1 (force-reinstall the claude CLI on a live host)
set -euxo pipefail
# Log to the file AND keep showing on the caller's stdout/stderr, via tee. The old `exec > file`
# sent everything to the log ONLY — under --local (bootstrap runs synchronously in the operator's
# ssh session) that left the terminal frozen at `+ exec` for minutes with no sign of progress. With
# tee, --local streams live to the terminal; as EC2 user-data (no terminal) the extra copy just goes
# to the cloud-init console, harmless. `tee` truncates the log fresh each run (matches old behavior).
# TRUNCATE, NOT APPEND — deliberately: deploy-all / wait_base_host.sh grep THIS log for
# BOOTSTRAP_DONE, so a `tee -a` would leave a previous run's success marker sitting in a log whose
# current run FAILED, and the deploy's health gate would go green on a failure. To still keep the
# record of the bootstrap the host is currently running from (a re-bootstrap otherwise destroys it),
# move the previous log aside to .log.1 first — one generation, bounded, no marker ambiguity.
# CRITICAL: tee is a background process; deploy-all greps the log for BOOTSTRAP_DONE right after this
# script returns, so we must let tee flush the final line first. Record its PID and wait on it at exit.
[ -f /var/log/index-svc-bootstrap.log ] && mv -f /var/log/index-svc-bootstrap.log /var/log/index-svc-bootstrap.log.1
exec > >(tee /var/log/index-svc-bootstrap.log) 2>&1
# ${!:-}: bash>=5.1 sets $! for a process substitution (Ubuntu 24.04 ships 5.2), but under `set -u`
# an unset $! would abort the script right here — default it instead, and skip the wait if empty.
_TEE_PID="${!:-}"
# shellcheck disable=SC2154  # ec IS assigned (ec=$?) at the start of the same trap command
trap 'ec=$?; exec 1>&- 2>&-; [ -n "${_TEE_PID:-}" ] && wait "$_TEE_PID" 2>/dev/null; exit $ec' EXIT

# Missing env file = a caller bug (deploy-all writes it before invoking us). Without this guard
# `source` fails under set -e with no marker, and the deploy sees only an opaque 900s timeout.
[ -f /etc/index-service.env ] || { echo "BOOTSTRAP_FAILED: /etc/index-service.env missing (deploy-all.sh writes it before invoking bootstrap)"; exit 1; }
# set +x around the source: today this file holds only BUCKET/REGION/MAX_FILES/MODEL/
# GLOSSARY_MAX_FILES, but with xtrace on, ANY value later added to it (a token, a salt) would be
# echoed verbatim into /var/log/index-svc-bootstrap.log and the cloud-init console.
set +x
# shellcheck disable=SC1091
source /etc/index-service.env
set -x

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
# DPkg::Lock::Timeout=300: on a fresh boot, unattended-upgrades / cloud-init's apt often hold the
# dpkg lock. Without this, apt-get FAILS INSTANTLY on "Could not get lock" and we bounce through
# retry_net's coarse 20s sleeps; with it, apt itself WAITS up to 5 min for the lock — smoother and
# far less likely to burn all retries during boot-time contention.
APT_OPTS=(-o DPkg::Lock::Timeout=300)
retry_net apt-get "${APT_OPTS[@]}" update -y
# rsync: how every artifact below is PUBLISHED onto a live host (staged tree -> live tree, atomic
# per file). Ubuntu's cloud image ships it and push-local-repo.sh already depends on it host-side,
# but this script must not silently fall back to a non-atomic copy, so make it explicit.
retry_net apt-get "${APT_OPTS[@]}" install -y python3-pip python3-venv unzip curl rsync
command -v rsync >/dev/null || { echo "BOOTSTRAP_FAILED: rsync unavailable — refusing to update a live host's code without atomic per-file publish"; exit 1; }
# awscli v2 (Ubuntu 24.04 has no apt awscli). The old guard was `command -v aws`, which accepted
# ANY aws — including a v1 from pip/apt on a pre-existing host, whose `s3api`/`ssm` behaviour and
# output differ. Require the v2 major explicitly; installing over an existing v2 is what
# `--update` is for, and this runs only when the major is wrong or aws is absent.
if ! aws --version 2>&1 | grep -q '^aws-cli/2\.'; then
  retry_net curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q -o awscliv2.zip && ./aws/install --update)
  rm -rf /tmp/aws /tmp/awscliv2.zip   # don't leave the installer tree on a host we re-bootstrap
fi
export PATH=/usr/local/bin:$PATH

# --- artifacts from S3 ---
# Download to $BIN.new and rename(2) into place. Writing straight to $BIN fails with ETXTBSY on a
# LIVE host — the resident `codegraph-server --mcp` sessions the bridges spawned are executing that
# exact file, and Linux refuses O_TRUNC on a running binary. That burned all 6 retry_net attempts
# and exited BOOTSTRAP_FAILED, i.e. the in-place re-bootstrap could never succeed while any project
# served. `mv` leaves running processes on the old inode and new spawns pick up the new one.
retry_net aws s3 cp "s3://$BUCKET/bin/codegraph-server" "$BIN.new" --region "$REGION"
chmod +x "$BIN.new"
# SMOKE-TEST the binary NOW (fail loud + early) instead of letting a wrong-arch /
# wrong-glibc / S3-truncated binary surface 10 min later as an opaque index-build
# health-gate timeout. A bad binary can't exec → `--version` fails → we exit with a
# greppable marker the SSM health probe / journalctl can pinpoint. Tested BEFORE it is
# published, so a bad download never replaces a working binary on a serving host.
"$BIN.new" --version >/dev/null 2>&1 || { rm -f "$BIN.new"; echo "BOOTSTRAP_FAILED: codegraph-server binary not executable (wrong arch/glibc or truncated S3 object)"; exit 1; }
mv -f "$BIN.new" "$BIN"
# Atomic symlink swap: `ln -sf` on an existing symlink is unlink-then-create, so a spawn landing in
# that window gets ENOENT. Create a temp link and rename it over the real one instead.
ln -sf "$BIN" /usr/local/bin/.codegraph-server.tmp && mv -Tf /usr/local/bin/.codegraph-server.tmp /usr/local/bin/codegraph-server

# --- index-service app code: STAGE → verify → publish ------------------------------------
# NEVER `tar xzf` straight over $APP on a live host. GNU tar truncates-and-rewrites each file in
# place, so (a) a refresh timer already executing $APP/glossary_refresh.sh keeps reading at its old
# byte offset in a file whose bytes changed underneath it and runs garbage, (b) http_bridge.py's
# lazy imports (file_read/file_search/glossary_read) load NEW module source into a process running
# OLD code, and (c) tar never deletes, so modules removed upstream linger and keep shadowing.
# Stage → verify → rsync publish fixes all three (see the header's "HOW AN IN-PLACE UPDATE STAYS
# SAFE"). NOT a versioned dir + symlink flip, which the reviewers preferred: $APP is a REAL
# directory on every already-live host and the units pointing at it are written by
# activate_project.sh, so turning it into a symlink cannot be done atomically from here and needs a
# coordinated migration in both files. Deferred on purpose rather than half-done.
retry_net aws s3 cp "s3://$BUCKET/index-service.tar.gz" /tmp/idx.tar.gz --region "$REGION"
APP_SIG="$(sha256sum /tmp/idx.tar.gz | cut -d' ' -f1)"
APP_STAGE=/opt/idx/stage/app
rm -rf "$APP_STAGE"; mkdir -p "$APP_STAGE"
tar xzf /tmp/idx.tar.gz -C "$APP_STAGE"
rm -f /tmp/idx.tar.gz
[ -f "$APP_STAGE/http_bridge.py" ] && [ -f "$APP_STAGE/requirements.txt" ] \
  || { rm -rf "$APP_STAGE"; echo "BOOTSTRAP_FAILED: staged index-service.tar.gz has no http_bridge.py/requirements.txt — refusing to publish a broken tree over the live one"; exit 1; }
rsync -a --delay-updates --delete-after "$APP_STAGE"/ "$APP"/
rm -rf "$APP_STAGE"
# Stamp OUTSIDE $APP so the --delete-after above can never eat it. Purely informational: it lets an
# operator (and /health) tell "code on disk" from "code the bridge loaded".
echo "$APP_SIG" > /opt/idx/.app_sig
# Bridges keep running the code they loaded. Say so, loudly and greppably — we do NOT restart them
# (activate_project.sh owns index-bridge-<projectId>; provision_index_service.sh owns stop/start
# around a re-bootstrap; see the header).
for _u in $(systemctl list-units --plain --no-legend --state=active 'index-bridge-*' 2>/dev/null | awk '{print $1}' || true); do
  echo "CODE_NEWER_THAN_RUNNING: $_u is live and still executing the PREVIOUS $APP code (on-disk app sig is now $APP_SIG). bootstrap.sh starts/stops nothing by design — its owner (activate_project.sh via deploy_project.sh, or provision_index_service.sh around a re-bootstrap) must cycle it."
done

# --- python deps -------------------------------------------------------------------------
# Both pip flags are DELIBERATELY kept, and both have real blast radius worth naming:
#   --break-system-packages installs into /usr/local/lib/python3.12/dist-packages, which SHADOWS
#     the apt-managed tree for EVERY python process on this host (cloud-init, unattended-upgrades,
#     the SSM-driven scripts themselves) — a transitive bump can in principle break the very SSM
#     path used to repair the host;
#   --ignore-installed skips the uninstall step, so a package directory is briefly half-old/
#     half-new while a resident bridge may lazily import from it.
# Dropping them is NOT the conservative choice: pip then tries to uninstall distutils-managed apt
# packages, fails outright, and the host ends up with no bridge deps at all. What we fix instead is
# running this at all — gate on the requirements hash plus a passing `pip check`, so a re-bootstrap
# that changes nothing never touches site-packages under the live bridges.
# DEFERRED (needs a coordinated migration): the real fix is a dedicated venv (/opt/idx/venv) with
# the bridge unit's ExecStart pointing into it. Those unit files are written by activate_project.sh,
# so the switch has to land in both files at once plus a one-time host migration; doing only this
# half would leave the bridges executing the system interpreter against venv-only deps.
REQ_SIG="$(sha256sum "$APP/requirements.txt" | cut -d' ' -f1)"
PIP_STAMP=/opt/idx/.reqs_sig
_pip_needed=1
if [ "$(cat "$PIP_STAMP" 2>/dev/null || echo none)" = "$REQ_SIG" ] && python3 -m pip check >/dev/null 2>&1; then
  echo "bootstrap: python deps already match requirements.txt ($REQ_SIG) and pip check passes — skipping install (no site-packages churn under live bridges)"
  _pip_needed=0
fi
if [ "$_pip_needed" -eq 1 ]; then
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
  # turns that into a loud, greppable bootstrap failure here — WITH the conflict text,
  # since "pin the transitive closure" is useless without knowing which pin.
  PIP_CHECK_OUT="$(python3 -m pip check 2>&1)" \
    || { echo "BOOTSTRAP_FAILED: pip dependency conflict (incompatible transitive deps) — pin the transitive closure in requirements.txt: ${PIP_CHECK_OUT}"; exit 1; }
  echo "$REQ_SIG" > "$PIP_STAMP"
fi

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
ripgrep_install() {
  command -v rg >/dev/null && return 0
  apt-get "${APT_OPTS[@]}" install -y ripgrep && return 0
  # Best-effort by design (the bridge still answers), but NOT silent: a missing rg degrades
  # search_files with no other signal anywhere, so leave a greppable marker in the log.
  echo "BOOTSTRAP_WARN: ripgrep install failed — the bridge's search_files tool will be degraded (answering otherwise unaffected)"
  return 0
}
ripgrep_install   # fast, .gitignore-aware search the bridge's file tools use

# --- Node + claude (cc) CLI: the build-time glossary engine -----------------------------
# The glossary builder (glossary_build.run_cc) shells out to a LOCAL `claude` CLI on THIS host
# to produce the Chinese-term -> code-symbol map (see docs/agent/glossary.md). Without it,
# glossary_refresh.sh / the initial full build fail with `claude: command not found` and the
# glossary SILENTLY stays empty (glossary_index degrades to [] — answering still works, the
# bridge never errors), so the gap is easy to miss. Install it here so a fresh host builds
# glossaries with zero manual setup. BEST-EFFORT: a failure here must NOT abort bootstrap —
# the index/bridge/gateway don't need cc, only the glossary does, and an empty glossary is a
# graceful degrade, not an outage. (Node is also installed by the gateway block below; this
# ensures it independently, since glossary needs cc even on a host with no gateway.)
NODE_MAJOR=24
ensure_node() {
  local cur
  cur="$(node -v 2>/dev/null | sed -n 's/^v\([0-9]\+\).*/\1/p' || true)"
  # Right major already present → no-op. The old guard accepted node at ANY version, so a host
  # that came with 18/20 never got 24 and `npm ci`/tsc failed obscurely later.
  [ "$cur" = "$NODE_MAJOR" ] && command -v node >/dev/null 2>&1 && return 0
  [ -n "$cur" ] && echo "bootstrap: node v${cur} present but v${NODE_MAJOR} required — upgrading"
  # Node 24 — same MAJOR as the agent container's CLI subprocess. Pin major only
  # (setup_24.x): NodeSource GCs old patch debs, so an exact patch pin breaks later.
  if retry_net curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesetup.sh \
    && bash /tmp/nodesetup.sh && retry_net apt-get "${APT_OPTS[@]}" install -y nodejs; then
    rm -f /tmp/nodesetup.sh
    return 0
  fi
  rm -f /tmp/nodesetup.sh
  # An upgrade failure must not abort a re-bootstrap on a host whose existing node is serving:
  # warn and carry on with what is installed. Only a host with NO node at all is a hard no.
  if [ -n "$cur" ]; then
    echo "BOOTSTRAP_WARN: node upgrade to v${NODE_MAJOR} failed — continuing with v${cur}"
    return 0
  fi
  return 1
}
# @latest (NOT pinned), matching agent-container/Dockerfile + the 2026-06-19 ops decision
# (AGENTS.md): take upstream fixes faster, trade reproducibility; check-versions.sh allows it.
# But do NOT reinstall it on every re-bootstrap: `npm install -g` replaces the CLI's global
# node_modules, and a detached glossary-build-* unit may be executing `claude` right now — that
# kills a multi-minute glossary build with MODULE_NOT_FOUND. Install only when absent; set
# REFRESH_CLAUDE_CLI=1 in /etc/index-service.env to force an upgrade on a quiet host.
if ensure_node && command -v npm >/dev/null 2>&1; then
  if command -v claude >/dev/null 2>&1 && [ "${REFRESH_CLAUDE_CLI:-0}" != "1" ]; then
    claude --version > /opt/idx/.claude_version 2>/dev/null || true
    echo "bootstrap: claude (cc) CLI already present ($(cat /opt/idx/.claude_version 2>/dev/null || echo '?')) — not reinstalling (would break an in-flight glossary build); set REFRESH_CLAUDE_CLI=1 to force"
  elif retry_net npm install -g @anthropic-ai/claude-code@latest; then
    claude --version > /opt/idx/.claude_version 2>/dev/null || true
    echo "bootstrap: claude (cc) CLI installed for glossary build: $(cat /opt/idx/.claude_version 2>/dev/null || echo '?')"
  else
    echo "bootstrap: WARN claude (cc) install failed — glossary will stay empty until cc is present (answering unaffected)"
  fi
else
  echo "bootstrap: WARN node/npm unavailable — skipping claude (cc) install; glossary will stay empty (answering unaffected)"
fi
cat > /etc/systemd/system/index-build@.service <<UNIT
[Unit]
Description=CodeGraph index build for repo %i (single-writer per graph)
After=network-online.target remote-fs.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
# NO build timeout. For Type=oneshot the whole ExecStart is bounded by DefaultTimeoutStartSec
# (90s on Ubuntu 24.04), after which systemd SIGTERMs the SOLE WRITER mid-RocksDB-write — the
# exact interrupted-writer path that produces the 0-node/quarantined graph this whole design
# exists to prevent. Today's builds fit in 90s, so this was latent; a bigger repo or a
# CPU-credit-throttled t4g crosses it. Deliberately no RuntimeMaxSec ceiling either: any finite
# cap has the same failure mode, just later.
TimeoutStartSec=infinity
# NO MemoryMax/MemoryHigh here either, deliberately. A cap on this unit makes the cgroup OOM-killer
# target the graph BUILD — the sole writer, mid-RocksDB-write — which is the corruption path the
# whole single-writer design exists to avoid; and there is no measured working-set to size a cap
# from, so any number picked here would turn builds that work today into killed writers. Bounding
# the build's memory needs a measured budget plus admission control comparing Σ MemoryMax against
# MemTotal at activation time (the units that would consume it are written by activate_project.sh),
# so it is recorded here rather than half-applied.
Environment=HOME=$LOCAL_REPO_ROOT/%i/.home
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# flock creates the lock FILE but not its parent dir; only activate_project.sh creates
# .codegraph, so a manual 'systemctl start index-build@<never-activated>' died with a bare
# "flock: No such file or directory".
ExecStartPre=/bin/mkdir -p $LOCAL_REPO_ROOT/%i/.codegraph
ExecStartPre=/bin/bash -c '[ -n "\$(ls -A $LOCAL_REPO_ROOT/%i 2>/dev/null)" ] || { echo "FATAL: $LOCAL_REPO_ROOT/%i is empty — refusing to build a 0-node graph"; exit 1; }'
# du EXCLUDES .git/.codegraph/.home: the sizing heuristic is about the SOURCE tree, and counting
# the existing graph + full git history inflated the estimate on every rebuild until it could
# refuse a build that would have fit fine.
ExecStartPre=/bin/bash -c 'need=\$(( \$(du -sk --exclude=.git --exclude=.codegraph --exclude=.home $LOCAL_REPO_ROOT/%i 2>/dev/null | cut -f1) * 5 / 2 + 1048576 )); avail=\$(df -Pk $INDEX_HOME | awk "NR==2{print \\\$4}"); [ "\${avail:-0}" -ge "\$need" ] || { echo "FATAL: insufficient $INDEX_HOME space for %i graph build: avail=\${avail}KiB need>=\${need}KiB"; exit 1; }'
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
# created in a LATER deploy phase. activate_gateway.sh writes /etc/bot-gateway-<projectId>.env
# and starts bot-gateway@<projectId> AFTER the runtime is ready (via SSM). On a REBOOT the
# unit (WantedBy=multi-user.target) restarts on its own — by then the env file
# persists on disk, so it comes straight back up.
#
# ON AN IN-PLACE RE-BOOTSTRAP the per-project gateways may already be RUNNING, and they all run
# from this ONE shared tree. So the build happens in a STAGING dir and only the finished result is
# published with rsync (per-file rename; open fds keep the old inode). Doing `npm ci` in $GW_APP
# itself — as this used to — DELETES node_modules wholesale in the working directory of every live
# bot-gateway@<projectId>, so the next lazy require() is MODULE_NOT_FOUND and Restart=always
# crash-loops another project's gateway. The old comment ("a running process keeps executing the
# dist it already loaded") is true for already-resolved modules and false for node_modules and
# lazy chunks — which is exactly what bit us.
# We still start NOTHING here (see RESTART OWNERSHIP in the header): activate_gateway.sh restarts
# its own project's unit afterwards. Never start a gateway from here — a second live process for
# the same Feishu app would steal the long-connection's events (a global singleton per app).
#
# Backend-only deploys (no gateway tarball staged) skip this gracefully.
GW_APP=/opt/bot-gateway
if aws s3api head-object --bucket "$BUCKET" --key bot-gateway.tar.gz --region "$REGION" >/dev/null 2>&1; then
  echo "setting up bot-gateway (build now, start later when runtime env is written)"
  ensure_node   # Node 24 (defined above for the cc install); no-op if already present
  mkdir -p "$GW_APP"
  retry_net aws s3 cp "s3://$BUCKET/bot-gateway.tar.gz" /tmp/gw.tar.gz --region "$REGION"
  # Content hash of the tarball — the SAME stamp activate_gateway.sh compares against to decide
  # whether to rebuild. Recorded (after a verified build, below) so the dist we just built is not
  # immediately rebuilt a second time by the activation that follows.
  GW_SRC_SIG="$(sha256sum /tmp/gw.tar.gz | cut -d' ' -f1)"
  # Serialize against activate_gateway.sh, which rebuilds this same shared tree for whichever
  # project is being deployed. Both take THIS lock and neither nests inside the other, so there is
  # no deadlock path. Wait rather than fail-fast (a delayed build beats a dead deploy), and on
  # timeout warn and proceed — refusing here could leave a host with no gateway dist at all.
  exec 9>/var/lock/source-truth-gw-build.lock
  flock -w 900 9 || echo "BOOTSTRAP_WARN: could not take /var/lock/source-truth-gw-build.lock within 900s — proceeding unserialized"
  GW_STAGE=/opt/bot-gateway.stage
  rm -rf "$GW_STAGE"; mkdir -p "$GW_STAGE"
  tar xzf /tmp/gw.tar.gz -C "$GW_STAGE"
  rm -f /tmp/gw.tar.gz
  # Install ALL deps (typescript/@types live in devDependencies and `npm run build`
  # = `tsc` needs them), compile TS → dist/, THEN prune devDeps so the resident
  # service runs on prod-only modules. A bare `npm ci --omit=dev` would skip tsc and
  # make `npm run build` fail with "tsc: not found" (cross-review HIGH).
  # All of it inside $GW_STAGE: the live tree is untouched until the build is verified.
  ( cd "$GW_STAGE" && retry_net npm ci && npm run build && npm prune --omit=dev ) \
    || { rm -rf "$GW_STAGE"; echo "BOOTSTRAP_FAILED: bot-gateway npm ci / build / prune failed"; exit 1; }
  # Sanity: the compiled entrypoint must exist, else the unit would crash-loop later. Checked in
  # STAGING, so a failed build never reaches the live tree.
  [ -f "$GW_STAGE/dist/index.js" ] || { rm -rf "$GW_STAGE"; echo "BOOTSTRAP_FAILED: bot-gateway build produced no dist/index.js"; exit 1; }
  chmod +x "$GW_STAGE/run.sh"
  # The gateway resolves card copy at __dirname/../../config/i18n.json — from
  # /opt/bot-gateway/dist that is /opt/config. The tarball ships config/ under the gateway
  # dir, so relocate it to /opt/config (parent of GW_APP) where the runtime path expects it.
  # rsync, NOT the old `rm -rf /opt/config; mv`: that left /opt/config ABSENT for EVERY project's
  # live gateway for as long as the mv took, and destroyed anything an operator had put there if
  # the mv then failed. An atomic `mv -T` is impossible for a non-empty directory, so publish
  # file-by-file instead — /opt/config is never missing at any instant.
  if [ -d "$GW_STAGE/config" ]; then
    mkdir -p /opt/config
    rsync -a --delay-updates --delete-after "$GW_STAGE/config"/ /opt/config/
    rm -rf "$GW_STAGE/config"
  fi
  # Publish the built tree. --exclude=/.src_sig so the stamp is governed only by the explicit
  # write below: if this sync is interrupted, the stale/absent stamp makes activate_gateway.sh
  # rebuild rather than trust a partial tree.
  rsync -a --delay-updates --delete-after --exclude=/.src_sig "$GW_STAGE"/ "$GW_APP"/
  rm -rf "$GW_STAGE"
  [ -f "$GW_APP/dist/index.js" ] || { echo "BOOTSTRAP_FAILED: bot-gateway dist/index.js missing after publish"; exit 1; }
  # Stamp ONLY after the build is verified AND published: if this bootstrap dies earlier, the
  # absent/old stamp makes activate_gateway.sh rebuild instead of trusting a half-installed tree.
  echo "$GW_SRC_SIG" > "$GW_APP/.src_sig"
  # Live gateways keep executing the dist they loaded. Name them (we restart nothing — see header).
  for _u in $(systemctl list-units --plain --no-legend --state=active 'bot-gateway@*' 2>/dev/null | awk '{print $1}' || true); do
    echo "CODE_NEWER_THAN_RUNNING: $_u is live and still executing the PREVIOUS gateway dist (on-disk gateway sig is now $GW_SRC_SIG). bootstrap.sh starts/stops nothing by design — activate_gateway.sh owns that project's unit, provision_index_service.sh owns stop/start around a re-bootstrap."
  done

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
# NODE_OPTIONS keeps V8's own heap ceiling BELOW the cgroup's: V8 does not read cgroup limits and
# sizes its heap from total host RAM (~4G here), so it would happily grow past MemoryMax and get
# SIGKILLed with no diagnostics. With --max-old-space-size=768 it throws a JS heap OOM with a
# stack trace first, which is debuggable and lands in the gateway log.
# Deliberately NO StartLimitBurst/StartLimitIntervalSec: tripping the start limiter leaves the
# gateway DOWN permanently, and a down gateway means the project takes no Feishu traffic at all —
# worse than a restart loop, which at least keeps trying and is visible in the log.
MemoryHigh=768M
MemoryMax=1G
OOMPolicy=stop
Environment=NODE_OPTIONS=--max-old-space-size=768
# Readiness probe. Two things this must get right, both of which a hard-coded
# 'http://127.0.0.1:18080/health' got wrong:
#   - PORT: the health port is per-project (bridge+10000), so 18080 is only correct for a
#     project whose bridge is 8080. activate_gateway.sh pins HEALTH_PORT in this instance's
#     env file; read it from there and skip the probe when it is absent.
#   - ROUTE: /health is LIVENESS and answers 200 as soon as the port is bound, which makes it
#     a vacuous gate. /ready is 200 only once the Feishu long-connection is actually up, which
#     is what "did this gateway come up" means.
# Every expansion below is \$-escaped so it survives into the unit and runs at START time. This
# heredoc is UNQUOTED (<<UNIT) so \$GW_APP interpolates, which also means an unescaped \$( ) or
# \${ } would be evaluated HERE, while writing the file: the previous version shipped literally
# p="" and probed http://127.0.0.1:/ready, i.e. the probe reported "HEALTH_PORT unset" and skipped
# on every gateway, forever, no matter what activate_gateway.sh wrote.
# Best-effort by construction: the loop always exits 0, so a slow connect warns but never marks
# the unit failed.
ExecStartPost=/bin/bash -c 'p="\$(. /etc/bot-gateway-%i.env 2>/dev/null; echo "\${HEALTH_PORT:-}")"; [ -n "\$p" ] || { echo "NOTE: HEALTH_PORT unset for %i — skipping readiness probe"; exit 0; }; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; curl -sf "http://127.0.0.1:\$p/ready" >/dev/null 2>&1 && exit 0; done; echo "WARN: gateway %i not ready after 10s (port \$p)"'
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo "bot-gateway@ template installed (per-project instances started by activate_gateway.sh)"
else
  echo "no bot-gateway.tar.gz staged — skipping gateway setup (backend-only deploy)"
fi

# --- CloudWatch agent: ship gateway log files + index-bridge journald to CloudWatch -------
# TOP-LEVEL, deliberately: this block used to live INSIDE the `bot-gateway.tar.gz` branch above,
# so a backend-only deploy (the documented case) never installed or reconfigured the agent even
# though half its job — shipping index-bridge-* journald — has nothing to do with the gateway. A
# host re-bootstrapped backend-only kept whatever stale config it had. The gateway file glob is
# harmless when no gateway exists (it simply matches nothing).
# Telemetry plan 阶段0 gate 2/3 + the monitoring plan's §0 front gate: the gateway's
# structured logs must reach a CloudWatch log group so Logs-Insights / metric-filters /
# dashboards can read them. The index instance role already has the logs perms (gate 1/3,
# provision_iam.sh cloudwatch-logs policy) SCOPED to /source-truth/* — so the log group
# name MUST start with that leading-slash prefix or every PutLogEvents AccessDenies.
# Best-effort: a CloudWatch-agent failure must NOT fail the bootstrap (the gateway and bridges
# still work; only telemetry shipping is degraded).
CW_CTL=/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
CW_CFG=/opt/aws/amazon-cloudwatch-agent/etc/cw-config.json
# VERSION: default "latest", overridable via CW_AGENT_VERSION in /etc/index-service.env (the URL
# path segment is either "latest" or an exact version). Left at "latest" rather than hard-pinned
# here because a pinned version must exist in EVERY regional bucket this deploys into, and there
# is nowhere in config today that records the chosen version — pinning belongs with that record.
# What matters more on a live host is not touching an agent that is already installed: dpkg -i
# runs the postinst, which RESTARTS the agent and gaps log shipping for every project on the box.
CW_WANT="${CW_AGENT_VERSION:-latest}"
CW_HAVE="$(dpkg-query -W -f='${Version}' amazon-cloudwatch-agent 2>/dev/null || echo none)"
if [ "$CW_HAVE" = none ] || { [ "$CW_WANT" != latest ] && [ "$CW_HAVE" != "$CW_WANT" ]; }; then
  CW_DEB=/tmp/amazon-cloudwatch-agent.deb
  if retry_net curl -fsSL "https://amazoncloudwatch-agent-${REGION}.s3.${REGION}.amazonaws.com/ubuntu/arm64/${CW_WANT}/amazon-cloudwatch-agent.deb" -o "$CW_DEB"; then
    # `apt-get install -f` on a SERVING host can install/remove arbitrary packages, so only reach
    # for it when dpkg actually left the package unconfigured.
    dpkg -i -E "$CW_DEB" || apt-get "${APT_OPTS[@]}" install -f -y || true
    rm -f "$CW_DEB"
    echo "cloudwatch-agent installed (was: $CW_HAVE, wanted: $CW_WANT)"
  else
    echo "WARN: cloudwatch-agent download failed — services run, telemetry shipping degraded"
  fi
else
  echo "cloudwatch-agent already installed (version $CW_HAVE, wanted $CW_WANT) — leaving it alone (a reinstall restarts the agent and gaps log shipping for every project on this host)"
fi
if [ ! -x "$CW_CTL" ]; then
  echo "WARN: cloudwatch-agent not present at $CW_CTL — telemetry shipping degraded (gateway + bridges unaffected)"
else
  mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
  # files.collect_list tails the gateway logs → /source-truth/bot-gateway (leading slash: matches
  # the IAM scope). instance-id in the stream name so hosts in different regions/accounts
  # sharing a log group don't interleave (and a re-bootstrap keeps writing the same stream).
  # SCHEMA: the journald section is "journald" with "units": [...] — the previous "journal" /
  # "unit": "..." spelling is not in the agent's config reference at all, so index-bridge logs
  # never reached CloudWatch while this script printed a success line claiming they did (and a
  # strict validation pass would have rejected the WHOLE document, taking gateway shipping with
  # it). retention_in_days stays here because this file is the single writer of that value for
  # both groups; moving ownership to `aws logs put-retention-policy` at provision time (the
  # reviewers' preference, and it avoids the agent halting on a divergent value) needs a
  # provision-side change to land first — deliberately not split across two owners here.
  cat > "${CW_CFG}.new" <<CWCFG
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
      },
      "journald": {
        "collect_list": [
          {
            "units": ["index-bridge-*"],
            "log_group_name": "/source-truth/index-bridge",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90
          }
        ]
      }
    }
  }
}
CWCFG
  # fetch-config RESTARTS the agent, so only run it when something actually changed or the agent
  # is not running — otherwise every re-bootstrap punches a log-shipping hole for all projects.
  if [ -f "$CW_CFG" ] && cmp -s "$CW_CFG" "${CW_CFG}.new" && "$CW_CTL" -a status 2>/dev/null | grep -q '"status": *"running"'; then
    rm -f "${CW_CFG}.new"
    echo "cloudwatch-agent config unchanged and agent running — skipping fetch-config (it would restart the agent)"
  else
    mv -f "${CW_CFG}.new" "$CW_CFG"
    # fetch-config (not append-config) so a re-run replaces, not duplicates, the input.
    if "$CW_CTL" -a fetch-config -m ec2 -s -c file:"$CW_CFG"; then
      # The ctl exit code is 0 even for a config the agent then fails to apply at runtime, which is
      # how the invalid journald keys above shipped a green message over a dead pipeline for months.
      # Verify the agent is actually RUNNING and say what its own log complains about if not. (Not
      # verified against the CloudWatch API here on purpose: logs:DescribeLogGroups is outside the
      # instance role's scoped policy, so an API check would print an AccessDenied that looks like
      # a telemetry failure when it isn't.)
      if "$CW_CTL" -a status 2>/dev/null | grep -q '"status": *"running"'; then
        echo "cloudwatch-agent shipping /var/log/bot-gateway*.log → /source-truth/bot-gateway + journald(index-bridge-*) → /source-truth/index-bridge"
      else
        echo "WARN: cloudwatch-agent accepted the config but is not running — telemetry shipping degraded. Agent log tail:"
        tail -20 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log 2>/dev/null || true
      fi
    else
      echo "WARN: cloudwatch-agent fetch-config failed — services run, telemetry shipping degraded"
    fi
  fi
fi

# --- log rotation for the EXPLICIT log files ---------------------------------------------
# journald-backed units are bounded by journald's own limits; every log this project writes with
# systemd `append:` or `tee -a` was not bounded by anything. /var/log/glossary-build-*.log alone
# is appended on every 300s refresh tick per repo, forever. On the 30GiB root volume that also
# holds every repo copy, its git history and every graph.db, disk exhaustion is the most likely
# first failure — and ENOSPC during a RocksDB write is exactly the interrupted-writer path the
# single-writer design exists to prevent.
# copytruncate is REQUIRED, not a style choice: systemd's `append:` and `tee` hold the fd open, so
# a plain rotate would leave them writing into the unlinked inode and the new file would stay
# empty. Written on every bootstrap (idempotent, content-identical).
cat > /etc/logrotate.d/source-truth <<'ROT'
/var/log/bot-gateway-*.log
/var/log/activate-project-*.log
/var/log/glossary-build-*.log
/var/log/reindex-*.log
/var/log/index-svc-bootstrap.log
{
  size 50M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}
ROT
echo "logrotate config written: /etc/logrotate.d/source-truth (size 50M, keep 5, copytruncate)"

echo "BOOTSTRAP_DONE"
