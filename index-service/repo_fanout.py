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
    """
    if "error" in data:
        return str(data.get("error"))
    msg = data.get("message")
    if isinstance(msg, str) and msg:
        low = msg.lower()
        if any(m in low for m in _LOCATE_FAILURE_MARKERS):
            return msg
    return None


def merge_fanout(tool_name: str, per_repo_raw: list[str]) -> str:
    """Merge a list of per-repo result JSON strings into ONE envelope for `tool_name`.

    `per_repo_raw` is in repo-declaration order; each entry is the (already path-aligned)
    JSON string that repo's session returned. Returns a single JSON envelope string with
    each list key concatenated across repos. Unknown tools / unparseable inputs fall back
    to the first entry unchanged (never corrupt what we don't understand).

    标量键（`warning`、`embedding_status` 之类）会被保留。此前只重建列表键，于是**所有标量
    一律丢失**——包括引擎在索引未建好时用来告知的 `warning`。后果是单仓能把这句警告透传出来，
    多仓反而吞掉，而仓库越多、某个仓没建好索引的概率越大，正是更需要这句警告的场合。
    """
    keys = _LIST_KEYS.get(tool_name)
    sum_keys = _SUM_KEYS.get(tool_name, ())
    if keys is None and not sum_keys:
        # Unknown tool: we don't know its shape — return the first non-empty raw verbatim.
        return per_repo_raw[0] if per_repo_raw else json.dumps({"error": "no results"})
    keys = keys or ()

    merged: dict[str, list[Any]] = {k: [] for k in keys}
    sums: dict[str, int | float] = {}
    scalars: dict[str, Any] = {}
    first_error: str | None = None
    saw_ok = False

    for raw in per_repo_raw:
        try:
            data = json.loads(raw)
        except (ValueError, TypeError):
            continue  # a malformed per-repo payload is dropped, not allowed to crash the merge
        if not isinstance(data, dict):
            continue
        if _payload_error(data) is not None:
            # Remember the first error but keep scanning — another repo may have real hits.
            if first_error is None:
                first_error = raw
            continue
        saw_ok = True
        for k in keys:
            seq = data.get(k)
            if isinstance(seq, list):
                merged[k].extend(seq)
        for k in sum_keys:
            v = data.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                sums[k] = sums.get(k, 0) + v
        # 其余标量键：保留第一个非空值。多仓下取第一个而不是拼接，因为像 warning 这样的
        # 提示语拼接起来只会变噪声；关键是它不能消失。
        for k, v in data.items():
            if k in merged or k in sum_keys or k in scalars:
                continue
            if isinstance(v, (list, dict)):
                continue
            if v is None or v == "":
                continue
            scalars[k] = v

    if not saw_ok and first_error is not None:
        # Every repo errored → surface the first error rather than an empty (misleading) list.
        return first_error

    out: dict[str, Any] = dict(merged)
    out.update(sums)
    # 标量放在最后合并，且不覆盖列表/数值键
    for k, v in scalars.items():
        out.setdefault(k, v)
    return json.dumps(out, ensure_ascii=False)
