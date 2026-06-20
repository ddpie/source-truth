"""Offline unit tests for the bridge's server-side repo scope gate (multi-repo 不变量1 / 阶段3).

The security invariant: a tool call carrying an out-of-scope `repo` is rejected BEFORE any
session work — never routed, never falls back to another repo (the cross-project leak this
exists to stop). Runs without codegraph-server: a fake CodegraphSession lets us assert the
session was never touched on rejection, and that an in-scope / unset repo routes through with
<repo>/-prefixed paths (path honesty §4.4).
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")  # FastMCP is the only hard dep; codegraph-server is NOT needed here

import http_bridge  # noqa: E402


class _FakeSession:
    """Minimal stand-in for CodegraphSession: records call_tool invocations so a test can
    assert it was (or wasn't) reached, and returns a canned symbol_search envelope."""

    def __init__(self, workspace, **_kw):
        self.workspace = workspace
        self.calls = 0

    def start(self):  # build_bridge calls this; no worker to spawn offline
        pass

    async def call_tool(self, tool_name, arguments):
        self.calls += 1
        return '{"results": [{"symbol": {"location": {"file": "Assets/Foo.cs", "line": 3}}}]}'


def _build(monkeypatch, workspace="/data/repo/code-5x"):
    """build_bridge with the session + writer-lock faked out → fully offline."""
    sessions = {}

    def _fake_ctor(ws, **kw):
        s = _FakeSession(ws, **kw)
        sessions["s"] = s
        return s

    monkeypatch.setattr(http_bridge, "CodegraphSession", _fake_ctor)
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: None)
    app = http_bridge.build_bridge(workspace=workspace, host="127.0.0.1", port=8931)
    return app, sessions["s"]


def _tool_fn(app, name):
    return app._tool_manager.get_tool(name).fn  # type: ignore[attr-defined]


def test_out_of_scope_repo_rejected_without_touching_session(monkeypatch):
    app, session = _build(monkeypatch)
    fn = _tool_fn(app, "codegraph_symbol_search")
    out = asyncio.run(fn(query="anything", repo="other-project"))
    assert '"repo not in scope"' in out, out
    assert session.calls == 0, "an out-of-scope repo must be rejected before any session call"


def test_prefix_of_in_scope_name_rejected(monkeypatch):
    # "code-5x-svc" shares a prefix with the in-scope "code-5x" but is a DIFFERENT repo →
    # must be rejected (no substring/prefix leak).
    app, session = _build(monkeypatch)
    fn = _tool_fn(app, "codegraph_symbol_search")
    out = asyncio.run(fn(query="anything", repo="code-5x-svc"))
    assert '"repo not in scope"' in out
    assert session.calls == 0


def test_in_scope_and_unset_route_through_with_repo_prefixed_paths(monkeypatch):
    # The sole in-scope repo (explicit) and an unset repo both reach the session, and the
    # returned location is prefixed with <repo>/ so the agent can tell which repo it came from.
    app, session = _build(monkeypatch)
    fn = _tool_fn(app, "codegraph_symbol_search")
    for repo_arg in ("code-5x", None):
        out = asyncio.run(fn(query="Foo", repo=repo_arg))
        # _align_paths rewrites the location's `file` field in place with the <repo>/ prefix.
        assert '"code-5x/Assets/Foo.cs"' in out, (repo_arg, out)
    assert session.calls == 2


def test_scope_gate_applies_to_every_exposed_graph_tool(monkeypatch):
    # The gate must guard ALL graph tools, not just symbol_search — a leak on any one is a leak.
    app, session = _build(monkeypatch)
    for name in http_bridge.EXPOSED_TOOLS:
        out = asyncio.run(_tool_fn(app, name)(query="x", repo="evil-repo"))
        assert '"repo not in scope"' in out, (name, out)
    assert session.calls == 0
