"""引擎契约五条缺陷的回归测试。

这五条的共同点是**都产出用户可见的错误答案，且没有任何一环报错**——所以它们只能靠断言判据本身来
守住，端到端冒烟测不出来（答案看起来完全正常）。每条测试都写清它在防什么形态。
"""

from __future__ import annotations

import json

import pytest

from codegraph_session import CodegraphSession
from http_bridge import _parse_symbol_location, _pick_symbol_match
from repo_fanout import merge_fanout


# ---------------------------------------------------------------- 6. 截断与 call_site 语义
def test_search_truncation_is_surfaced() -> None:
    """引擎把 results 截断在 20 条并用 total_matches 报真实命中数（实测见过 67）。

    此前 total_matches 在整个 bridge 里出现 0 次，agent 只看到 20 条却无从知道被截断，
    于是答案写出「共找到 20 处」——一个具体、可信、且错的数字。
    """
    from http_bridge import _align_paths

    raw = json.dumps({"results": [{"symbol": {"name": f"s{i}"}} for i in range(20)],
                      "total_matches": 67})
    out = json.loads(_align_paths(raw, "codegraph_symbol_search", index_root="/w", repo=""))
    assert out["truncated"] is True
    assert out["shown"] == 20 and out["total_matches"] == 67
    assert "at least 20" in out["truncation_note"]


def test_no_truncation_note_when_all_matches_returned() -> None:
    """没被截断时不得加噪声——否则每条答案都会带一句无意义的提示。"""
    from http_bridge import _align_paths

    raw = json.dumps({"results": [{"symbol": {"name": "s"}}], "total_matches": 1})
    out = json.loads(_align_paths(raw, "codegraph_symbol_search", index_root="/w", repo=""))
    assert "truncation_note" not in out
    assert out.get("truncated") is not True


def test_call_site_line_semantics_are_labelled() -> None:
    """call_site.line 指向**调用者的声明行**，不是调用发生的行。

    载荷里此前只有一个裸 line，agent 只能理解成「调用在这一行」，照它写出的出处指向一个与调用
    无关的位置——出处看起来精确，实际错位，没有任何一环报错。
    """
    from http_bridge import _align_paths

    raw = json.dumps({"callers": [{"symbol": {"name": "Caller",
                                              "location": {"file": "/w/a.cs", "line": 10}},
                                   "call_site": {"file": "/w/a.cs", "line": 7}}]})
    out = json.loads(_align_paths(raw, "codegraph_get_callers", index_root="/w", repo=""))
    cs = out["callers"][0]["call_site"]
    assert cs["caller_declaration_line"] == 7
    assert "not the line where the call occurs" in cs["line_semantics"]
    assert cs["line"] == 7, "不改写引擎给的事实，只补充语义"


# ---------------------------------------------------------------- 1. results[0] 取错符号
def test_exact_name_match_beats_semantic_first_result() -> None:
    """0.20.1 的语义回退会把非精确匹配排在前面。

    实测形态：查 `to_container_path`，首条结果是
    `test_backslash_path_normalized_to_forward_slash`（语义近似的测试函数）。取 results[0] 后
    get_callers 返回 []，而空列表在回答里被当成权威结论「没有任何地方调用它」——答案完全错，
    却没有任何一环报错。
    """
    results = [
        {"symbol": {"name": "test_backslash_path_normalized_to_forward_slash",
                    "location": {"file": "/w/tests/test_paths.py", "line": 41}},
         "match_reason": "Semantic", "score": 0.41},
        {"symbol": {"name": "to_container_path",
                    "location": {"file": "/w/path_align.py", "line": 89}},
         "match_reason": "SymbolName", "score": 0.93},
    ]
    picked = _pick_symbol_match(results, "to_container_path")
    assert picked is not None
    assert picked["symbol"]["name"] == "to_container_path"


def test_semantic_only_results_are_rejected_not_guessed() -> None:
    """全是语义近似、没有精确匹配时，宁可报「没找到」也不猜。

    猜一个近似符号会让下游得出一个**看起来确定**的错误结论；报没找到只是没答上。
    """
    results = [
        {"symbol": {"name": "SomethingElse", "location": {"file": "/w/a.py", "line": 3}},
         "match_reason": "Semantic", "score": 0.38},
        {"symbol": {"name": "AlsoNotIt", "location": {"file": "/w/b.py", "line": 9}},
         "match_reason": "Semantic", "score": 0.42},
    ]
    assert _pick_symbol_match(results, "to_container_path") is None
    with pytest.raises(ValueError, match="closely enough"):
        _parse_symbol_location(json.dumps({"results": results}), "to_container_path")


def test_high_score_accepted_when_engine_gives_no_match_reason() -> None:
    """老引擎不给 match_reason 时靠 score 阈值兜底（实测精确 0.75-0.97 / 噪声 0.33-0.43）。"""
    results = [{"symbol": {"name": "MaxEncumbrance",
                           "location": {"file": "/w/F.cs", "line": 75}}, "score": 0.88}]
    picked = _pick_symbol_match(results, "MaxEncumbrance")
    assert picked is not None and picked["symbol"]["name"] == "MaxEncumbrance"


def test_echoed_symbol_name_mismatch_disqualifies_a_result() -> None:
    """引擎回显的 symbol_name 与 symbol.name 不一致，说明这条结果不是在讲这个符号。"""
    results = [{"symbol": {"name": "Other", "location": {"file": "/w/a.py", "line": 1}},
                "symbol_name": "MaxEncumbrance", "match_reason": "SymbolName", "score": 0.9}]
    assert _pick_symbol_match(results, "MaxEncumbrance") is None


# ---------------------------------------------------------------- 2. direct_impacted 是 int
def test_direct_impacted_is_summed_not_concatenated() -> None:
    """引擎返回的 direct_impacted 是**整数**，不是列表。

    此前它被列在 _LIST_KEYS 里，于是多仓合并把 `15` 变成 `[]`——影响面从「15 处」变成「无影响」。
    单仓不走合并，所以这个缺陷只在多仓时出现，也就更难被发现。
    """
    a = json.dumps({"impacted": [{"path": "a.cs"}], "direct_impacted": 15, "total_impacted": 40})
    b = json.dumps({"impacted": [{"path": "b.cs"}], "direct_impacted": 7, "total_impacted": 12})
    out = json.loads(merge_fanout("codegraph_analyze_impact", [a, b]))
    assert out["direct_impacted"] == 22, "整数键必须相加"
    assert out["total_impacted"] == 52
    assert len(out["impacted"]) == 2, "列表键仍然拼接"


def test_single_repo_direct_impacted_survives() -> None:
    out = json.loads(merge_fanout("codegraph_analyze_impact",
                                  [json.dumps({"impacted": [], "direct_impacted": 15})]))
    assert out["direct_impacted"] == 15


# ---------------------------------------------------------------- 3. 标量键被丢弃
def test_warning_survives_multi_repo_merge() -> None:
    """合并此前只重建列表键，于是**所有标量一律丢失**，包括引擎用来告知「索引可能没建好」的 warning。

    后果是单仓能透传这句警告，多仓反而吞掉——而仓库越多，某个仓索引没建好的概率越大，
    正是更需要这句警告的场合。
    """
    a = json.dumps({"results": [{"symbol": {"name": "A"}}],
                    "warning": "index may not be built for this repo"})
    b = json.dumps({"results": [{"symbol": {"name": "B"}}]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert out["warning"] == "index may not be built for this repo"
    assert len(out["results"]) == 2


def test_scalar_does_not_overwrite_list_or_sum_keys() -> None:
    """标量保留不能破坏列表/数值键——否则修一个缺陷引入另一个。"""
    a = json.dumps({"impacted": [{"path": "a"}], "direct_impacted": 3, "note": "n1"})
    out = json.loads(merge_fanout("codegraph_analyze_impact", [a]))
    assert isinstance(out["impacted"], list)
    assert out["direct_impacted"] == 3
    assert out["note"] == "n1"


# ---------------------------------------------------------------- 4. 定位失败被读成「无调用者」
def test_locate_failure_is_treated_as_an_error() -> None:
    """引擎定位不到起点时返回 {"callers": [], "message": "Could not find starting node ..."}，
    isError 为 false 且**没有 error 键**。

    只检查 `"error" in data` 会让它通过，于是 `callers: []` 被当成事实结论「确认没有调用者」。
    这两件事的含义完全相反，而下游无法区分。
    """
    fail = json.dumps({"callers": [],
                       "message": "Could not find starting node for symbol 'Foo'"})
    ok = json.dumps({"callers": [{"symbol": {"name": "Bar"}}]})
    out = json.loads(merge_fanout("codegraph_get_callers", [fail, ok]))
    assert len(out["callers"]) == 1, "定位失败的那个仓不应贡献空列表"

    # 所有仓都定位失败时，必须把失败原文透出，而不是回一个空列表
    only_fail = merge_fanout("codegraph_get_callers", [fail])
    assert "Could not find starting node" in only_fail


def test_genuine_empty_callers_is_not_an_error() -> None:
    """真的没有调用者是正常结果，不能被当成失败——否则修一个缺陷造出反向的假阳性。"""
    empty = json.dumps({"callers": []})
    out = json.loads(merge_fanout("codegraph_get_callers", [empty]))
    assert out["callers"] == []
    assert "error" not in out


# ---------------------------------------------------------------- 5. embedding_status 无人读
@pytest.mark.parametrize("state", ["building", "pending", "failed", "not_ready"])
def test_embedding_degradation_detected(state: str) -> None:
    """引擎用 embedding_status 报告向量索引状态，此前在整个 index-service 里出现 0 次。

    降级期间语义匹配不可用、检索质量下降，但 /health 照样 200、日志无痕迹——运维只会看到
    「机器人今天答得不太准」。
    """
    assert CodegraphSession._embedding_degradation({"embedding_status": state}) is not None


def test_embedding_ready_is_not_degraded() -> None:
    for ok in ({"embedding_status": "ready"}, {"embedding_status": "complete"}, {}):
        assert CodegraphSession._embedding_degradation(ok) is None


def test_embedding_status_object_form() -> None:
    got = CodegraphSession._embedding_degradation(
        {"embedding_status": {"status": "building", "progress": 0.4}})
    assert got is not None and "0.4" in got


def test_embedding_degradation_is_not_unhealthy() -> None:
    """降级不得计入不健康：那会让 /health 变红并触发重启，而重启让索引从头再建，
    反而延长降级窗口。"""
    payload = {"results": [], "embedding_status": "building", "nodeCount": 1200}

    class _C:
        text = json.dumps(payload)

    class _R:
        isError = False
        content = [_C()]

    unhealthy, reason = CodegraphSession._classify(_R(), "codegraph_symbol_search")
    assert unhealthy is False, f"降级被误判为不健康: {reason}"
