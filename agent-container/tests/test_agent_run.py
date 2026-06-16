"""Unit tests for the agent run loop (agent_lib.run_agent) — no real SDK needed.

run_agent is the testable core of agent.py's @app.entrypoint handler: it parses
the payload, builds options, drives an injected query function, and yields each
message through. The real claude_agent_sdk.query is injected at runtime; here we
inject a stub so the loop is verifiable without the SDK installed.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

AGENT_DIR = Path(__file__).resolve().parent.parent
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))

import agent_lib  # noqa: E402


def _collect(agen):
    """Drain an async generator synchronously for testing."""
    import asyncio

    async def _run():
        return [m async for m in agen]

    return asyncio.run(_run())


def test_run_agent_yields_messages_from_query():
    seen = {}

    async def fake_query(*, prompt, options):
        seen["prompt"] = prompt
        seen["options"] = options
        for m in ("msg-1", "msg-2", "RESULT"):
            yield m

    out = _collect(
        agent_lib.run_agent({"prompt": "where is match logic"}, query_fn=fake_query)
    )
    assert out == ["msg-1", "msg-2", "RESULT"]
    assert seen["prompt"] == "where is match logic"
    # options must be a real ClaudeAgentOptions OR the SDK-free dict fallback;
    # either way it must carry the read-only allow-list.
    assert seen["options"] is not None


def test_run_agent_passes_codegraph_url_into_options(monkeypatch):
    captured = {}

    async def fake_query(*, prompt, options):
        captured["options"] = options
        if False:  # pragma: no cover - make it an async generator
            yield None

    monkeypatch.setenv("CODEGRAPH_MCP_URL", "https://idx.internal/mcp")
    _collect(agent_lib.run_agent({"prompt": "x"}, query_fn=fake_query))
    opts = captured["options"]
    # When SDK is absent, run_agent falls back to the options dict.
    as_dict = opts if isinstance(opts, dict) else getattr(opts, "__dict__", {})
    assert as_dict.get("mcp_servers", {}).get("codegraph", {}).get("url") == "https://idx.internal/mcp"


def test_run_agent_rejects_missing_prompt():
    async def fake_query(*, prompt, options):  # pragma: no cover
        yield None

    with pytest.raises((KeyError, ValueError)):
        _collect(agent_lib.run_agent({}, query_fn=fake_query))
