"""Merge per-repo codegraph results into one envelope (multi-repo fan-out, 阶段2).

When the agent asks a graph query WITHOUT naming a repo and the bridge serves multiple
repos, the bridge runs the query against EACH repo's resident session and merges the
results here. This module is the PURE merge core (no I/O, no sessions) so the corruption-
critical serving path stays thin and the merge logic is unit-testable in isolation.

Design constraints (verified against codegraph-server 0.18.5 envelopes):
  - symbol_search  → {"results":  [...]}
  - get_callers    → {"callers":  [...]}
  - analyze_impact → {"impacted": [...], "indirect_impacted": [...], "direct_impacted": [...]}
  - Result items carry NO score/rank field, so there is NO meaningful cross-repo relevance
    key to interleave on. We therefore preserve REPO-DECLARATION ORDER (the order the bridge
    passes repos in) and, within each repo, codegraph's own ranking. Each item's file path
    is already <repo>/-prefixed by path_align upstream, so the agent can tell repos apart.
  - An errored per-repo envelope ({"error": ...}) contributes NOTHING to the merge (one
    repo's transient failure must not blank the others). If EVERY repo errored, the merged
    envelope surfaces the first error so the agent doesn't read silence as "no matches".
"""
from __future__ import annotations

import json
from typing import Any

# Which list key(s) each tool's envelope carries. Order matters for analyze_impact: the
# merged envelope keeps the same keys, each concatenated across repos in repo order.
_LIST_KEYS: dict[str, tuple[str, ...]] = {
    "codegraph_symbol_search": ("results",),
    "codegraph_get_callers": ("callers",),
    "codegraph_analyze_impact": ("impacted", "indirect_impacted", "direct_impacted"),
}


def merge_fanout(tool_name: str, per_repo_raw: list[str]) -> str:
    """Merge a list of per-repo result JSON strings into ONE envelope for `tool_name`.

    `per_repo_raw` is in repo-declaration order; each entry is the (already path-aligned)
    JSON string that repo's session returned. Returns a single JSON envelope string with
    each list key concatenated across repos. Unknown tools / unparseable inputs fall back
    to the first entry unchanged (never corrupt what we don't understand).
    """
    keys = _LIST_KEYS.get(tool_name)
    if keys is None:
        # Unknown tool: we don't know its shape — return the first non-empty raw verbatim.
        return per_repo_raw[0] if per_repo_raw else json.dumps({"error": "no results"})

    merged: dict[str, list[Any]] = {k: [] for k in keys}
    first_error: str | None = None
    saw_ok = False

    for raw in per_repo_raw:
        try:
            data = json.loads(raw)
        except (ValueError, TypeError):
            continue  # a malformed per-repo payload is dropped, not allowed to crash the merge
        if not isinstance(data, dict):
            continue
        if "error" in data:
            # Remember the first error but keep scanning — another repo may have real hits.
            if first_error is None:
                first_error = raw
            continue
        saw_ok = True
        for k in keys:
            seq = data.get(k)
            if isinstance(seq, list):
                merged[k].extend(seq)

    if not saw_ok and first_error is not None:
        # Every repo errored → surface the first error rather than an empty (misleading) list.
        return first_error

    return json.dumps(merged, ensure_ascii=False)
