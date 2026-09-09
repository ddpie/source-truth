"""Unit tests for repo_fanout.merge_fanout — pure multi-repo result merge (阶段2).

No sessions, no codegraph. Asserts: repo-order preservation, per-tool envelope shapes,
errored-repo handling (one repo's error never blanks others; all-errored surfaces an
error), and malformed-input robustness.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

from repo_fanout import merge_fanout  # noqa: E402


def _sym(file, line=1):
    return {"symbol": {"location": {"file": file, "line": line}}}


# ── symbol_search: concatenate results in repo order ─────────────────────────
def test_symbol_search_concatenates_in_repo_order():
    a = json.dumps({"results": [_sym("repoA/x.cs"), _sym("repoA/y.cs")]})
    b = json.dumps({"results": [_sym("repoB/z.cs")]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    files = [r["symbol"]["location"]["file"] for r in out["results"]]
    assert files == ["repoA/x.cs", "repoA/y.cs", "repoB/z.cs"], files


def test_symbol_search_empty_repos_yield_empty_results():
    a = json.dumps({"results": []})
    b = json.dumps({"results": []})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert out == {"results": []}


# ── get_callers ──────────────────────────────────────────────────────────────
def test_get_callers_merges_callers_key():
    a = json.dumps({"callers": [_sym("repoA/a.cs")]})
    b = json.dumps({"callers": [_sym("repoB/b.cs"), _sym("repoB/c.cs")]})
    out = json.loads(merge_fanout("codegraph_get_callers", [a, b]))
    assert len(out["callers"]) == 3
    assert out["callers"][0]["symbol"]["location"]["file"] == "repoA/a.cs"


# ── analyze_impact: all three list keys merged, each in repo order ───────────
def test_analyze_impact_merges_all_impact_keys():
    a = json.dumps({"impacted": [{"path": "repoA/a.cs"}], "indirect_impacted": [{"path": "repoA/i.cs"}]})
    b = json.dumps({"impacted": [{"path": "repoB/b.cs"}], "indirect_impacted": []})
    out = json.loads(merge_fanout("codegraph_analyze_impact", [a, b]))
    assert [x["path"] for x in out["impacted"]] == ["repoA/a.cs", "repoB/b.cs"]
    assert [x["path"] for x in out["indirect_impacted"]] == ["repoA/i.cs"]
    # direct_impacted 不再出现在这里：引擎返回的是**整数**（直接受影响的节点数），不是列表。
    # 这条断言原本写的是 `out["direct_impacted"] == []`，等于把缺陷本身固化成期望——真实载荷里
    # 的 `15` 会被合并成 `[]`，影响面从「15 处」变成「无影响」。它现在按数值键相加，
    # 由 tests/test_engine_contract.py::test_direct_impacted_is_summed_not_concatenated 覆盖。
    assert "direct_impacted" not in out, "本例的两个仓都没给这个键，不应凭空造一个"


# ── errored repos ─────────────────────────────────────────────────────────────
def test_one_repo_error_does_not_blank_the_others():
    # repoA errored (transient), repoB has real hits → merge keeps repoB's results.
    a = json.dumps({"error": "index unavailable", "detail": "warming up"})
    b = json.dumps({"results": [_sym("repoB/z.cs")]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert [r["symbol"]["location"]["file"] for r in out["results"]] == ["repoB/z.cs"]
    assert "error" not in out


def test_all_repos_errored_surfaces_first_error():
    # If EVERY repo errored, return an error (not an empty list the agent would misread
    # as "no matches" — code is the only truth, so a broken index must say so).
    a = json.dumps({"error": "index unavailable", "detail": "A"})
    b = json.dumps({"error": "index unavailable", "detail": "B"})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert out.get("error") == "index unavailable"
    assert out.get("detail") == "A"  # FIRST error surfaced


# ── robustness ─────────────────────────────────────────────────────────────────
def test_malformed_per_repo_payload_is_dropped_not_crashing():
    a = "not json at all"
    b = json.dumps({"results": [_sym("repoB/z.cs")]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert [r["symbol"]["location"]["file"] for r in out["results"]] == ["repoB/z.cs"]


def test_non_dict_payload_dropped():
    a = json.dumps(["a", "list", "not", "a", "dict"])
    b = json.dumps({"results": [_sym("repoB/z.cs")]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a, b]))
    assert len(out["results"]) == 1


def test_unknown_tool_returns_first_raw_unchanged():
    a = json.dumps({"weird": [1, 2, 3]})
    b = json.dumps({"weird": [4]})
    out = merge_fanout("codegraph_unknown_tool", [a, b])
    assert json.loads(out) == {"weird": [1, 2, 3]}


def test_empty_input_list_yields_empty_envelope():
    out = json.loads(merge_fanout("codegraph_symbol_search", []))
    # no repos to merge → empty results (the per-tool shape), not a crash
    assert out == {"results": []}


def test_single_repo_passthrough_shape_preserved():
    # The common N=1-via-fanout case: one repo, merged shape identical to its input shape.
    a = json.dumps({"results": [_sym("repoA/x.cs", 9)]})
    out = json.loads(merge_fanout("codegraph_symbol_search", [a]))
    assert out["results"][0]["symbol"]["location"] == {"file": "repoA/x.cs", "line": 9}


def _merge(tool, *payloads):
    return json.loads(merge_fanout(
        tool, [json.dumps(p) for p in payloads],
        repo_names=[f"repo-{index}" for index in range(len(payloads))],
    ))


def test_partial_locate_failure_cannot_be_read_as_no_callers():
    out = _merge(
        "codegraph_get_callers",
        {"callers": [], "message": "Could not find starting node for Foo"},
        {"callers": [], "diagnostic": {"node_found": True}},
    )
    assert out["callers"] == []
    assert out["partial"] is True
    assert "error" not in out  # The successful repository remains usable.
    assert "does not prove" in out["warning"]
    assert out["repo_results"][0]["repo"] == "repo-0"
    assert out["repo_results"][0]["status"] == "error"
    assert "starting node" in out["repo_results"][0]["error"]
    assert out["repo_results"][1]["metadata"]["diagnostic"] == {"node_found": True}
    assert "diagnostic" not in out  # One repository's location is not a global finding.


@pytest.mark.parametrize("states", [("ready", "building"), ("building", "ready")])
def test_ready_repository_cannot_hide_degraded_embedding(states):
    out = _merge(
        "codegraph_symbol_search",
        *({"results": [], "embedding_status": state} for state in states),
    )
    assert out["embedding_status"] == "mixed"
    assert [r["metadata"]["embedding_status"] for r in out["repo_results"]] == list(states)
    assert "embedding states differ" in out["warning"]


def test_embedding_objects_and_all_repository_warnings_survive():
    state = {"status": "building", "progress": 0.4}
    out = _merge(
        "codegraph_symbol_search",
        {"results": [], "embedding_status": state, "warning": "A: graph incomplete"},
        {"results": [], "warning": "B: semantic search unavailable"},
    )
    assert out["embedding_status"] == state
    assert out["repo_results"][0]["metadata"]["embedding_status"] == state
    assert "A: graph incomplete" in out["warning"]
    assert "B: semantic search unavailable" in out["warning"]


def test_failed_repository_metadata_is_retained():
    out = _merge(
        "codegraph_symbol_search",
        {"error": "index unavailable", "embedding_status": {"status": "failed"},
         "warning": "index needs rebuilding"},
        {"results": [_sym("repo-1/a.cs")], "embedding_status": "ready"},
    )
    assert len(out["results"]) == 1
    assert out["partial"] is True
    assert out["embedding_status"] == "mixed"
    assert "index needs rebuilding" in out["warning"]
    assert out["repo_results"][0]["metadata"]["embedding_status"] == {"status": "failed"}


def test_truncation_totals_describe_the_merged_list():
    out = _merge(
        "codegraph_symbol_search",
        *({"results": [_sym(f"{repo}/{i}.cs") for i in range(20)],
           "total_matches": total, "shown": 20, "truncated": True,
           "truncation_note": f"showing 20 of {total}"}
          for repo, total in [("repo-0", 30), ("repo-1", 40)]),
    )
    assert len(out["results"]) == out["shown"] == 40
    assert out["total_matches"] == 70
    assert out["truncated"] is True
    assert out["total_matches_complete"] is True
    assert "showing 40 of 70" in out["truncation_note"]
    assert [r["metadata"]["total_matches"] for r in out["repo_results"]] == [30, 40]


def test_later_repository_truncation_is_not_hidden_by_first_false():
    out = _merge(
        "codegraph_symbol_search",
        {"results": [_sym("repo-0/a.cs")], "total_matches": 1, "truncated": False},
        {"results": [_sym("repo-1/b.cs")], "total_matches": 8, "truncated": True},
    )
    assert out["truncated"] is True
    assert out["shown"] == 2 and out["total_matches"] == 9


@pytest.mark.parametrize("missing", [{}, {"total_matches": True}, {"total_matches": 0}])
def test_missing_or_invalid_total_is_only_a_lower_bound(missing):
    out = _merge(
        "codegraph_symbol_search",
        {"results": [_sym("repo-0/a.cs")], "total_matches": 3},
        {"results": [_sym("repo-1/b.cs")], **missing},
    )
    assert "total_matches" not in out
    assert out["total_matches_complete"] is False
    assert out["total_matches_lower_bound"] == 4
    assert out["shown"] == 2
    assert "at least 4" in out["truncation_note"]


def test_failed_repository_prevents_an_exact_global_search_total():
    out = _merge(
        "codegraph_symbol_search",
        {"results": [_sym("repo-0/a.cs")], "total_matches": 3},
        {"error": "index unavailable"},
    )
    assert out["partial"] is True
    assert "total_matches" not in out
    assert out["total_matches_lower_bound"] == 3
    assert out["total_matches_complete"] is False


def test_camel_case_total_matches_is_normalized():
    out = _merge(
        "codegraph_symbol_search",
        {"results": [_sym("repo-0/a.cs")], "totalMatches": 2},
        {"results": [_sym("repo-1/b.cs")], "total_matches": 3},
    )
    assert out["total_matches"] == 5
    assert out["shown"] == 2
    assert "totalMatches" not in out


def test_repository_diagnostics_are_not_presented_as_global():
    out = _merge(
        "codegraph_get_callers",
        {"callers": [], "diagnostic": {"node_found": True}, "call_graph_unavailable": False},
        {"callers": [], "diagnostic": {"node_found": False}, "call_graph_unavailable": True},
    )
    assert "diagnostic" not in out
    assert out["call_graph_unavailable"] is True
    assert [r["metadata"]["diagnostic"]["node_found"] for r in out["repo_results"]] == [True, False]


@pytest.mark.parametrize("raw", ["invalid json", "[]", "{}"])
def test_all_invalid_responses_cannot_be_reported_as_empty_success(raw):
    out = json.loads(merge_fanout("codegraph_symbol_search", [raw, raw]))
    assert out["error"]
    assert all(r["status"] == "error" for r in out["repo_results"])


def test_all_location_failures_have_an_explicit_tool_error():
    out = _merge(
        "codegraph_get_callers",
        {"callers": [], "message": "Could not find starting node for Foo"},
        {"callers": [], "message": "Could not find symbol Foo"},
    )
    assert "starting node" in out["error"]
    assert len(out["repo_results"]) == 2


def test_repository_names_must_match_response_count():
    with pytest.raises(ValueError, match="every repository response"):
        merge_fanout("codegraph_symbol_search", ['{"results": []}'], repo_names=[])
