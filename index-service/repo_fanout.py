"""Merge per-repo codegraph results into one envelope (multi-repo fan-out, 阶段2).

When the agent asks a graph query WITHOUT naming a repo and the bridge serves multiple
repos, the bridge runs the query against EACH repo's resident session and merges the
results here. This module is the PURE merge core (no I/O, no sessions) so the corruption-
critical serving path stays thin and the merge logic is unit-testable in isolation.

Engine envelopes:
  - symbol_search  → {"results":  [...]}
  - get_callers    → {"callers":  [...]}
  - analyze_impact → {"impacted": [...], "indirect_impacted": [...], "direct_impacted": int}

Results retain repository order and the engine's ranking within each repository.
Failures and metadata retain their repository identity, even when another repository
succeeds. Aggregate counts never claim completeness when a query failed or omitted
its total. Paths have already been aligned by the bridge.
"""
from __future__ import annotations

import json
from typing import Any

# Which list key(s) each tool's envelope carries. Order matters for analyze_impact: the
# merged envelope keeps the same keys, each concatenated across repos in repo order.
#
# analyze_impact 的 direct_impacted **不在**这里：引擎返回的是一个**整数**（受影响的直接节点数），
# 不是列表。把它当列表键处理时，多仓合并会把 `15` 变成 `[]`——影响面从「15 处」变成「无影响」，
# 而单仓路径不走合并，所以这个缺陷只在多仓时出现。它现在按标量键累加，见 _SUM_KEYS。
_LIST_KEYS: dict[str, tuple[str, ...]] = {
    "codegraph_symbol_search": ("results",),
    "codegraph_get_callers": ("callers",),
    "codegraph_analyze_impact": ("impacted", "indirect_impacted"),
}

# 数值键：跨仓相加而不是拼接。
_SUM_KEYS: dict[str, tuple[str, ...]] = {
    "codegraph_analyze_impact": ("direct_impacted", "total_impacted"),
}

# 定位失败的判据。引擎定位不到起点时返回的是
#   {"callers": [], "message": "Could not find starting node ..."}
# ——isError 为 false，**没有 error 键**。只检查 `"error" in data` 会让这个载荷通过，于是
# `callers: []` 被当成事实结论「确认没有调用者」。这是本项目已确认的一类错误答案：
# 定位失败与「真的没有调用者」在下游完全无法区分，而两者的含义相反。
_LOCATE_FAILURE_MARKERS = (
    "could not find starting node",
    "could not find symbol",
    "no starting node",
    "symbol not found",
)


def _payload_error(data: dict) -> str | None:
    """返回该载荷表达的错误说明；载荷正常时返回 None。

    除了显式的 `error` 键，还识别「isError=false 但 message 说定位失败」这种形态——
    见 _LOCATE_FAILURE_MARKERS 的说明。

    **刻意不在这里判「调用图为空」**：报错仓库不会参与结果合并，而「该符号确实没有调用者」
    是完全合法的结果，把它当错误会排除这个仓库的有效结果。调用图缺失是在
    http_bridge._note_empty_call_graph 里**附加提示**处理的，不是转成错误——两者的区别是
    「让答案说得诚实」和「让结果消失」。
    """
    if "error" in data:
        return str(data.get("error"))
    msg = data.get("message")
    if isinstance(msg, str) and msg:
        low = msg.lower()
        if any(m in low for m in _LOCATE_FAILURE_MARKERS):
            return msg
    return None


def _search_counts(out: dict, payloads: list[dict], failures: bool) -> None:
    """Summarize search counts without turning missing totals into exact counts."""
    if not any(
        any(key in data for key in ("total_matches", "totalMatches", "truncated"))
        for data in payloads
    ):
        return
    shown = len(out["results"])
    total = 0
    complete = not failures
    truncated = False
    for data in payloads:
        count = len(data["results"])
        reported = data.get("total_matches", data.get("totalMatches"))
        known = (
            isinstance(reported, int)
            and not isinstance(reported, bool)
            and reported >= count
        )
        total += reported if known else count
        complete = complete and known
        truncated = truncated or data.get("truncated") is True or (
            known and reported > count
        )
    out["shown"] = shown
    out["truncated"] = truncated
    out["total_matches_complete"] = complete
    if complete:
        out["total_matches"] = total
    else:
        out["total_matches_lower_bound"] = total
    if truncated or not complete:
        count_note = str(total) if complete else f"at least {total}"
        out["truncation_note"] = (
            f"showing {shown} of {count_note} matches across repositories; "
            "these results must not be described as a complete list"
        )


def merge_fanout(
    tool_name: str, per_repo_raw: list[str], *, repo_names: list[str] | None = None
) -> str:
    """Merge a list of per-repo result JSON strings into ONE envelope for `tool_name`.

    `per_repo_raw` is in repo-declaration order; each entry is the (already path-aligned)
    JSON string that repo's session returned. Returns a single JSON envelope string with
    each list key concatenated across repos. Unknown tools retain their first payload.
    ``repo_results`` holds each repository's metadata and failures without duplicating
    its result lists. Conflicting metadata is not promoted to a misleading global value.
    """
    keys = _LIST_KEYS.get(tool_name)
    sum_keys = _SUM_KEYS.get(tool_name, ())
    if keys is None and not sum_keys:
        # Unknown tool: we don't know its shape — return the first non-empty raw verbatim.
        return per_repo_raw[0] if per_repo_raw else json.dumps({"error": "no results"})
    keys = keys or ()
    if repo_names is not None and len(repo_names) != len(per_repo_raw):
        raise ValueError("repo_names must identify every repository response")

    out: dict[str, Any] = {k: [] for k in keys}
    sums: dict[str, int | float] = {}
    metadata_values: dict[str, list[Any]] = {}
    repo_results: list[dict[str, Any]] = []
    payloads: list[dict] = []
    failures: list[dict] = []
    warnings: list[str] = []
    managed = set(keys) | set(sum_keys) | {
        "warning", "embedding_status", "embeddingStatus", "partial", "repo_results",
        "truncated", "shown", "total_matches", "totalMatches", "truncation_note",
        "total_matches_complete", "total_matches_lower_bound",
    }
    embedding_states: list[Any] = []

    for index, raw in enumerate(per_repo_raw):
        try:
            data = json.loads(raw)
        except (ValueError, TypeError):
            data = {"error": "invalid JSON response from index"}
        if not isinstance(data, dict):
            data = {"error": "index response must be an object"}
        error = _payload_error(data)
        if error is None and not isinstance(data.get(keys[0]), list):
            error = f"index response has no valid {keys[0]} list"
        metadata = {k: v for k, v in data.items() if k not in keys}
        record: dict[str, Any] = {
            "repo_index": index,
            "status": "error" if error is not None else "ok",
            "metadata": metadata,
        }
        if repo_names is not None:
            record["repo"] = repo_names[index]
        if error is not None:
            record["error"] = error
            failures.append({**data, "error": error})
        repo_results.append(record)

        warning = data.get("warning")
        if warning:
            items = warning if isinstance(warning, list) else [warning]
            for item in items:
                text = item if isinstance(item, str) else json.dumps(item, ensure_ascii=False)
                if text and text not in warnings:
                    warnings.append(text)
        state = data.get("embedding_status", data.get("embeddingStatus"))
        if state is not None and state != "" and state not in embedding_states:
            embedding_states.append(state)

        if error is not None:
            continue
        payloads.append(data)
        for k in keys:
            seq = data.get(k)
            if isinstance(seq, list):
                out[k].extend(seq)
        for k in sum_keys:
            v = data.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                sums[k] = sums.get(k, 0) + v
        for k, v in data.items():
            if k in managed or v is None or v == "":
                continue
            values = metadata_values.setdefault(k, [])
            if v not in values:
                values.append(v)

    if not payloads and failures:
        return json.dumps(
            {**failures[0], "repo_results": repo_results}, ensure_ascii=False
        )

    out.update(sums)
    for key, values in metadata_values.items():
        if key in ("call_graph_unavailable", "impact_zero_is_unverified"):
            out[key] = any(value is True for value in values)
        elif len(payloads) == 1 and not failures:
            out[key] = values[0]
    if failures:
        out["partial"] = True
        warnings.append(
            "Some repository queries failed; these results cover only successful repositories. "
            "An empty result does not prove there are no callers or impacts."
        )
    if embedding_states:
        out["embedding_status"] = (
            embedding_states[0] if len(embedding_states) == 1 else "mixed"
        )
        if len(embedding_states) > 1:
            warnings.append("Repository embedding states differ; see repo_results.")
    if warnings:
        out["warning"] = "\n".join(warnings)
    if tool_name == "codegraph_symbol_search":
        _search_counts(out, payloads, bool(failures))
    if failures or any(record["metadata"] for record in repo_results):
        out["repo_results"] = repo_results
    return json.dumps(out, ensure_ascii=False)
