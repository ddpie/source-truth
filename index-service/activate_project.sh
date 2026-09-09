#!/usr/bin/env bash
# activate_project.sh — attach (or re-attach) ONE project to this index host. Idempotent.
# Invoked over SSM by deploy_project.sh; can run repeatedly and while OTHER projects serve.
#
# Why this is separate from bootstrap.sh: user-data (bootstrap) runs ONCE at first boot, so it
# cannot add/refresh a project on a running host. This script is the per-project unit of work —
# init-env leaves the host with zero projects, then each "add a project" calls this.
#
# Reads its inputs from the environment (deploy_project.sh sets them before invoking):
#   PROJECT_ID          this project's id  (^[a-z0-9-]+$)
#   REPO_MANIFEST_JSON  ONE project's repo set in ONE JSON value:
#       {"projectId":"<id>","port":<int>,
#        "repos":[{"subdir","git","ref"?,"refreshIntervalSec"?}, ...]}
#   GIT_SECRET_ID       (optional) Secrets Manager id of the read-only git credential (R-cred-1)
#   REGION, MAX_FILES   from the host's /etc/index-service.env (sourced below)
#
# SINGLE-WRITER (不变量2): each repo gets its own graph.db/HOME/flock under /data/repo/<subdir>.
# The build (index-build@<subdir>) and this project's resident bridge lock the SAME per-repo flock,
# so they never write one graph.db concurrently. The refresh path NEVER spawns codegraph — it only
# git-pulls; the bridge's file-watcher re-indexes in-place.
set -euo pipefail

# INPUT VALIDATION FIRST — before the log path, before any unit/filesystem path is built.
# PROJECT_ID and every SUBDIR are interpolated into unit names, /etc paths, log paths and (for
# orphan reconcile) an `rm -rf`. A value containing `/` or `..` would write unit files outside
# /etc/systemd/system or delete outside /data/repo. The contract is documented above as
# ^[a-z0-9-]+$; we require the stricter leading-alnum form used by reindex_local_repo.sh:34 so a
# leading dash can never be read as an option by systemctl/flock/rm.
: "${PROJECT_ID:?activate_project: PROJECT_ID required}"
printf '%s' "$PROJECT_ID" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
  || { echo "ACTIVATE_FAILED: invalid PROJECT_ID '$PROJECT_ID' (must match ^[a-z0-9][a-z0-9-]*$)"; exit 2; }

exec > >(tee -a "/var/log/activate-project-${PROJECT_ID}.log") 2>&1

: "${REPO_MANIFEST_JSON:?activate_project: REPO_MANIFEST_JSON required}"

# Capture a caller-passed (per-project) MODEL BEFORE sourcing the env file, which also defines
# MODEL (host-global) and would otherwise clobber the per-project value.
_PASSED_MODEL="${MODEL:-}"
_PASSED_SDK="${AGENT_SDK:-claude}"
_PASSED_GLOSSARY_ENABLED="${GLOSSARY_ENABLED:-}"

# shellcheck disable=SC1091
source /etc/index-service.env   # BUCKET, REGION, MAX_FILES, MODEL, GLOSSARY_ENABLED (written by provision)
# Per-project model (from projects.json via deploy_project) wins over the host-global env value.
[ -n "$_PASSED_MODEL" ] && MODEL="$_PASSED_MODEL"
AGENT_SDK="$_PASSED_SDK"
# Glossary on/off: the caller's value wins (deploy_project passes the persisted choice), else the
# host env, else on (older hosts without the key).
GLOSSARY_ENABLED="${_PASSED_GLOSSARY_ENABLED:-${GLOSSARY_ENABLED:-true}}"

APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
LOCAL_REPO_ROOT=/data/repo
RENDER_MANIFEST="$APP/render_manifest.py"

# repo_uses_git <source>: rc 0 if this repo is fetched via git (default), non-zero for local.
# Local repos are pushed to /data/repo/<subdir> out-of-band (scripts/push-local-repo.sh) and
# refreshed manually — no git_fetch, no refresh timer.
repo_uses_git() {
  [ "${1:-git}" != "local" ]
}

GIT_FETCH="$APP/git_fetch.sh"
GLOSSARY_REFRESH="$APP/glossary_refresh.sh"
[ -f "$RENDER_MANIFEST" ] || { echo "ACTIVATE_FAILED: render_manifest.py not in app bundle"; exit 1; }
[ -f "$GIT_FETCH" ]       || { echo "ACTIVATE_FAILED: git_fetch.sh not in app bundle"; exit 1; }
[ -f "$GLOSSARY_REFRESH" ] || { echo "ACTIVATE_FAILED: glossary_refresh.sh not in app bundle"; exit 1; }
# MODEL for the build-time cc engine. Precedence: a NON-EMPTY per-project model passed by
# deploy_project (from projects.json) wins; else the host-global MODEL from index-service.env;
# else the project default (so an older env file without MODEL still works). `source` above may
# have set MODEL from the env file; an explicitly-passed empty MODEL='' must NOT blank it.
: "${MODEL:=}"
[ -n "$MODEL" ] || MODEL="global.anthropic.claude-opus-4-8"
# Glossary off ⇒ EMPTY model: skips the initial build below and makes the refresh timer pull-only.
[ "$GLOSSARY_ENABLED" != "false" ] || MODEL=""
[ -x "$BIN" ]             || { echo "ACTIVATE_FAILED: codegraph-server not installed (run bootstrap first)"; exit 1; }

mkdir -p /etc/index-projects "$LOCAL_REPO_ROOT"
MANIFEST="/etc/index-projects/${PROJECT_ID}.json"

# PER-PROJECT ENV for the generated units. The refresh unit's ExecStart reads $MODEL at run time,
# and with only EnvironmentFile=/etc/index-service.env that resolved to the HOST-GLOBAL model —
# so a project with a per-project model override built its initial glossary with one model and
# every incremental refresh with another, silently. Write the RESOLVED per-project value here and
# load it AFTER the host-global file in each unit (last EnvironmentFile wins).
# An env file (not interpolation into ExecStart) on purpose: no quoting/word-splitting hazard for
# a model id or an inference-profile ARN, matching why the git url/ref are also read at run time.
PROJECT_ENV="/etc/index-project-${PROJECT_ID}.env"
AGENT_SDK="${AGENT_SDK:-claude}"
case "$AGENT_SDK" in openai|claude) ;; *) echo "ACTIVATE_FAILED: invalid AGENT_SDK"; exit 2 ;; esac
GLOSSARY_PYTHON=python3
if [[ "$AGENT_SDK" == "openai" && "$GLOSSARY_ENABLED" != "false" ]]; then
  GLOSSARY_PYTHON="$(bash "$APP/setup_glossary.sh" "$APP")"
fi
GLOSSARY_SUBDIRS="$(printf '%s' "$REPO_MANIFEST_JSON" \
  | python3 "$RENDER_MANIFEST" --field subdir /dev/stdin | paste -sd,)"
PROJECT_ENV_STAGE="$(mktemp "${PROJECT_ENV}.XXXXXX")"
printf 'MODEL=%s\nREGION=%s\nAGENT_SDK=%s\nGLOSSARY_ENABLED=%s\nGLOSSARY_PYTHON=%s\nGLOSSARY_CONFIG_FILE=%s\nGLOSSARY_MAX_FILES=%s\nGLOSSARY_SUBDIRS=%s\n' \
  "$MODEL" "$REGION" "$AGENT_SDK" "$GLOSSARY_ENABLED" "$GLOSSARY_PYTHON" "$PROJECT_ENV" \
  "${GLOSSARY_MAX_FILES:-0}" "$GLOSSARY_SUBDIRS" > "$PROJECT_ENV_STAGE"
if ! cmp -s "$PROJECT_ENV_STAGE" "$PROJECT_ENV"; then
  # Stop old workers before replacing the selection. Builds cannot publish after
  # this returns; unrelated projects remain running.
  systemctl stop "glossary-build-${PROJECT_ID}-*.service" 2>/dev/null || true
  if [ -f "$MANIFEST" ]; then
    for old_subdir in $(python3 "$RENDER_MANIFEST" --field subdir "$MANIFEST"); do
      systemctl stop "index-refresh-${old_subdir}.service" 2>/dev/null || true
    done
  fi
fi
(
  flock 9
  mv "$PROJECT_ENV_STAGE" "$PROJECT_ENV"
) 9>"$PROJECT_ENV.lock"
chmod 644 "$PROJECT_ENV"
# Capture the project's PREVIOUS subdirs BEFORE overwriting the manifest — the authoritative
# "what this project owned last time" set for orphan reconcile (independent of timers/slices,
# which may not exist for local repos or on a no-glossary-engine host).
# Explicit `if` (NOT `[ -f ] && OLD_SUBDIRS=...`): the && form's exit code on a first activate
# (no manifest yet) is non-zero, and as a bare statement that can trip `set -e` on some readings.
OLD_SUBDIRS=""
if [ -f "$MANIFEST" ]; then
  # A present-but-unparseable old manifest would silently yield an empty set → orphan cleanup
  # skipped (leaking repo copies / glossary slices). Warn loudly so it's not invisible; the prior
  # manifest was written by us and should always parse, so this is a "should never happen" tripwire.
  if ! OLD_SUBDIRS="$(python3 "$RENDER_MANIFEST" --field subdir "$MANIFEST" 2>/dev/null)"; then
    echo "WARN: existing manifest $MANIFEST did not parse — orphan reconcile may miss removed repos"
    OLD_SUBDIRS=""
  fi
fi
printf '%s' "$REPO_MANIFEST_JSON" > "$MANIFEST"

# Validate with the SHIPPED parser; fail loud before touching any repo/unit.
SUBDIRS="$(python3 "$RENDER_MANIFEST" --field subdir "$MANIFEST")" \
  || { echo "ACTIVATE_FAILED: invalid REPO_MANIFEST_JSON for $PROJECT_ID"; exit 1; }
MANIFEST_PID="$(python3 "$RENDER_MANIFEST" --field projectId "$MANIFEST")"
[ "$MANIFEST_PID" = "$PROJECT_ID" ] || { echo "ACTIVATE_FAILED: manifest projectId '$MANIFEST_PID' != '$PROJECT_ID'"; exit 1; }
BRIDGE_PORT="$(python3 "$RENDER_MANIFEST" --field port "$MANIFEST")" \
  || { echo "ACTIVATE_FAILED: manifest missing/invalid port"; exit 1; }
SERVE_ARGS="$(python3 "$RENDER_MANIFEST" --serve-args "$LOCAL_REPO_ROOT" "$MANIFEST")" \
  || { echo "ACTIVATE_FAILED: could not render serve args"; exit 1; }

# --- git credential (R-cred-1): one read-only token, fetched HOST-SIDE, never via SSM body ------
# Written to a 0600 EnvironmentFile + a 0700 askpass helper that the build/refresh units source.
# PER-PROJECT PATHS (was host-global /opt/idx/git-token + /etc/index-git.env): with one shared
# path, activating project B overwrote project A's token — A's refreshes then either failed or,
# worse, presented B's credential to A's git host. Cross-project credential substitution on a host
# whose whole point is per-project logical isolation. Each project now owns its own token file,
# askpass helper and env file, named by projectId (charset-validated at the top of this script).
# The legacy host-global files are intentionally NOT written and NOT deleted: another project's
# units, generated before this change, still reference /etc/index-git.env, and leaving that file
# alone keeps their token stable until their own re-activation regenerates them.
GIT_TOKEN_FILE="/opt/idx/git-token-${PROJECT_ID}"
GIT_ASKPASS_FILE="/opt/idx/git-askpass-${PROJECT_ID}.sh"
GIT_ENV_FILE="/etc/index-git-${PROJECT_ID}.env"
if [ -n "${GIT_SECRET_ID:-}" ]; then
  GIT_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$GIT_SECRET_ID" \
    --query SecretString --output text 2>/dev/null || echo "")"
  if [ -n "$GIT_TOKEN" ]; then
    # The askpass helper is STATIC (cats a separate token file) — the token is never interpolated
    # into a script, so a token containing "/$/backtick can't break out or be command-substituted.
    # Both files are created under `umask 077` (created restricted from the start — no chmod-after-
    # write window where the token file is briefly world-readable). The token file holds ONLY the
    # raw token; the askpass + env file hold no secret.
    ( umask 077; printf '%s' "$GIT_TOKEN" > "$GIT_TOKEN_FILE" )
    ( umask 077; printf '#!/bin/sh\nexec cat %s\n' "$GIT_TOKEN_FILE" > "$GIT_ASKPASS_FILE" )
    chmod 700 "$GIT_ASKPASS_FILE"
    ( umask 077; printf 'GIT_ASKPASS=%s\nGIT_TERMINAL_PROMPT=0\n' "$GIT_ASKPASS_FILE" > "$GIT_ENV_FILE" )
    export GIT_ASKPASS="$GIT_ASKPASS_FILE" GIT_TERMINAL_PROMPT=0
    unset GIT_TOKEN
  else
    echo "WARN: GIT_SECRET_ID set but secret empty/unreadable — clone works only for public repos"
  fi
fi

# --- clone each repo + build its graph + write a concrete per-repo refresh unit+timer ----------
BUILD_UNITS=""
SERVE_FLOCKS=""
# Local repos whose code hasn't been pushed yet: "装服务" stands up the bridge/runtime/gateway now
# and DEFERS the graph build to the first `scripts/push-local-repo.sh`. Tracked here so the build
# loop + initial glossary build skip them (they'd otherwise fail / waste a Bedrock precheck on an
# empty dir). The bridge still serves them (empty, unhealthy) until the first push builds the graph.
DEFERRED_SUBDIRS=""
while IFS= read -r SUBDIR; do
  : "${SUBDIR:?ACTIVATE_FAILED: empty subdir (refusing git op on repo root)}"
  # Same guard as PROJECT_ID: SUBDIR lands in unit names (index-build@, index-refresh-), in $WS
  # under /data/repo, and in the reconcile `rm -rf`. render_manifest.SUBDIR_RE already enforces
  # this charset when parsing the manifest — repeated here so the shell never builds a path from
  # an unvalidated value (same pattern, byte for byte, so nothing that parses can fail here).
  printf '%s' "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
    || { echo "ACTIVATE_FAILED: invalid subdir '$SUBDIR' (must match ^[a-z0-9][a-z0-9-]*$)"; exit 2; }
  WS="$LOCAL_REPO_ROOT/$SUBDIR"
  SRC="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST" 2>/dev/null || echo git)"
  [ -n "$SRC" ] && [ "$SRC" != "None" ] || SRC=git
  if repo_uses_git "$SRC"; then
    GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" "$MANIFEST")" \
      || { echo "ACTIVATE_FAILED: no git url for $SUBDIR"; exit 1; }
    GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" "$MANIFEST" || echo "")"
    IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" "$MANIFEST" 2>/dev/null || echo "")"
    [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300
    bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
      || { echo "ACTIVATE_FAILED: git fetch $SUBDIR"; exit 1; }
  else
    # LOCAL source: code is pushed out-of-band to $WS by scripts/push-local-repo.sh (+ host-side
    # reindex_local_repo.sh). If it hasn't landed yet, DON'T fail — "装服务" should still stand up
    # the bridge/runtime/gateway; the graph build is deferred to the first push (reindex's first-push
    # path does the full build). Mark it deferred so the build + initial-glossary loops skip it.
    mkdir -p "$WS"
    if [ -z "$(ls -A "$WS" 2>/dev/null)" ]; then
      echo "activate: local repo '$SUBDIR' has no code yet — deferring graph build to first push (scripts/push-local-repo.sh)"
      DEFERRED_SUBDIRS="$DEFERRED_SUBDIRS $SUBDIR"
    else
      echo "activate: $SUBDIR is a LOCAL repo (no git fetch, no refresh timer)"
    fi
  fi
  # graph dirs INSIDE $WS (proven layout); created after fetch/push, git-untracked so reset --hard keeps them.
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"

  BUILD_UNITS="$BUILD_UNITS index-build@${SUBDIR}.service"
  # -w 300 -E 75: the serve-side flock chain used to be UNBOUNDED. With Type=simple, a bridge
  # parked forever in `flock` is reported by systemd as active(running) while it has never bound
  # its port — the exact opaque "healthy unit, dead endpoint" failure this codebase works to avoid.
  # A bounded wait turns that into a loud, greppable failure (exit status=75 in the journal) and
  # Restart=always retries, so a build that legitimately holds the writer lock longer than 300s
  # still converges — it just no longer hides. -w 300 (not 120): a first-push graph build on a
  # large repo runs minutes, and failing while the sole writer is doing its job would be noise.
  SERVE_FLOCKS="$SERVE_FLOCKS /usr/bin/flock -w 300 -E 75 $WS/.codegraph/.writer.lock"

  # Concrete refresh unit + timer — ONLY for git repos (local repos refresh manually via re-push).
  # ExecStart re-reads git url/ref from THIS project's manifest at run time (via render_manifest
  # --repo-field) rather than baking them into the unit text: that (a) preserves an EMPTY ref
  # correctly — git_fetch treats "" as "default branch" — instead of an unquoted empty systemd arg
  # collapsing and shifting the positional args; and (b) keeps the git URL/ref out of the ExecStart
  # line, so a value with whitespace or a leading dash can't become an extra/option arg. The whole
  # command is one `bash -c` so the $(...) lookups run on the host. The refresh runs
  # glossary_refresh.sh, which (a) does the authoritative git pull (its exit code fails the unit on
  # a bad pull), then (b) rebuilds THIS repo's glossary slice incrementally (best-effort).
  if repo_uses_git "$SRC"; then
  cat > "/etc/systemd/system/index-refresh-${SUBDIR}.service" <<UNIT
[Unit]
Description=Scheduled git pull + glossary refresh for repo ${SUBDIR}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-/etc/index-git.env
# Per-project git credential (see the GIT_TOKEN_FILE block above). Loaded AFTER the legacy
# host-global file so it wins where it exists, while a host that still only has the old shared
# file keeps working until its projects are re-activated.
EnvironmentFile=-${GIT_ENV_FILE}
EnvironmentFile=-/etc/index-service.env
# AFTER the host-global file so the per-project MODEL/REGION win (last EnvironmentFile wins).
EnvironmentFile=-${PROJECT_ENV}
# Cheap hardening. NOT PrivateTmp: glossary_refresh.sh hands /tmp change-list paths to a DETACHED
# systemd-run unit, which would not see this unit's private /tmp — the refresh would silently
# stop finding its own change lists. NOT ProtectSystem=strict either: this unit git-writes the
# worktree and reads the token helper under /opt/idx, so it needs a ReadWritePaths audit first.
NoNewPrivileges=true
ExecStart=/bin/bash -c 'GU="\$(python3 $RENDER_MANIFEST --repo-field git ${SUBDIR} ${MANIFEST})"; GR="\$(python3 $RENDER_MANIFEST --repo-field ref ${SUBDIR} ${MANIFEST})"; exec $GLOSSARY_REFRESH ${SUBDIR} "\$GU" "\$GR" ${WS} ${PROJECT_ID} "\$MODEL" "\$REGION"'
UNIT
  cat > "/etc/systemd/system/index-refresh-${SUBDIR}.timer" <<UNIT
[Unit]
Description=Refresh timer for repo ${SUBDIR}
[Timer]
OnBootSec=${IV}s
OnUnitActiveSec=${IV}s
Unit=index-refresh-${SUBDIR}.service
[Install]
WantedBy=timers.target
UNIT
  fi
done <<< "$SUBDIRS"

# --- this project's CONCRETE resident bridge unit (index-bridge-<projectId>) -------------------
# A concrete unit (not the @ template) because SERVE_FLOCKS is a variable-length chain of flock
# prefixes that can't be carried in a systemd specifier. Serves ONLY this project's repos on its
# OWN port → project A's process has no handle to project B's graph (A 档逻辑隔离).
#
# MEMORY SIZING (was a flat MemoryMax=2G for every project). The bridge's cgroup contains python3
# PLUS ONE resident `codegraph-server --mcp` child PER REPO, and when a cgroup hits MemoryMax the
# kernel's cgroup OOM killer picks the LARGEST task in it — which is a codegraph-server, i.e. the
# single writer holding graph.db open read-write. A flat 2G therefore made the writer the
# designated victim on any multi-repo project: the mitigation caused the #1 documented failure
# (interrupted writer → 0-node graph). Size the cap by repo count instead so the limit is a real
# ceiling rather than a routine one.
REPO_COUNT="$(printf '%s\n' "$SUBDIRS" | grep -c . || true)"
[ "${REPO_COUNT:-0}" -ge 1 ] || REPO_COUNT=1
# 768M per repo graph + 512M python/overhead, floor 2G so a single-repo project keeps today's cap.
BRIDGE_MEM_MB=$(( 512 + REPO_COUNT * 768 ))
[ "$BRIDGE_MEM_MB" -ge 2048 ] || BRIDGE_MEM_MB=2048
# HOST BUDGET WARNING (no admission control — refusing an activation on a live host would be worse
# than over-committing it). Σ of this project's new cap + every OTHER project's bridge cap vs
# MemTotal; the gateway units add ~1G each on top, so warn at 70%.
MEM_TOTAL_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
  OTHER_MB=0
  for u in /etc/systemd/system/index-bridge-*.service; do
    [ -f "$u" ] || continue
    case "$u" in */index-bridge-${PROJECT_ID}.service) continue ;; esac
    # Existing units may carry either suffix (this script wrote MemoryMax=2G before the sizing
    # change and writes <n>M now) — normalize both to MiB, else a legacy unit counts as 0 and the
    # sum silently understates the host's commitment.
    m="$(awk -F= '/^MemoryMax=/{v=$2; if (v ~ /G$/) {sub(/G$/,"",v); v=v*1024} else sub(/M$/,"",v); print int(v)}' "$u" | tail -1)"
    OTHER_MB=$(( OTHER_MB + ${m:-0} ))
  done
  SUM_MB=$(( BRIDGE_MEM_MB + OTHER_MB ))
  if [ "$SUM_MB" -gt $(( MEM_TOTAL_MB * 70 / 100 )) ]; then
    echo "WARN: bridge memory ceilings sum to ${SUM_MB}MiB on a ${MEM_TOTAL_MB}MiB host (>70%)."
    echo "WARN: bot-gateway units add ~1GiB each, and index-build@/glossary-build are on top of"
    echo "WARN: that — a host-wide OOM here can kill ANOTHER project's codegraph writer."
    echo "WARN: move a project off this host or use a larger instance type."
  fi
fi
cat > "/etc/systemd/system/index-bridge-${PROJECT_ID}.service" <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge for project ${PROJECT_ID} (resident)
After=network-online.target remote-fs.target${BUILD_UNITS}
Wants=network-online.target${BUILD_UNITS}
# Wants= (NOT Requires=) is deliberate: a failed build must not block the bridge, because a bridge
# that serves an empty graph still answers /health 503 and recovers via the watcher, whereas a
# bridge that never starts takes the project offline. bootstrap.sh's header comment says
# After=/Requires=; the code here is the intended semantics and the comment is the stale half.
# Bounded restart loop: without this, a genuine over-cap (or any crash-on-start) restarts every
# 5s FOREVER, SIGKILLing the RocksDB writer on every cycle. 5 attempts / 300s is generous enough
# that ordinary restarts never trip it; when it does trip, the unit stays failed and loudly says
# so instead of grinding the graph. Recovery: systemctl reset-failed + start (a re-activate does
# the reset-failed itself, below).
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Environment=HOME=/data
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=${MAX_FILES}
WorkingDirectory=${APP}
# --host 0.0.0.0 IS LEFT AS-IS, DELIBERATELY (reviewed, not overlooked). The AgentCore runtime
# reaches this bridge over the VPC by private IP (Route53 private zone
# index.<region>.source-truth.internal → the instance's PrivateIpAddress), so a private-IP bind
# would satisfy the runtime — but uvicorn binds ONE address, and the loopback probe
# (curl 127.0.0.1:<port>/health, used by the runbook and by ops) is load-bearing, so a
# private-IP-only bind would break it. Baking the private IP into this generated unit would also
# make the bridge fail to start with EADDRNOTAVAIL if the ENI/IP ever changes — worse than the
# exposure it removes. The real fix is authentication (there is none today; the security group is
# the only control) which needs a matching change in the agent's MCP client. Follow-up, not here.
ExecStart=${SERVE_FLOCKS} /usr/bin/python3 -m http_bridge ${SERVE_ARGS} --host 0.0.0.0 --port ${BRIDGE_PORT} --mount-root "" --project ${PROJECT_ID}
Restart=always
RestartSec=5
# OOM ISOLATION: cap bridge memory so a leak restarts this project's bridge (OOMPolicy=stop)
# rather than letting it push the host into a global OOM that could kill ANOTHER project's
# codegraph writer. Sized above from the repo count, floor 2G.
# NO MemoryHigh: under cgroup v2 the page cache is charged to the cgroup, so reading a few hundred
# MiB of graph.db drove the cgroup to MemoryHigh on CACHE ALONE and the kernel throttled it into
# direct reclaim — a latency brownout with /health still 200 and no alarm. Cache is reclaimable, so
# MemoryMax alone cannot OOM on cache; dropping the soft limit removes the brownout without
# weakening the ceiling.
MemoryMax=${BRIDGE_MEM_MB}M
OOMPolicy=stop
# FOLLOW-UP (needs a change outside this script): the cgroup OOM killer still picks the largest
# task, i.e. a codegraph-server child, not the python parent. Making the parent the victim needs
# each codegraph child in its own child cgroup/scope with its own MemoryMax — that is a
# codegraph_session.py change, and OOMScoreAdjust= here cannot express it (children inherit it).
# HARDENING. Cheap, no migration: no privilege escalation, read-only filesystem except the data
# root, no /home or /root visibility, private /tmp. ReadWritePaths=/data covers every path the
# bridge writes (graph.db + HOME=/data + the per-repo flocks under /data/repo); /data/glossary is
# read-only for the glossary tools and is inside it. Bytecode caching under /opt/idx/app becomes a
# silent no-op (read-only) — startup only.
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/data
ProtectHome=true
PrivateTmp=true
# NOT DONE (needs a host migration, deliberately left): running as a dedicated unprivileged user.
# It requires re-owning /data/repo/*, every .codegraph/.home graph dir and /data/glossary on all
# existing hosts, plus matching changes in index-build@/glossary-build/reindex, so it cannot ride
# along with a unit-file edit. Track separately.
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Build each repo (sole writer per graph) BEFORE starting the bridge. If the bridge is already
# running (re-activate), stop it first so the build's `flock -n` can take the writer lock.
systemctl stop "index-bridge-${PROJECT_ID}.service" 2>/dev/null || true
# From here on the project is OFFLINE. Any non-zero exit (a failed build, or an unexpected error
# under `set -e`) previously left it that way: a re-activate that hit one bad repo took a
# previously-healthy project down. reindex_local_repo.sh:216 already handles this correctly; mirror
# it with a trap so EVERY failure path — not just the build check below — brings the bridge back.
# Cleared with `trap - EXIT` once the bridge is started for real.
restore_bridge_on_abort() {
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "ACTIVATE_ABORTED (rc=$rc): restarting index-bridge-${PROJECT_ID} so the project keeps serving"
  systemctl reset-failed "index-bridge-${PROJECT_ID}.service" 2>/dev/null || true
  systemctl start "index-bridge-${PROJECT_ID}.service" 2>/dev/null || true
}
trap restore_bridge_on_abort EXIT
DEFERRED_MEMBER=" ${DEFERRED_SUBDIRS# } "   # space-delimited membership test (quoted: no globbing)
for SUBDIR in $SUBDIRS; do
  # A deferred (empty local) repo has no code to index yet — skip its build. The bridge starts and
  # serves it empty (unhealthy) until the first `push-local-repo.sh` runs the full build.
  case "$DEFERRED_MEMBER" in *" $SUBDIR "*)
    echo "activate: skipping graph build for '$SUBDIR' (no code yet — deferred to first push)"
    continue ;;
  esac
  systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
  # `restart`, NOT `start`: index-build@ is Type=oneshot + RemainAfterExit=yes, so once it has run
  # in this boot it stays active(exited) and `start` is a NO-OP — the graph was never rebuilt, and
  # the Result= read below returned the PREVIOUS run's `success`, so a re-activate silently skipped
  # the rebuild and reported it as done. reindex_local_repo.sh:207 documents the same trap.
  systemctl restart "index-build@${SUBDIR}.service" || true
  R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
  if [ "$R" != "success" ]; then
    echo "ACTIVATE_FAILED: index-build@${SUBDIR} Result=$R"
    journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -40 || true
    exit 1
  fi
done

# RECONCILE (old-manifest-driven): orphans = OLD_SUBDIRS − current SUBDIRS. Authoritative and
# source-agnostic — works for local repos (no timer) AND on hosts with no glossary engine (no
# slice). A timer-driven loop would never see a removed LOCAL repo (it has no timer) and would leak
# its repo copy + glossary slice forever (glossary_read globs every <sub>.jsonl unconditionally).
# Tear down each orphan's refresh unit (git repos only; disable is a no-op for local), its glossary
# slice + lock, and its on-disk repo copy + graph.
CUR_SUBDIRS=" ${SUBDIRS//$'\n'/ } "   # space-delimited membership test (quoted: no globbing)
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
PROJ_GLOSS_DIR="$GLOSSARY_ROOT/$PROJECT_ID"
# CROSS-PROJECT CLAIM CHECK. /data/repo/<subdir> and the index-refresh-<subdir> units are a
# HOST-GLOBAL namespace while manifests are per-project, so if projects A and B both declare subdir
# `foo` and A drops it, A's reconcile would `rm -rf /data/repo/foo` — deleting B's graph.db and
# .home while B's bridge holds them open read-write — and disable the timer B still needs.
# Full isolation means namespacing the path by project (/data/repo/<projectId>/<subdir>), which is a
# host migration (every existing repo copy, graph, unit and manifest moves); NOT done here. What is
# safe now: never destroy shared state, and say so loudly when a subdir is shared.
# Prints the other manifest's path on stdout; rc 0 = claimed elsewhere.
subdir_claimed_elsewhere() {  # $1 = subdir
  local sub="$1" m
  for m in /etc/index-projects/*.json; do
    [ -f "$m" ] || continue
    [ "$m" = "$MANIFEST" ] && continue
    if python3 "$RENDER_MANIFEST" --field subdir "$m" 2>/dev/null | grep -qxF "$sub"; then
      echo "$m"
      return 0
    fi
  done
  return 1
}

for sub in $OLD_SUBDIRS; do
  case "$CUR_SUBDIRS" in *" $sub "*) continue ;; esac   # still current → keep
  if OWNER_M="$(subdir_claimed_elsewhere "$sub")"; then
    echo "reconcile: repo '$sub' removed from project $PROJECT_ID but STILL CLAIMED by $OWNER_M —"
    echo "reconcile: keeping /data/repo/$sub + index-refresh-$sub (another project serves it);"
    echo "reconcile: dropping only this project's glossary slice."
    rm -f "$PROJ_GLOSS_DIR/${sub}.jsonl" "$PROJ_GLOSS_DIR/${sub}.jsonl.meta" \
      "$PROJ_GLOSS_DIR/${sub}.jsonl.pending" "$PROJ_GLOSS_DIR/.${sub}.lock" 2>/dev/null || true
    continue
  fi
  echo "reconcile: repo '$sub' removed from project $PROJECT_ID — tearing down unit + slice + repo copy"
  systemctl disable --now "index-refresh-${sub}.timer" 2>/dev/null || true
  systemctl reset-failed "index-refresh-${sub}.timer" "index-refresh-${sub}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/index-refresh-${sub}.service" "/etc/systemd/system/index-refresh-${sub}.timer" 2>/dev/null || true
  rm -f "$PROJ_GLOSS_DIR/${sub}.jsonl" "$PROJ_GLOSS_DIR/${sub}.jsonl.meta" \
    "$PROJ_GLOSS_DIR/${sub}.jsonl.pending" "$PROJ_GLOSS_DIR/.${sub}.lock" 2>/dev/null || true
  rm -rf "$LOCAL_REPO_ROOT/${sub}" "$LOCAL_REPO_ROOT/${sub}.incoming" "$LOCAL_REPO_ROOT/${sub}.bridge.lock" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

# SHARED-SUBDIR TRIPWIRE for the repos this project keeps. Two projects declaring the same subdir
# point two bridges at the SAME /data/repo/<subdir>/graph.db; http_bridge's per-workspace singleton
# lock makes the second bridge exit rather than corrupt it, so the symptom is a crash-looping
# project, not a corrupt graph — but nothing else says why. Warn; do not refuse (refusing would
# take a currently-serving project down over a pre-existing condition).
for SUBDIR in $SUBDIRS; do
  if OWNER_M="$(subdir_claimed_elsewhere "$SUBDIR")"; then
    echo "WARN: subdir '$SUBDIR' is ALSO declared by $OWNER_M — /data/repo/$SUBDIR (graph.db, .home,"
    echo "WARN: refresh unit) is shared between projects. Expect one bridge to fail its singleton"
    echo "WARN: writer lock. Give each project its own subdir name."
  fi
done

# reset-failed BEFORE starting: StartLimitBurst on the bridge unit means a prior crash loop can
# leave the unit in `failed` with the start limiter tripped, where `start` refuses. A re-activate
# must always be able to bring the project back up.
systemctl reset-failed "index-bridge-${PROJECT_ID}.service" 2>/dev/null || true
systemctl enable --now "index-bridge-${PROJECT_ID}.service"
# The project is serving again — stop restoring it on exit.
trap - EXIT
for SUBDIR in $SUBDIRS; do
  SRC="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST" 2>/dev/null || echo git)"
  if ! repo_uses_git "${SRC:-git}"; then
    # Local repo: no git timer. If this subdir was PREVIOUSLY a git source, a stale
    # index-refresh-<sub>.timer would keep git-pulling a dir that no longer has a remote and fail
    # forever — so tear it down here (idempotent; a no-op when there was never a timer). This makes
    # a git→local source flip converge, not just a full repo removal (which reconcile above handles).
    systemctl disable --now "index-refresh-${SUBDIR}.timer" 2>/dev/null || true
    systemctl reset-failed "index-refresh-${SUBDIR}.timer" "index-refresh-${SUBDIR}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/index-refresh-${SUBDIR}.service" "/etc/systemd/system/index-refresh-${SUBDIR}.timer" 2>/dev/null || true
    echo "activate: local repo $SUBDIR — no refresh timer (removed any stale git timer)"
    continue
  fi
  systemctl enable --now "index-refresh-${SUBDIR}.timer"
done
systemctl daemon-reload 2>/dev/null || true

# Initial FULL glossary build per repo. Detached + best-effort: a full cc scan can take minutes
# (build-time engine on Bedrock), and the bridge already serves an EMPTY glossary until the slice
# lands (glossary_index degrades to []), so activation must NOT block on it. Each repo writes its
# own slice (<subdir>.jsonl). Subsequent refreshes go incremental via the per-repo timer.
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
# IDEMPOTENCE: activate_project.sh re-runs on every (re)deploy. Only repos with NO existing
# non-empty slice need the initial FULL build — a repo already built keeps current via its refresh
# timer (incremental). This avoids re-spending a full cc scan + a Bedrock precheck token on every
# idempotent re-activation, and avoids re-blanking a working slice.
NEED_BUILD=""
for SUBDIR in $SUBDIRS; do
  # Skip deferred (empty local) repos: no code → a cc scan finds nothing and would waste a Bedrock
  # precheck + write an empty slice. The first push builds the graph AND refreshes the glossary.
  case "$DEFERRED_MEMBER" in *" $SUBDIR "*) continue ;; esac
  SLICE="$GLOSSARY_ROOT/${PROJECT_ID}/${SUBDIR}.jsonl"
  if ! (cd "$APP" && python3 - "$SLICE" "$AGENT_SDK" "$MODEL" "$REGION" "${GLOSSARY_MAX_FILES:-0}" <<'PY'
import sys
from glossary_config import fingerprint, matches
sys.exit(0 if matches(sys.argv[1], fingerprint(*sys.argv[2:5], max_files=int(sys.argv[5]))) else 1)
PY
  ); then
    NEED_BUILD="$NEED_BUILD $SUBDIR"
  fi
done
NEED_BUILD="${NEED_BUILD# }"

if [ -z "$NEED_BUILD" ]; then
  echo "glossary: all slices already built — skipping initial build (refresh timers keep them current)"
elif [ -z "$MODEL" ]; then
  echo "glossary: MODEL empty — skipping initial build (engine disabled; enable with deploy-all.sh --with-glossary)"
# GUARD: only run the build engine if this host can actually invoke Bedrock. Without the
# bedrock-invoke IAM policy (engine intentionally disabled, or an older host), every cc call
# would AccessDenied and silently write an EMPTY slice that looks "built". A cheap converse
# precheck decides once (only when something actually needs building); fail → SKIP + log.
elif [[ "$AGENT_SDK" == "claude" ]] && ! aws bedrock-runtime converse --region "$REGION" --model-id "$MODEL" \
        --messages '[{"role":"user","content":[{"text":"ok"}]}]' \
        --cli-connect-timeout 8 --cli-read-timeout 20 >/dev/null 2>&1; then
  echo "glossary: Bedrock not invokable on this host (no bedrock-invoke perm?) — skipping initial build"
else
  for SUBDIR in $NEED_BUILD; do
    WS="$LOCAL_REPO_ROOT/$SUBDIR"
    mkdir -p "$GLOSSARY_ROOT/${PROJECT_ID}"
    LOG="/var/log/glossary-build-${PROJECT_ID}-${SUBDIR}.log"
    # DETACH VIA systemd-run, NOT `nohup … &`. This script is driven over SSM RunCommand, and SSM
    # does not return until EVERY process still holding the command's stdout pipe has exited. A
    # `nohup … &` child stays in our session and inherits the `exec > >(tee …)` pipe fd from the top
    # of this script, so it keeps that pipe open — SSM (and therefore the deploy step that then
    # starts the gateway) blocks on the whole multi-minute cc scan. systemd-run hands the build to
    # PID 1 as a transient unit in its own session/cgroup with its own fds; this call returns at
    # once and the build outlives our SSM session. --collect reaps the unit when it finishes (even
    # on failure) so a later re-activate can reuse the same unit name.
    # flock on a per-slice lock SHARED with the refresh unit (glossary_refresh.sh takes the same
    # lock), so the initial full build and the first scheduled incremental can't write the slice
    # concurrently (last-writer-wins corruption). The log + the glossary_gen_done/cc_failed JSON
    # line in it are the success/failure signal.
    # GLOSSARY_MAX_FILES: `source`d from /etc/index-service.env is NOT exported — pass it through
    # explicitly (via --setenv) or glossary_gen falls back to its own default (400). The refresh
    # timer gets it differently (systemd EnvironmentFile exports it). The conditional
    # `${VAR:+--setenv=…}` word simply vanishes when GLOSSARY_MAX_FILES is unset, so no empty arg.
    systemctl reset-failed "glossary-build-${PROJECT_ID}-${SUBDIR}.service" 2>/dev/null || true
    GLOSSARY_SOURCE="$(python3 "$RENDER_MANIFEST" --repo-field source "$SUBDIR" "$MANIFEST")"
    # MEMORY CAP on the transient unit. This is the single biggest consumer on the host: up to
    # GLOSSARY_BUILD_CONCURRENCY (default 8) concurrent `claude` Node processes, each with its full
    # stdout buffered in the parent. Uncapped, it OOMs the HOST — and a host-wide OOM lets the
    # kernel pick the largest RSS process anywhere, very plausibly ANOTHER project's codegraph
    # writer. That is exactly the cross-project writer kill the bridge's MemoryMax exists to
    # prevent. Capped, an over-budget build is killed instead: glossary_gen's failure path keeps the
    # existing slice (SKIP), so the cost is a stale glossary, never a damaged graph. If builds start
    # getting killed, lower GLOSSARY_BUILD_CONCURRENCY rather than raising this.
    systemd-run --collect --unit="glossary-build-${PROJECT_ID}-${SUBDIR}" \
        -p WorkingDirectory="$APP" \
        -p MemoryMax=3G -p OOMPolicy=stop \
        -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" \
        --setenv=GLOSSARY_ROOT="$GLOSSARY_ROOT" --setenv=AWS_REGION="$REGION" \
        --setenv=GLOSSARY_CONFIG_FILE="$PROJECT_ENV" --setenv=AGENT_SDK="$AGENT_SDK" \
        ${GLOSSARY_MAX_FILES:+--setenv=GLOSSARY_MAX_FILES="$GLOSSARY_MAX_FILES"} \
        flock "$GLOSSARY_ROOT/${PROJECT_ID}/.${SUBDIR}.lock" \
          bash "$APP/glossary_worker.sh" --project "${PROJECT_ID}" --repo-root "$WS" \
            --out "$GLOSSARY_ROOT/${PROJECT_ID}/${SUBDIR}.jsonl" \
            --model "$MODEL" --region "$REGION" --sdk "$AGENT_SDK" --source "$GLOSSARY_SOURCE" --full --strict \
      || echo "glossary: systemd-run launch failed for $SUBDIR (non-fatal — bridge serves empty glossary)"
  done
  echo "glossary: initial full build launched (detached via systemd-run) for [${NEED_BUILD}]"
fi

echo "ACTIVATE_DONE project=${PROJECT_ID} port=${BRIDGE_PORT} repos=[${SUBDIRS//$'\n'/ }]"
