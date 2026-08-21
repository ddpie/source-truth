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
# __build is INTERNAL: the ssh-facing invocation re-launches this script in __build mode inside a
# transient systemd unit (see the launcher at the tail), so the heavy work survives SSH disconnect.
# Operators never pass it; only systemd-run does.
BG=false
if [ "${1:-}" = "__build" ]; then BG=true; shift; fi
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
# Written only after a verified non-empty full build; its presence (not graph.db's size) is what
# picks incremental over full. Lives under .home/ (rsync-protected), so a code push never drops it.
BUILD_MARKER="$WS/.home/.codegraph/.build-ok"
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
    # DETACH VIA systemd-run, NOT `nohup … &`: this script runs over SSH (push-local-repo.sh),
    # and an SSH channel stays open until every process holding its stdout has exited — a
    # `nohup … &` child inherits that stdout fd and would keep the operator's push command hanging
    # on the full cc scan. systemd-run hands the build to PID 1 (own session/cgroup/fds) and returns
    # at once. --collect reaps the unit on completion so a later refresh reuses the same unit name.
    # ${GLOSSARY_MAX_FILES:+--setenv=…} simply vanishes when unset (no empty arg).
    systemctl reset-failed "glossary-build-${PID}-${SUBDIR}.service" 2>/dev/null || true
    # MemoryMax: same reasoning as activate_project.sh — up to GLOSSARY_BUILD_CONCURRENCY (8)
    # concurrent `claude` processes here are the largest consumer on the host, and an UNCAPPED OOM
    # becomes a host-wide OOM that can kill another project's codegraph writer. Killed build =
    # glossary_gen SKIP = the existing slice survives, so the failure mode is a stale glossary.
    systemd-run --collect --unit="glossary-build-${PID}-${SUBDIR}" \
        -p WorkingDirectory="$APP" \
        -p MemoryMax=3G -p OOMPolicy=stop \
        -p "StandardOutput=append:$glog" -p "StandardError=append:$glog" \
        --setenv=GLOSSARY_ROOT="$groot" --setenv=AWS_REGION="${REGION:-}" \
        ${GLOSSARY_MAX_FILES:+--setenv=GLOSSARY_MAX_FILES="$GLOSSARY_MAX_FILES"} \
        flock "$groot/${PID}/.${SUBDIR}.lock" \
        python3 -m glossary_gen "${args[@]}" \
      || echo "reindex: systemd-run launch failed for $SUBDIR (non-fatal — slice left as-is)"
    echo "reindex: glossary slice refresh launched (detached via systemd-run, $mode) for $SUBDIR"
  ) || true
}

# do_build: apply the staged code, then (re)build the graph and refresh the glossary IN PARALLEL.
# Runs in the background transient unit (BG=true) so it survives SSH disconnect: a first-push full
# build takes minutes AND must reach its final `systemctl start $BRIDGE` — if the ssh channel were
# killed mid-build the bridge would stay down forever. glossary_gen writes <subdir>.jsonl under its
# OWN per-slice lock and never touches graph.db, so it's safe to run concurrently with the graph
# build (which holds the per-repo .writer.lock) — 单写者 is per-graph.db, and these are different files.
do_build() {
  # Decide incremental vs full by a BUILD-OK MARKER, not by graph.db size. A 0-node placeholder
  # graph (built by index-build@ when the repo dir was still empty, before the first push) is a
  # valid store WELL OVER 64KiB (~150-270K), so a size threshold wrongly classified it as
  # "already built" → incremental → the watcher can't backfill thousands of never-indexed files →
  # the graph stays empty forever. The marker is written ONLY after a full build whose log proves a
  # non-empty graph was persisted, so its presence means "a real graph exists here". It lives under
  # .home/ (rsync-protected in apply_staged), so a code push never removes it.
  if [ -f "$BUILD_MARKER" ]; then
    # ----- SUBSEQUENT push: in-place update, watcher picks it up, bridge stays up -----
    echo "reindex: applying staged update in place (bridge stays up; watcher re-indexes incrementally)"
    apply_staged
    stamp_snapshot
    rm -rf "$STAGE"
    refresh_glossary incremental   # parallel: launches its own detached systemd unit, returns at once
    echo "REINDEX_DONE subdir=${SUBDIR} project=${PID} mode=incremental"
  else
    # ----- FIRST push (no build marker): full build with the bridge stopped (free the writer flock) -----
    # AVAILABILITY COST, stated explicitly: the bridge is per-PROJECT, so stopping it takes EVERY
    # repo in this project offline for the duration of THIS repo's build (minutes on a large repo),
    # not just the repo being pushed. That is inherent to one bridge process per project — the
    # writer flock cannot be freed without stopping the process that holds it. Only the first push
    # pays it; later pushes update in place with the bridge up.
    echo "reindex: first build for $SUBDIR — stopping $BRIDGE to build the graph (single-writer)"
    echo "reindex: NOTE — this takes ALL of project ${PID}'s repos offline until the build finishes."
    systemctl stop "$BRIDGE" 2>/dev/null || true
    apply_staged
    stamp_snapshot
    # Kick the glossary build off NOW, BEFORE the (blocking, minutes-long) graph build — it scans the
    # applied source files and is independent of graph.db, so the two run in parallel and total
    # wall-clock ≈ max(graph, glossary) instead of their sum.
    refresh_glossary full
    # `restart` (not `start`): index-build@ is Type=oneshot + RemainAfterExit=yes, so once it has
    # run in this boot it stays active(exited) and a plain `start` is a NO-OP (never rebuilds).
    # `restart` forces it to actually run again. reset-failed first so a prior failed state doesn't
    # block the transaction.
    systemctl reset-failed "index-build@${SUBDIR}.service" 2>/dev/null || true
    # Timestamp taken BEFORE the restart: the fallback window for reading this run's log lines.
    BUILD_SINCE="$(date -u +'%Y-%m-%d %H:%M:%S')"
    systemctl restart "index-build@${SUBDIR}.service" || true
    R="$(systemctl show "index-build@${SUBDIR}.service" --value -p Result 2>/dev/null || echo unknown)"
    if [ "$R" != "success" ]; then
      echo "REINDEX_FAILED: index-build@${SUBDIR} Result=$R"; journalctl -u "index-build@${SUBDIR}.service" --no-pager | tail -30 || true
      systemctl start "$BRIDGE" 2>/dev/null || true   # bring the project back even on a failed first build
      exit 1
    fi
    # DON'T trust the unit's >=64KiB ExecStartPost check alone — a 0-node placeholder store also
    # clears 64KiB. Confirm from the build log that a NON-EMPTY graph was actually persisted
    # ("Persisted <N> nodes" with N>0) before dropping the marker. If it built empty (e.g. code
    # somehow not present), leave NO marker so the next push retries a full build instead of getting
    # stuck on an empty graph.
    #
    # SCOPED TO THIS INVOCATION. Reading the unit's whole retained history was the bug the marker
    # exists to prevent: if THIS run persisted nothing but a previous run logged "Persisted 5000
    # nodes", `tail -1` returned 5000 and the marker was written for an EMPTY graph — after which
    # every later push takes the incremental path and the graph stays empty forever. Prefer the
    # systemd InvocationID (exact, one run) and fall back to --since the pre-restart timestamp on
    # an older systemd that does not expose it.
    INV="$(systemctl show "index-build@${SUBDIR}.service" --value -p InvocationID 2>/dev/null || echo "")"
    if [ -n "$INV" ]; then
      BUILD_LOG_CMD=(journalctl "_SYSTEMD_INVOCATION_ID=$INV" --no-pager)
    else
      BUILD_LOG_CMD=(journalctl -u "index-build@${SUBDIR}.service" --since "$BUILD_SINCE" --no-pager)
    fi
    NODES="$("${BUILD_LOG_CMD[@]}" 2>/dev/null \
      | grep -oE 'Persisted [0-9]+ nodes' | tail -1 | grep -oE '[0-9]+' || echo 0)"
    if [ "${NODES:-0}" -gt 0 ]; then
      touch "$BUILD_MARKER" 2>/dev/null || true
      echo "reindex: graph built with ${NODES} nodes — marker written"
    else
      echo "REINDEX_WARN: index-build@${SUBDIR} reported 0 nodes — NOT marking built; next push will retry full build"
    fi
    rm -rf "$STAGE"
    systemctl start "$BRIDGE" || { echo "REINDEX_WARN: graph built OK but bridge start returned non-zero — check: systemctl status $BRIDGE"; }
    echo "REINDEX_DONE subdir=${SUBDIR} project=${PID} mode=initial-build"
  fi
}

if [ "$BG" = true ]; then
  # We ARE the background build (launched by systemd-run below): do the heavy work and exit. The
  # per-subdir flock (fd 9, taken at the top) is held for the whole build — a second push's launcher
  # fails fast rather than racing this build's rsync/graph write.
  do_build
  exit 0
fi

# ssh-FACING PATH: hand the heavy work to a transient systemd unit (PID 1, own session/cgroup/fds)
# and return immediately. This is why a first-push full build (minutes) survives the operator's ssh
# disconnecting — systemd, not the ssh channel, owns the process.
#
# Resolve $0 to an ABSOLUTE path before re-exec: the transient unit inherits PID 1's cwd (/), so a
# relative $0 (e.g. invoked as `bash reindex_local_repo.sh`) would not be found by the child. The
# real path (push-local-repo.sh runs `sudo bash /opt/idx/app/reindex_local_repo.sh`) is already
# absolute; this just makes a manual relative invocation safe too.
SELF="$0"; case "$SELF" in /*) : ;; *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;; esac
UNIT="reindex-${SUBDIR}"

# CONCURRENCY: we still hold the fd9 advisory lock here (taken at the top). Keep holding it across
# the launch so a second concurrent same-subdir push blocks at the top's `flock -n 9` and fails fast
# — NOT here. The background unit re-takes the SAME lock at its top, so we must release fd9 the
# instant before systemd-run so the child doesn't deadlock on its own flock -n. But if the unit name
# already exists (a prior push's __build still running), systemd-run FAILS — and we must NOT then run
# do_build inline, because we've released the lock and would race that running build's rsync --delete.
# So: on a systemd-run failure we distinguish "unit already exists" (fail fast, a build is in flight)
# from "systemd-run truly unavailable" (non-systemd box → inline fallback, re-acquiring the lock).
systemctl reset-failed "${UNIT}.service" 2>/dev/null || true
if systemctl is-active --quiet "${UNIT}.service" 2>/dev/null; then
  echo "REINDEX_FAILED: a reindex for '${SUBDIR}' is already running (unit ${UNIT}.service) — re-run after it finishes"
  exit 1
fi
exec 9>&-   # drop the launcher's lock; the background unit re-acquires it
run_err="$(systemd-run --collect --unit="$UNIT" \
     -p "StandardOutput=append:/var/log/reindex-${SUBDIR}.log" \
     -p "StandardError=append:/var/log/reindex-${SUBDIR}.log" \
     /bin/bash "$SELF" __build "$SUBDIR" 2>&1)"; run_rc=$?
if [ "$run_rc" -eq 0 ]; then
  echo "REINDEX_LAUNCHED subdir=${SUBDIR} unit=${UNIT}.service"
  echo "  代码已上传，建图+术语表在后台并行进行（ssh 断开不影响）。"
  echo "  这一步不会阻塞，也不会打印 REINDEX_DONE——重建完成的标志在后台日志里。查看进度/确认完成："
  echo "    sudo journalctl -u ${UNIT}.service -f        # 建图/编排（看到 REINDEX_DONE 即完成）"
  echo "    sudo tail -f /var/log/reindex-${SUBDIR}.log  # 同上（文件）"
  echo "    sudo tail -f /var/log/glossary-build-*-${SUBDIR}.log  # 术语表"
elif command -v systemd-run >/dev/null 2>&1; then
  # systemd-run EXISTS but the launch failed (e.g. unit-name collision we didn't catch above, or a
  # transient systemd error). Do NOT run inline — we've released the lock and another build may be
  # writing the live tree. Fail loud so the operator re-runs rather than risk a concurrent rsync.
  echo "REINDEX_FAILED: could not launch background build for '${SUBDIR}' (systemd-run rc=$run_rc): ${run_err}"
  echo "  若上一次推送仍在后台跑，等它结束再重试：sudo systemctl status ${UNIT}.service"
  exit 1
else
  # systemd-run genuinely unavailable (non-systemd test box). Re-acquire the lock (we released fd9
  # above) and run inline so the push still works — without detach, so an ssh disconnect would
  # interrupt it. Re-acquiring is what keeps the single-writer guarantee on this fallback path.
  echo "reindex: systemd-run unavailable — running the build inline (ssh disconnect WOULD interrupt it)"
  exec 9>"$LOCKFILE"
  flock -n 9 || { echo "REINDEX_FAILED: another reindex for '$SUBDIR' is in progress (lock $LOCKFILE)"; exit 1; }
  do_build
fi
