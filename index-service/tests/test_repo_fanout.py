"""Unit tests for repo_fanout.merge_fanout — pure multi-repo result merge (阶段2).

No sessions, no codegraph. Asserts: repo-order preservation, per-tool envelope shapes,
errored-repo handling (one repo's error never blanks others; all-errored surfaces an
error), and malformed-input robustness.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

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
    assert out["direct_impacted"] == []  # key always present even if no repo had it


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
