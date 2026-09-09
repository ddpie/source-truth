"""Smoke test for agent.py thin shell — imports the entrypoint module and drives
run_main with a stubbed engine dispatcher (no real SDK needed).

Verifies the agent-container slice of the end-to-end path:
  payload {prompt} -> @app.entrypoint run_main -> engine_runner.run_agent -> yield
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
    import engine_runner  # noqa: PLC0415

    async def fake_run(payload):
        yield f"echo:{payload['prompt']}"

    # Inject the dispatcher stub so neither SDK runs.
    monkeypatch.setattr(engine_runner, "run_agent", fake_run)

    async def _drain():
        return [m async for m in agent.run_main({"prompt": "ping"})]

    out = asyncio.run(_drain())
    assert out == ["echo:ping"]
