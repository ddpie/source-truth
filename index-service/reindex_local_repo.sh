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

# Serialize apply runs per subdir. Two concurrent reindexes would run `rsync -a --delete` against the
# SAME live dir and delete each other's half-transferred files. Hold a non-blocking per-subdir lock
# for the rest of the script (fd 9 stays open until we exit, releasing it); a second concurrent push
# fails fast with a clear message rather than corrupting the live tree.
LOCKFILE="$LOCAL_REPO_ROOT/.$SUBDIR.reindex.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "REINDEX_FAILED: another reindex for '$SUBDIR' is in progress (lock $LOCKFILE) — re-run after it finishes"; exit 1; }

[ -d "$STAGE" ] || { echo "REINDEX_FAILED: no staged code at $STAGE (run push-local-repo.sh first)"; exit 1; }
[ -n "$(ls -A "$STAGE" 2>/dev/null)" ] || { echo "REINDEX_FAILED: staged dir $STAGE is empty"; exit 1; }

# Resolve the owning project from the manifests, AND the repo's declared source. We only ingest
# LOCAL repos here: applying a push onto a git-source repo would be silently undone by the next
# git-refresh `git reset --hard`, so refuse it loudly instead.
PID=""; SRC=""
for m in /etc/index-projects/*.json; do
  [ -f "$m" ] || continue
  # Print "<projectId> <source>" if this manifest owns $SUBDIR, else exit 1 (no output).
  out="$(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
for r in m.get("repos",[]):
    if r.get("subdir")==sys.argv[2]:
        print(m["projectId"], r.get("source","git")); sys.exit(0)
sys.exit(1)' "$m" "$SUBDIR")" || continue
  PID="${out%% *}"; SRC="${out##* }"; break
done
[ -n "$PID" ] || { echo "REINDEX_FAILED: subdir '$SUBDIR' not found in any project manifest"; exit 1; }
[ "$SRC" = "local" ] || { echo "REINDEX_FAILED: '$SUBDIR' is a ${SRC:-git} repo, not local — push-local-repo.sh only applies to source:\"local\" repos (a git repo is refreshed by its own git pull)"; exit 1; }
BRIDGE="index-bridge-${PID}.service"
GRAPH="$WS/.home/.codegraph/graph.db"
APP="${APP:-/opt/idx/app}"
CHANGED_LIST="$(mktemp /tmp/reindex-changed.XXXXXX)"
DELETED_LIST="$(mktemp /tmp/reindex-deleted.XXXXXX)"
trap 'rm -f "$CHANGED_LIST" "$DELETED_LIST"' EXIT

# Snapshot marker for OPS (not surfaced in answers — see invariants). `sudo cat .snapshot-time`
# tells the operator when this local repo was last pushed.
stamp_snapshot() { date -u +%Y-%m-%dT%H:%M:%SZ > "$WS/.snapshot-time" 2>/dev/null || true; }

# Apply staged tree onto the live tree IN PLACE, capturing the change set into CHANGED_LIST /
# DELETED_LIST for the incremental glossary rebuild. --delete makes live mirror the staged copy;
# PROTECT the live graph dirs (they live inside $WS and must survive the sync); --no-links refuses
# symlinks (push already dropped them; belt-and-suspenders). --itemize-changes prints one line per
# path: a leading '*deleting' marks a removal, otherwise the change flags ('>f...' etc.) mark an
# added/updated file. We parse that into the two lists (a dir line ends in '/', skipped).
#
# --delay-updates SHRINKS the interrupt window: rsync transfers every updated file into a holding
# area inside $WS first, then renames them all in at the very end. If this script is killed (kill,
# power loss, disk full) DURING the transfer — the long part — the live tree is left UNTOUCHED;
# only an interrupt in the brief final rename batch can leave live half-updated. Either way the
# staged dir survives (the `rm -rf "$STAGE"` runs only after a clean apply), so re-running push/
# reindex reconverges live to the full staged state — the same recover-by-rerun story as an
# interrupted `git pull`'s `git reset --hard`.
apply_staged() {
  mkdir -p "$WS/.codegraph" "$WS/.home/.codegraph"
  : > "$CHANGED_LIST"; : > "$DELETED_LIST"
  rsync -a --delete --delay-updates --itemize-changes \
    --filter='P .codegraph/' --filter='P .home/' \
    --exclude='.git' --no-links \
    "$STAGE/" "$WS/" | while IFS= read -r line; do
      # itemize lines are "<flags> <path>": an 11-char flag field for a change (e.g. ">f+++++++++"),
      # or the "*deleting" keyword for a removal — both followed by one-or-more spaces then the path.
      # Strip the leading non-space token AND all following spaces so the path has no leading blanks
      # (the *deleting keyword is shorter than 11 chars and pads with spaces, which a single ${#* }
      # strip would leave behind).
      path="${line#* }"; path="${path#"${path%%[![:space:]]*}"}"
      case "$path" in */) continue ;; esac    # directory entry — no file term to (re)build
      case "$line" in
        '*deleting'*) printf '%s\n' "$path" >> "$DELETED_LIST" ;;
        *)            printf '%s\n' "$path" >> "$CHANGED_LIST" ;;
      esac
    done
}

# Rebuild the glossary slice (best-effort, detached) — mirrors activate_project's build engine.
# $1 = mode: "incremental" (feed the rsync-derived change lists) or "full" (first build).
# Gated on MODEL + a Bedrock precheck so a host without the build engine degrades gracefully
# (graph already updated; a stale/empty glossary is tolerable). Detached so reindex returns fast.
refresh_glossary() {
  local mode="$1"
  ( # subshell: a glossary hiccup must never change reindex's exit code
    # shellcheck disable=SC1091
    . /etc/index-service.env 2>/dev/null || true   # MODEL, REGION, GLOSSARY_MAX_FILES
    local groot="${GLOSSARY_ROOT:-/data/glossary}"
    [ -n "${MODEL:-}" ] || { echo "reindex: MODEL empty — skipping glossary refresh"; return 0; }
    aws bedrock-runtime converse --region "${REGION:-}" --model-id "$MODEL" \
      --messages '[{"role":"user","content":[{"text":"ok"}]}]' \
      --cli-connect-timeout 8 --cli-read-timeout 20 >/dev/null 2>&1 \
      || { echo "reindex: Bedrock not invokable — skipping glossary refresh (slice left as-is)"; return 0; }
    mkdir -p "$groot/${PID}"
    local glog="/var/log/glossary-build-${PID}-${SUBDIR}.log"
    local slice="$groot/${PID}/${SUBDIR}.jsonl"
    local args=(--project "$PID" --repo-root "$WS" --out "$slice" --model "$MODEL" --region "${REGION:-}")
    if [ "$mode" = "incremental" ]; then
      # Copy the change lists to stable temp names: the detached build reads them asynchronously,
      # so they must outlive this script's EXIT-trap cleanup of CHANGED_LIST/DELETED_LIST. These
      # copies are tiny and left in /tmp (OS-cleared); not worth a cleanup race. An empty change
      # set just makes glossary_gen no-op (it exits 0 without calling cc).
      local cl dl; cl="$(mktemp /tmp/gloss-chg.XXXXXX)"; dl="$(mktemp /tmp/gloss-del.XXXXXX)"
      cp "$CHANGED_LIST" "$cl"; cp "$DELETED_LIST" "$dl"
      args+=(--changed-list "$cl" --deleted-list "$dl")
    else
      args+=(--full)
    fi
    ( cd "$APP" && nohup env GLOSSARY_ROOT="$groot" AWS_REGION="${REGION:-}" \
        ${GLOSSARY_MAX_FILES:+GLOSSARY_MAX_FILES="$GLOSSARY_MAX_FILES"} \
        flock "$groot/${PID}/.${SUBDIR}.lock" \
        python3 -m glossary_gen "${args[@]}" >>"$glog" 2>&1 & ) || true
    echo "reindex: glossary slice refresh launched (detached, $mode) for $SUBDIR"
  ) || true
}

# Decide incremental vs full by graph VALIDITY, not mere non-emptiness. Use the SAME >=64KiB
# threshold index-build@'s ExecStartPost enforces (bootstrap.sh): a first build that was killed
# mid-write can leave a small partial graph.db — `[ -s ]` (non-empty) would then wrongly pick the
# incremental path and the watcher would serve a broken/stale graph forever. A sub-64KiB file means
# "no valid graph yet" → fall through to the full-build branch, which rebuilds it correctly.
GRAPH_SZ="$(du -sb "$GRAPH" 2>/dev/null | cut -f1 || echo 0)"
if [ "${GRAPH_SZ:-0}" -ge 65536 ]; then
  # ----- SUBSEQUENT push: in-place update, watcher picks it up, bridge stays up -----
  echo "reindex: applying staged update in place (bridge stays up; watcher re-indexes incrementally)"
  apply_staged
  stamp_snapshot
  rm -rf "$STAGE"
  refresh_glossary incremental
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
  refresh_glossary full
  echo "REINDEX_DONE subdir=${SUBDIR} project=${PID} mode=initial-build"
fi
