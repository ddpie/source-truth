#!/usr/bin/env bash
# glossary_refresh.sh <subdir> <git_url> <ref> <ws> <project> <model> <region>
#
# One refresh step for ONE repo: pull the repo, then (re)build that repo's glossary slice
# INCREMENTALLY from the git diff. Invoked by the per-repo index-refresh-<subdir> unit AFTER
# the codegraph watcher picks up the new files.
#
# Why a wrapper (not two ExecStart lines): the incremental glossary build needs the OLD..NEW
# shas that git_fetch.sh prints (`git_fetch_shas: <sub> OLD=.. NEW=..`); capturing that line and
# feeding it to glossary_gen is easiest in one script. git_fetch's exit code is preserved — a
# failed pull still fails the unit (alarm), and the glossary step is best-effort (never fails the
# refresh: a stale glossary is tolerable, a missed code pull is not).
#
# PER-REPO SLICE: each repo writes /data/glossary/<project>/<subdir>.jsonl (NOT a shared file), so
# concurrent per-repo refresh timers never write the same file, and a repo's diff only rebuilds its
# own slice. glossary_read aggregates all *.jsonl slices in the project dir.
set -uo pipefail

SUBDIR="${1:?glossary_refresh: subdir required}"
URL="${2:-}"; REF="${3:-}"; WS="${4:?ws required}"; PROJECT="${5:?project required}"
MODEL="${6:-}"; REGION="${7:-}"   # empty model = glossary engine disabled (pull-only refresh)
APP="${GLOSSARY_APP_DIR:-/opt/idx/app}"   # overridable for offline tests only
GLOSSARY_ROOT="${GLOSSARY_ROOT:-/data/glossary}"
OUT="$GLOSSARY_ROOT/$PROJECT/${SUBDIR}.jsonl"

# 1) Pull (authoritative). Capture output so we can read the OLD/NEW shas; tee it back to the
#    journal so the existing git_fetch logging is preserved.
FETCH_OUT="$(bash "$APP/git_fetch.sh" "$SUBDIR" "$URL" "$REF" "$WS" 2>&1)"; RC=$?
printf '%s\n' "$FETCH_OUT"
[ "$RC" -eq 0 ] || exit "$RC"   # a failed pull MUST fail the unit (never serve stale code silently)

# 2) Parse `git_fetch_shas: <subdir> OLD=<sha> NEW=<sha>`.
SHAS_LINE="$(printf '%s\n' "$FETCH_OUT" | sed -n 's/^git_fetch_shas: .*OLD=/OLD=/p' | head -1)"
OLD=""; NEW=""
case "$SHAS_LINE" in
  OLD=*) OLD="${SHAS_LINE#OLD=}"; OLD="${OLD%% *}";
         NEW="$(printf '%s\n' "$SHAS_LINE" | sed -n 's/.*NEW=//p')" ;;
esac

# 3) (Re)build this repo's glossary slice. Best-effort: a glossary failure must NOT fail the
#    refresh (the code pull already succeeded). Empty OLD => full build; OLD present => incremental.
#    Glossary off (deploy-all without --with-glossary): the pull above is the whole job.
if [ "${GLOSSARY_ENABLED:-true}" = "false" ] || [ -z "$MODEL" ]; then
  echo "glossary_refresh: glossary disabled (no model) — pull done for $SUBDIR, slice left as-is"
  exit 0
fi
mkdir -p "$GLOSSARY_ROOT/$PROJECT" 2>/dev/null || true
ARGS=(--project "$PROJECT" --repo-root "$WS" --out "$OUT" --model "$MODEL" --region "$REGION" --source git)
if [ -n "$OLD" ] && [ -n "$NEW" ]; then
  ARGS+=(--old "$OLD" --new "$NEW")
else
  ARGS+=(--full)
fi
# flock the per-slice lock (SAME lock activate_project's initial full build takes), so a refresh
# that fires while the initial build is still running can't write the slice concurrently
# (last-writer-wins corruption). -w 5: if the build holds it, skip this tick rather than queue —
# the next timer tick will pick up any new commits anyway.
LOCK="$GLOSSARY_ROOT/$PROJECT/.${SUBDIR}.lock"
if ! ( cd "$APP" && GLOSSARY_ROOT="$GLOSSARY_ROOT" AWS_REGION="$REGION" \
        flock -w 5 "$LOCK" bash "$APP/glossary_worker.sh" "${ARGS[@]}" ); then
  echo "glossary_refresh: glossary build skipped/failed for $SUBDIR (refresh still OK; glossary left as-is)" >&2
fi
exit 0
