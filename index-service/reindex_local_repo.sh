#!/usr/bin/env bash
# reindex_local_repo.sh — host-side ingest for a LOCAL repo. Two modes:
#   --prepare <subdir>  : create staging dir /data/repo/<subdir>.incoming owned by the SSH user
#                         (so push-local-repo.sh rsyncs into it without sudo on the dir).
#   <subdir>            : swap staged code into live and rebuild, with ATOMIC ROLLBACK on failure.
#
# CORRECTNESS OVER SPEED (MVP). We stop the project bridge, snapshot the current live dir aside,
# move staged code into place, and rebuild the graph AT THE LIVE PATH (never build at a different
# path than it's served from). If the build FAILS, we roll back to the snapshot (old code + old
# graph) and restart — the live copy is never left as "new code + stale graph" (which would cite
# wrong lines, 违反代码为唯一依据). The bridge is down for the rebuild duration; local pushes are
# manual + infrequent so this is acceptable (see runbook). A future optimization is build-in-
# staging-then-rename for sub-second downtime — DEFERRED pending verification that graph.db is
# portable across a directory rename.
#
# SINGLE-WRITER (不变量2): the rebuild runs while the bridge is STOPPED, so index-build@'s flock is
# free — never two writers on graph.db.
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
OLD="$LOCAL_REPO_ROOT/.$SUBDIR.old.$$"

echo "reindex: stopping $BRIDGE for swap+rebuild (project offline during rebuild)"
systemctl stop "$BRIDGE" 2>/dev/null || true

rollback() {
  echo "reindex: ROLLING BACK — restoring previous live copy"
  rm -rf "$WS" 2>/dev/null || true
  [ -d "$OLD" ] && mv "$OLD" "$WS" 2>/dev/null || true
  systemctl start "$BRIDGE" 2>/dev/null || true
}
trap rollback EXIT

# Snapshot current live aside (atomic rename, same filesystem), then move staged code into place.
if [ -d "$WS" ]; then mv "$WS" "$OLD"; fi
mv "$STAGE" "$WS"
mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"   # fresh graph workspace dirs for the rebuild
# Snapshot marker for OPS (not surfaced in answers — see invariants). `sudo cat .snapshot-time`
# tells the operator when this local repo was last pushed. mv (not --delete rsync) keeps it.
date -u +%Y-%m-%dT%H:%M:%SZ > "$WS/.snapshot-time" 2>/dev/null || true

echo "reindex: building graph at live path (bridge stopped, flock free)"
systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
systemctl start "index-build@${SUBDIR}.service"
R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
[ "$R" = "success" ] || { echo "REINDEX_FAILED: index-build@${SUBDIR} Result=$R — rolling back"; journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -30 || true; exit 1; }

# Success: start bridge, drop the old copy, disarm rollback.
systemctl start "$BRIDGE"
trap - EXIT
rm -rf "$OLD"
echo "REINDEX_DONE subdir=${SUBDIR} project=${PID}"
