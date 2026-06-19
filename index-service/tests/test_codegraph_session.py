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


# ── health AND-gates on a live worker thread (subprocess-death defense) ──────
def test_healthy_is_false_when_worker_thread_is_dead():
    # A subprocess that dies while idle could leave _healthy True between liveness
    # probe ticks; /health must still report unhealthy because the worker thread
    # is gone. The `healthy` property AND-gates on a live thread to guarantee that.
    sess = CodegraphSession("/tmp/ws")
    sess._healthy = True  # flag says healthy …
    assert sess._thread is None  # … but no worker thread was ever started
    assert sess.healthy is False  # AND-gate → reported unhealthy

    class _DeadThread:
        def is_alive(self) -> bool:
            return False

    sess._thread = _DeadThread()  # type: ignore[assignment]
    assert sess.healthy is False  # dead thread → unhealthy even with _healthy True


def test_needs_restart_when_thread_dead_or_wedged():
    sess = CodegraphSession("/tmp/ws")
    # No thread yet → needs (re)start.
    assert sess._needs_restart() is True

    class _LiveThread:
        def is_alive(self) -> bool:
            return True

    sess._thread = _LiveThread()  # type: ignore[assignment]
    # Alive but warmup not finished (_ready unset) → still coming up, do NOT restart.
    sess._ready.clear()
    assert sess._needs_restart() is False
    # Alive, warmup finished, but unhealthy → wedged → needs restart.
    sess._ready.set()
    sess._healthy = False
    assert sess._needs_restart() is True


def test_liveness_tolerates_a_single_transient_blip():
    # A single bad probe must NOT exit the worker (no full cold restart over a
    # transient GC pause / a heavy query that held the lock past the probe timeout).
    n, should_exit = CodegraphSession._record_probe(0, bad=True)
    assert (n, should_exit) == (1, False)  # 1 failure < threshold(2) → stay alive
    # A good probe immediately after clears the streak.
    n, should_exit = CodegraphSession._record_probe(n, bad=False)
    assert (n, should_exit) == (0, False)


def test_liveness_exits_after_consecutive_failures():
    # Sustained failure (a real subprocess death) fails every probe → exit once the
    # streak reaches the threshold, so /health tracks reality within ~10s.
    n, should_exit = CodegraphSession._record_probe(0, bad=True)
    assert should_exit is False
    n, should_exit = CodegraphSession._record_probe(n, bad=True)
    assert (n, should_exit) == (2, True)  # 2 consecutive → worker exits → restart


def test_reap_orphan_servers_kills_only_own_children(monkeypatch):
    # _reap_orphan_servers must SIGKILL codegraph-server children of THIS pid found
    # by pgrep, and never raise. Mock pgrep output + os.kill.
    import codegraph_session as cs

    killed = []

    class _Out:
        stdout = "12345\n67890\n"

    monkeypatch.setattr(cs.subprocess, "run", lambda *a, **k: _Out())
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    cs.CodegraphSession._reap_orphan_servers()
    assert (12345, cs.signal.SIGKILL) in killed
    assert (67890, cs.signal.SIGKILL) in killed


def test_reap_orphan_servers_never_raises(monkeypatch):
    import codegraph_session as cs

    # pgrep itself blowing up must be swallowed (best-effort).
    def _boom(*a, **k):
        raise OSError("pgrep missing")

    monkeypatch.setattr(cs.subprocess, "run", _boom)
    cs.CodegraphSession._reap_orphan_servers()  # must not raise

    # An already-gone pid (ProcessLookupError) is the normal case, also swallowed.
    class _Out:
        stdout = "999999\n"

    def _gone(pid, sig):
        raise ProcessLookupError()

    monkeypatch.setattr(cs.subprocess, "run", lambda *a, **k: _Out())
    monkeypatch.setattr(cs.os, "kill", _gone)
    cs.CodegraphSession._reap_orphan_servers()  # must not raise
