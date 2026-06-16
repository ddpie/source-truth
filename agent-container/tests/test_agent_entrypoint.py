"""Smoke test for agent.py thin shell — imports the entrypoint module and drives
run_main with a stubbed query (no real claude_agent_sdk needed).

Verifies the agent-container slice of the end-to-end path:
  payload {prompt} -> @app.entrypoint run_main -> agent_lib.run_agent -> query -> yield
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent.parent
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))


def test_agent_module_imports_and_registers_entrypoint():
    import agent  # noqa: PLC0415

    assert hasattr(agent, "app")
    assert callable(agent.run_main)


def test_run_main_streams_via_run_agent(monkeypatch):
    import agent  # noqa: PLC0415
    import agent_lib  # noqa: PLC0415

    async def fake_query(*, prompt, options):
        yield f"echo:{prompt}"

    # Inject the stub query into run_agent so the SDK is never needed.
    orig_run_agent = agent_lib.run_agent

    def patched_run_agent(payload, **kw):
        return orig_run_agent(payload, query_fn=fake_query, **kw)

    monkeypatch.setattr(agent_lib, "run_agent", patched_run_agent)

    async def _drain():
        return [m async for m in agent.run_main({"prompt": "ping"})]

    out = asyncio.run(_drain())
    assert out == ["echo:ping"]
