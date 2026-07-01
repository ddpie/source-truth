#!/usr/bin/env bash
# test_reindex_local_repo.sh — static checks for the local-repo ingest script. No systemd, no network.
# Update model: first push (no graph) → full build with bridge stopped; subsequent push (graph
# exists) → in-place rsync apply, watcher picks it up, bridge stays up.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/index-service/reindex_local_repo.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_reindex_local_repo:"

[[ -f "$S" ]]; check "script exists" $?
bash -n "$S"; check "parses" $?
bash "$S" "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "invalid subdir rejected" $?
bash "$S" --prepare "Bad/Sub" 2>/dev/null; rc=$?; [[ $rc -ne 0 ]]; check "prepare rejects invalid subdir" $?
grep -q 'REINDEX_PREPARED' "$S"; check "has --prepare mode" $?

# Must refuse a git-source repo: applying a push onto it would be undone by the next git pull.
grep -q '\[ "\$SRC" = "local" \]' "$S"; check "refuses non-local (git) repos" $?
grep -q 'not local' "$S"; check "fail-loud message explains git vs local" $?

# Two update paths keyed on whether a VALID graph exists — same >=64KiB threshold index-build@'s
# ExecStartPost enforces, so a killed first build's partial graph.db re-triggers a full rebuild
# rather than a wrong incremental.
grep -q 'GRAPH_SZ.*du -sb "\$GRAPH"' "$S"; check "sizes the graph to decide incremental vs first build" $?
grep -q '"\${GRAPH_SZ:-0}" -ge 65536' "$S"; check "uses the 64KiB validity threshold (matches build guard)" $?
# Incremental path: in-place apply, NO bridge stop (watcher picks it up).
grep -q 'mode=incremental' "$S"; check "has incremental (watcher) path" $?
# First-build path: stop bridge, build, start bridge.
grep -q 'mode=initial-build' "$S"; check "has first-build path" $?
grep -q 'systemctl stop "\$BRIDGE"' "$S"; check "first build stops the bridge (single-writer)" $?

# In-place apply must protect the live graph dirs from rsync --delete.
grep -q "filter=.P .codegraph" "$S" && grep -q "filter=.P .home" "$S"; check "apply protects .codegraph/.home from --delete" $?
# Apply uses --delete to mirror the staged tree, --itemize-changes to derive the change set,
# and --no-links to refuse symlinks.
grep -q 'rsync -a --delete' "$S" && grep -q -- '--no-links' "$S"; check "apply rsync mirrors + refuses symlinks" $?
grep -q -- '--itemize-changes' "$S"; check "apply captures change set via --itemize-changes" $?

# Glossary refresh: incremental path feeds the rsync-derived change lists; first build does --full;
# both gated by a Bedrock precheck (degrade gracefully on a no-engine host).
grep -q 'refresh_glossary incremental' "$S"; check "incremental path refreshes glossary from change lists" $?
grep -q 'refresh_glossary full' "$S"; check "first build refreshes glossary with --full" $?
grep -q -- '--changed-list' "$S" && grep -q -- '--deleted-list' "$S"; check "feeds glossary_gen change/deleted lists" $?
grep -q 'bedrock-runtime converse' "$S"; check "glossary refresh gated by Bedrock precheck" $?
[[ "$_fail" -eq 0 ]]; exit $?
