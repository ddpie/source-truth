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
exec > >(tee -a "/var/log/activate-project-${PROJECT_ID:-unknown}.log") 2>&1

: "${PROJECT_ID:?activate_project: PROJECT_ID required}"
: "${REPO_MANIFEST_JSON:?activate_project: REPO_MANIFEST_JSON required}"

# shellcheck disable=SC1091
source /etc/index-service.env   # BUCKET, REGION, MAX_FILES (written by bootstrap's user-data)

APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
LOCAL_REPO_ROOT=/data/repo
RENDER_MANIFEST="$APP/render_manifest.py"
GIT_FETCH="$APP/git_fetch.sh"
[ -f "$RENDER_MANIFEST" ] || { echo "ACTIVATE_FAILED: render_manifest.py not in app bundle"; exit 1; }
[ -f "$GIT_FETCH" ]       || { echo "ACTIVATE_FAILED: git_fetch.sh not in app bundle"; exit 1; }
[ -x "$BIN" ]             || { echo "ACTIVATE_FAILED: codegraph-server not installed (run bootstrap first)"; exit 1; }

mkdir -p /etc/index-projects "$LOCAL_REPO_ROOT"
MANIFEST="/etc/index-projects/${PROJECT_ID}.json"
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
if [ -n "${GIT_SECRET_ID:-}" ]; then
  GIT_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$GIT_SECRET_ID" \
    --query SecretString --output text 2>/dev/null || echo "")"
  if [ -n "$GIT_TOKEN" ]; then
    printf '#!/bin/sh\nexec echo "%s"\n' "$GIT_TOKEN" > /opt/idx/git-askpass.sh
    chmod 700 /opt/idx/git-askpass.sh
    printf 'GIT_ASKPASS=/opt/idx/git-askpass.sh\nGIT_TERMINAL_PROMPT=0\n' > /etc/index-git.env
    chmod 600 /etc/index-git.env
    export GIT_ASKPASS=/opt/idx/git-askpass.sh GIT_TERMINAL_PROMPT=0
    unset GIT_TOKEN
  else
    echo "WARN: GIT_SECRET_ID set but secret empty/unreadable — clone works only for public repos"
  fi
fi

# --- clone each repo + build its graph + write a concrete per-repo refresh unit+timer ----------
BUILD_UNITS=""
SERVE_FLOCKS=""
while IFS= read -r SUBDIR; do
  : "${SUBDIR:?ACTIVATE_FAILED: empty subdir (refusing git op on repo root)}"
  WS="$LOCAL_REPO_ROOT/$SUBDIR"
  GIT_URL="$(python3 "$RENDER_MANIFEST" --repo-field git "$SUBDIR" "$MANIFEST")" \
    || { echo "ACTIVATE_FAILED: no git url for $SUBDIR"; exit 1; }
  GIT_REF="$(python3 "$RENDER_MANIFEST" --repo-field ref "$SUBDIR" "$MANIFEST" || echo "")"
  IV="$(python3 "$RENDER_MANIFEST" --repo-field refreshIntervalSec "$SUBDIR" "$MANIFEST" 2>/dev/null || echo "")"
  [ -n "$IV" ] && [ "$IV" != "None" ] || IV=300

  bash "$GIT_FETCH" "$SUBDIR" "$GIT_URL" "$GIT_REF" "$WS" \
    || { echo "ACTIVATE_FAILED: git fetch $SUBDIR"; exit 1; }
  # graph dirs INSIDE $WS (proven layout); created after clone, git-untracked so reset --hard keeps them.
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"

  BUILD_UNITS="$BUILD_UNITS index-build@${SUBDIR}.service"
  SERVE_FLOCKS="$SERVE_FLOCKS /usr/bin/flock $WS/.codegraph/.writer.lock"

  # Concrete refresh unit + timer for this repo (git url/ref baked in — non-secret).
  cat > "/etc/systemd/system/index-refresh-${SUBDIR}.service" <<UNIT
[Unit]
Description=Scheduled git pull for repo ${SUBDIR} (codegraph watcher re-indexes in-place)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-/etc/index-git.env
ExecStart=$GIT_FETCH ${SUBDIR} ${GIT_URL} ${GIT_REF} ${WS}
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
done <<< "$SUBDIRS"

# --- this project's CONCRETE resident bridge unit (index-bridge-<projectId>) -------------------
# A concrete unit (not the @ template) because SERVE_FLOCKS is a variable-length chain of flock
# prefixes that can't be carried in a systemd specifier. Serves ONLY this project's repos on its
# OWN port → project A's process has no handle to project B's graph (A 档逻辑隔离).
cat > "/etc/systemd/system/index-bridge-${PROJECT_ID}.service" <<UNIT
[Unit]
Description=CodeGraph MCP HTTP bridge for project ${PROJECT_ID} (resident)
After=network-online.target remote-fs.target${BUILD_UNITS}
Wants=network-online.target${BUILD_UNITS}
[Service]
Environment=HOME=/data
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=CODEGRAPH_MAX_FILES=${MAX_FILES}
WorkingDirectory=${APP}
ExecStart=${SERVE_FLOCKS} /usr/bin/python3 -m http_bridge ${SERVE_ARGS} --host 0.0.0.0 --port ${BRIDGE_PORT} --mount-root ""
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Build each repo (sole writer per graph) BEFORE starting the bridge. If the bridge is already
# running (re-activate), stop it first so the build's `flock -n` can take the writer lock.
systemctl stop "index-bridge-${PROJECT_ID}.service" 2>/dev/null || true
for SUBDIR in $SUBDIRS; do
  systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
  systemctl start "index-build@${SUBDIR}.service" || true
  R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
  if [ "$R" != "success" ]; then
    echo "ACTIVATE_FAILED: index-build@${SUBDIR} Result=$R"
    journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -40 || true
    exit 1
  fi
done

systemctl enable --now "index-bridge-${PROJECT_ID}.service"
for SUBDIR in $SUBDIRS; do
  systemctl enable --now "index-refresh-${SUBDIR}.timer"
done

echo "ACTIVATE_DONE project=${PROJECT_ID} port=${BRIDGE_PORT} repos=[${SUBDIRS//$'\n'/ }]"
