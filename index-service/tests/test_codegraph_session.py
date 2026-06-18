"""Unit tests for CodegraphSession._classify — pure, no codegraph-server/network.

_classify is the health gate: it must (a) accept each exposed tool's DISTINCT
healthy envelope (symbol_search→results, get_callers→callers, analyze_impact→
impacted), including a legitimately EMPTY container, and (b) still reject genuine
breakage (isError, error field, 0-nodes, malformed). Before the tool-aware fix,
a valid get_callers/analyze_impact response was misjudged "missing a results
list" and wedged the resident session — this guards that regression offline.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")  # CodegraphSession imports mcp at module load

from codegraph_session import CodegraphSession  # noqa: E402


class _Content:
    def __init__(self, text: str) -> None:
        self.text = text


class _Result:
    """Minimal stand-in for an MCP CallToolResult."""

    def __init__(self, payload, *, is_error: bool = False) -> None:
        self.isError = is_error
        self.content = [_Content(json.dumps(payload))] if payload is not None else []


def _classify(payload, tool_name=None, *, is_error=False):
    return CodegraphSession._classify(_Result(payload, is_error=is_error), tool_name)


# ── healthy envelopes, tool-aware ───────────────────────────────────────────
def test_symbol_search_results_list_is_healthy():
    unhealthy, _ = _classify({"results": [{"symbol": {}}]}, "codegraph_symbol_search")
    assert unhealthy is False


def test_get_callers_callers_list_is_healthy():
    # No `results` key — must be accepted via the tool-aware `callers` container.
    unhealthy, reason = _classify(
        {"callers": [{"symbol": {}}], "symbol_name": "x"}, "codegraph_get_callers"
    )
    assert unhealthy is False, reason


def test_analyze_impact_impacted_list_is_healthy():
    unhealthy, reason = _classify(
        {"impacted": [{"path": "p"}], "risk_level": "low"}, "codegraph_analyze_impact"
    )
    assert unhealthy is False, reason


def test_empty_container_is_healthy_for_each_tool():
    # An empty list is a legit "no match"/"no callers" answer on a HEALTHY graph.
    assert _classify({"results": []}, "codegraph_symbol_search")[0] is False
    assert _classify({"callers": []}, "codegraph_get_callers")[0] is False
    assert _classify({"impacted": []}, "codegraph_analyze_impact")[0] is False


def test_unknown_or_missing_tool_defaults_to_symbol_search_contract():
    # warmup calls _classify with no tool name → must use the symbol_search key.
    assert _classify({"results": []})[0] is False
    assert _classify({"callers": []})[0] is True  # missing `results` under default


# ── breakage still rejected ─────────────────────────────────────────────────
def test_wrong_container_for_tool_is_unhealthy():
    # A get_callers response that somehow lacks `callers` is still unhealthy.
    unhealthy, reason = _classify({"results": []}, "codegraph_get_callers")
    assert unhealthy is True and "callers" in reason


def test_is_error_is_unhealthy():
    assert _classify({"callers": []}, "codegraph_get_callers", is_error=True)[0] is True


def test_error_field_is_unhealthy():
    assert _classify({"results": [], "error": "boom"}, "codegraph_symbol_search")[0] is True


def test_zero_nodes_warning_is_unhealthy():
    unhealthy, reason = _classify(
        {"results": [], "warning": "graph has 0 nodes"}, "codegraph_symbol_search"
    )
    assert unhealthy is True and "0 nodes" in reason


def test_malformed_json_is_unhealthy():
    bad = _Result(None)
    bad.content = [_Content("not json{")]
    assert CodegraphSession._classify(bad, "codegraph_symbol_search")[0] is True


def test_empty_content_is_unhealthy():
    assert CodegraphSession._classify(_Result(None), "codegraph_symbol_search")[0] is True
