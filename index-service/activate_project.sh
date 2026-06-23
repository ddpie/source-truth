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

# Capture a caller-passed (per-project) MODEL BEFORE sourcing the env file, which also defines
# MODEL (host-global) and would otherwise clobber the per-project value.
_PASSED_MODEL="${MODEL:-}"

# shellcheck disable=SC1091
source /etc/index-service.env   # BUCKET, REGION, MAX_FILES, MODEL (written by provision)
# Per-project model (from projects.json via deploy_project) wins over the host-global env value.
[ -n "$_PASSED_MODEL" ] && MODEL="$_PASSED_MODEL"

APP=/opt/idx/app
BIN=/opt/idx/bin/codegraph-server
LOCAL_REPO_ROOT=/data/repo
RENDER_MANIFEST="$APP/render_manifest.py"
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
    # The askpass helper is STATIC (cats a separate token file) — the token is never interpolated
    # into a script, so a token containing "/$/backtick can't break out or be command-substituted.
    # Both files are created under `umask 077` (created restricted from the start — no chmod-after-
    # write window where the token file is briefly world-readable). The token file holds ONLY the
    # raw token; the askpass + env file hold no secret.
    ( umask 077; printf '%s' "$GIT_TOKEN" > /opt/idx/git-token )
    ( umask 077; printf '#!/bin/sh\nexec cat /opt/idx/git-token\n' > /opt/idx/git-askpass.sh )
    chmod 700 /opt/idx/git-askpass.sh
    ( umask 077; printf 'GIT_ASKPASS=/opt/idx/git-askpass.sh\nGIT_TERMINAL_PROMPT=0\n' > /etc/index-git.env )
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

  # Concrete refresh unit + timer for this repo. ExecStart re-reads git url/ref from THIS
  # project's manifest at run time (via render_manifest --repo-field) rather than baking them
  # into the unit text: that (a) preserves an EMPTY ref correctly — git_fetch treats "" as
  # "default branch" — instead of an unquoted empty systemd arg collapsing and shifting the
  # positional args (which made the DEST arg empty and every pull fail); and (b) keeps the git
  # URL/ref out of the ExecStart line, so a value with whitespace or a leading dash can't become
  # an extra/option arg. The whole command is one `bash -c` so the $(...) lookups run on the host.
  # The refresh runs glossary_refresh.sh, which (a) does the authoritative git pull (its exit
  # code fails the unit on a bad pull, unchanged), then (b) rebuilds THIS repo's glossary slice
  # incrementally from the pull's old..new diff (best-effort, never fails the unit). MODEL/REGION
  # come from /etc/index-service.env; the build-time cc engine uses them on Bedrock.
  cat > "/etc/systemd/system/index-refresh-${SUBDIR}.service" <<UNIT
[Unit]
Description=Scheduled git pull + glossary refresh for repo ${SUBDIR}
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin:/bin
EnvironmentFile=-/etc/index-git.env
EnvironmentFile=-/etc/index-service.env
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
ExecStart=${SERVE_FLOCKS} /usr/bin/python3 -m http_bridge ${SERVE_ARGS} --host 0.0.0.0 --port ${BRIDGE_PORT} --mount-root "" --project ${PROJECT_ID}
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

# RECONCILE: a repo removed from this project's repos[] must not leave an orphan behind.
# activate only ever (re)creates units/slices for the CURRENT $SUBDIRS, so a previously-activated
# repo that's now gone would keep: (a) its index-refresh-<sub>.timer firing, and (b) its
# /data/glossary/<project>/<sub>.jsonl slice — which glossary_read globs unconditionally, so its
# stale concepts would pollute glossary_index forever. Tear down units + slice for any on-disk
# <sub> not in the current manifest. (Repo working copies under /data/repo are left in place — a
# stale graph isn't served once its bridge args drop it; only the glossary slice is globbed blindly.)
CUR_SUBDIRS=" $(echo $SUBDIRS) "   # space-delimited membership test
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
PROJ_GLOSS_DIR="$GLOSSARY_ROOT/$PROJECT_ID"
for unit in $(systemctl list-unit-files 'index-refresh-*.timer' --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  sub="${unit#index-refresh-}"; sub="${sub%.timer}"
  # Only this project's repos are candidates; we can't tell ownership from the unit name alone,
  # so only reconcile a unit whose matching slice lives under THIS project's glossary dir.
  [ -f "$PROJ_GLOSS_DIR/${sub}.jsonl" ] || continue
  case "$CUR_SUBDIRS" in *" $sub "*) continue ;; esac   # still current → keep
  echo "glossary: reconcile — repo '$sub' removed; tearing down its refresh unit + slice"
  systemctl disable --now "index-refresh-${sub}.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/index-refresh-${sub}.service" "/etc/systemd/system/index-refresh-${sub}.timer" 2>/dev/null || true
  rm -f "$PROJ_GLOSS_DIR/${sub}.jsonl" "$PROJ_GLOSS_DIR/.${sub}.lock" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

systemctl enable --now "index-bridge-${PROJECT_ID}.service"
for SUBDIR in $SUBDIRS; do
  systemctl enable --now "index-refresh-${SUBDIR}.timer"
done

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
  SLICE="$GLOSSARY_ROOT/${PROJECT_ID}/${SUBDIR}.jsonl"
  if [ ! -s "$SLICE" ]; then
    NEED_BUILD="$NEED_BUILD $SUBDIR"
  fi
done
NEED_BUILD="${NEED_BUILD# }"

if [ -z "$NEED_BUILD" ]; then
  echo "glossary: all slices already built — skipping initial build (refresh timers keep them current)"
elif [ -z "$MODEL" ]; then
  echo "glossary: MODEL empty — skipping initial build (engine disabled)"
# GUARD: only run the build engine if this host can actually invoke Bedrock. Without the
# bedrock-invoke IAM policy (engine intentionally disabled, or an older host), every cc call
# would AccessDenied and silently write an EMPTY slice that looks "built". A cheap converse
# precheck decides once (only when something actually needs building); fail → SKIP + log.
elif ! aws bedrock-runtime converse --region "$REGION" --model-id "$MODEL" \
        --messages '[{"role":"user","content":[{"text":"ok"}]}]' \
        --cli-connect-timeout 8 --cli-read-timeout 20 >/dev/null 2>&1; then
  echo "glossary: Bedrock not invokable on this host (no bedrock-invoke perm?) — skipping initial build"
else
  for SUBDIR in $NEED_BUILD; do
    WS="$LOCAL_REPO_ROOT/$SUBDIR"
    mkdir -p "$GLOSSARY_ROOT/${PROJECT_ID}"
    LOG="/var/log/glossary-build-${PROJECT_ID}-${SUBDIR}.log"
    # flock on a per-slice lock SHARED with the refresh unit (glossary_refresh.sh takes the same
    # lock), so the initial full build and the first scheduled incremental can't write the slice
    # concurrently (last-writer-wins corruption). nohup-detached so activation doesn't block; the
    # log + the glossary_gen_done/cc_failed JSON line in it are the success/failure signal.
    ( cd "$APP" && GLOSSARY_ROOT="$GLOSSARY_ROOT" AWS_REGION="$REGION" \
        nohup flock "$GLOSSARY_ROOT/${PROJECT_ID}/.${SUBDIR}.lock" \
          python3 -m glossary_gen --project "${PROJECT_ID}" --repo-root "$WS" \
            --out "$GLOSSARY_ROOT/${PROJECT_ID}/${SUBDIR}.jsonl" \
            --model "$MODEL" --region "$REGION" --full \
            >>"$LOG" 2>&1 & ) || true
  done
  echo "glossary: initial full build launched (detached) for [${NEED_BUILD}]"
fi

echo "ACTIVATE_DONE project=${PROJECT_ID} port=${BRIDGE_PORT} repos=[${SUBDIRS//$'\n'/ }]"
