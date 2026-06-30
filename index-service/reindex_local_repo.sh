#!/usr/bin/env bash
# reindex_local_repo.sh — host-side ingest for a LOCAL repo. Two modes:
#   --prepare <subdir>  : create staging dir /data/repo/<subdir>.incoming owned by the SSH user
#                         (so push-local-repo.sh rsyncs into it without sudo on the dir).
#   <subdir>            : apply the staged code to the live repo dir and pick up the change.
#
# UPDATE MODEL — same path git repos already use (multi-repo-isolation §8):
#   - FIRST push (no graph yet): the live dir has no graph.db, so the resident codegraph watcher
#     has nothing to incrementally update. Build the graph once via index-build@ (bridge stopped so
#     its flock is free — single-writer, 不变量2), then start the bridge.
#   - SUBSEQUENT push (graph exists): rsync the staged tree onto the live tree IN PLACE — exactly
#     like `git pull`'s `git reset --hard` rewrites the working tree. The resident codegraph --mcp
#     process's file-watcher picks up the changed files and rebuilds the in-memory graph within
#     seconds. NO bridge stop, NO full rebuild, NO second writer. The graph dirs (.codegraph/.home)
#     are PROTECTED from rsync --delete so the live graph survives the sync.
#
# Why stage first, then apply locally (push-local-repo.sh does the slow network rsync into
# .incoming; this script does the fast LOCAL rsync .incoming -> live): the network transfer can be
# slow or fail, and it must never touch the live dir mid-flight. By the time we apply, the staged
# tree is complete, so the only window of inconsistency is the brief local rsync — during which the
# live tree is momentarily a mix of old and new files. A query landing in that window may read a
# not-yet-consistent tree, but the watcher reconciles within seconds. This is the SAME accepted
# behavior as a git repo's in-place `git pull` (multi-repo-isolation §8.2).
set -euo pipefail

MODE="reindex"
if [ "${1:-}" = "--prepare" ]; then MODE="prepare"; shift; fi
SUBDIR="${1:?usage: reindex_local_repo.sh [--prepare] <subdir>}"
echo "$SUBDIR" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "REINDEX_FAILED: invalid subdir '$SUBDIR'"; exit 2; }

LOCAL_REPO_ROOT=/data/repo
WS="$LOCAL_REPO_ROOT/$SUBDIR"
STAGE="$LOCAL_REPO_ROOT/$SUBDIR.incoming"

if [ "$MODE" = "prepare" ]; then
  # Staging dir owned by the INVOKING (sudo) user; NEVER touches the live dir.
  mkdir -p "$STAGE"
  owner="${SUDO_USER:-root}"
  chown -R "$owner":"$owner" "$STAGE" 2>/dev/null || true
  echo "REINDEX_PREPARED stage=$STAGE owner=$owner"
  exit 0
fi

[ -d "$STAGE" ] || { echo "REINDEX_FAILED: no staged code at $STAGE (run push-local-repo.sh first)"; exit 1; }
[ -n "$(ls -A "$STAGE" 2>/dev/null)" ] || { echo "REINDEX_FAILED: staged dir $STAGE is empty"; exit 1; }

# Resolve the owning project from the manifests.
PID=""
for m in /etc/index-projects/*.json; do
  [ -f "$m" ] || continue
  if python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in [r.get("subdir") for r in m.get("repos",[])] else 1)' "$m" "$SUBDIR"; then
    PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projectId"])' "$m")"; break
  fi
done
[ -n "$PID" ] || { echo "REINDEX_FAILED: subdir '$SUBDIR' not found in any project manifest"; exit 1; }
BRIDGE="index-bridge-${PID}.service"
GRAPH="$WS/.home/.codegraph/graph.db"

# Snapshot marker for OPS (not surfaced in answers — see invariants). `sudo cat .snapshot-time`
# tells the operator when this local repo was last pushed.
stamp_snapshot() { date -u +%Y-%m-%dT%H:%M:%SZ > "$WS/.snapshot-time" 2>/dev/null || true; }

# Apply staged tree onto the live tree IN PLACE. --delete makes live mirror the staged copy, but
# PROTECT the live graph dirs (they live inside $WS and must survive the sync), and don't follow
# symlinks (push already dropped them; belt-and-suspenders). git metadata is irrelevant for a
# local repo. Trailing slash on src copies CONTENTS into $WS.
apply_staged() {
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
  rsync -a --delete \
    --filter='P .codegraph/' --filter='P .home/' \
    --exclude='.git' --no-links \
    "$STAGE/" "$WS/"
}

if [ -s "$GRAPH" ]; then
  # ----- SUBSEQUENT push: in-place update, watcher picks it up, bridge stays up -----
  echo "reindex: applying staged update in place (bridge stays up; watcher re-indexes incrementally)"
  apply_staged
  stamp_snapshot
  rm -rf "$STAGE"
  echo "REINDEX_DONE subdir=${SUBDIR} project=${PID} mode=incremental"
else
  # ----- FIRST push: no graph yet → full build with the bridge stopped (free the writer flock) -----
  echo "reindex: first build for $SUBDIR — stopping $BRIDGE to build the graph (single-writer)"
  systemctl stop "$BRIDGE" 2>/dev/null || true
  apply_staged
  stamp_snapshot
  systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
  systemctl start "index-build@${SUBDIR}.service" || true
  R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
  if [ "$R" != "success" ]; then
    echo "REINDEX_FAILED: index-build@${SUBDIR} Result=$R"; journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -30 || true
    systemctl start "$BRIDGE" 2>/dev/null || true   # bring the project back even on a failed first build
    exit 1
  fi
  rm -rf "$STAGE"
  systemctl start "$BRIDGE" || { echo "REINDEX_WARN: graph built OK but bridge start returned non-zero — check: systemctl status $BRIDGE"; }
  echo "REINDEX_DONE subdir=${SUBDIR} project=${PID} mode=initial-build"
fi
