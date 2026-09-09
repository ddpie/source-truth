"""SDK dispatch and terminal semantics without model/network calls."""

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent_lib  # noqa: E402
import engine_runner  # noqa: E402
from agent_settings import project_settings, runtime_settings  # noqa: E402


def test_defaults_and_legacy_migration():
    assert project_settings({}, schema_version=2).sdk == "openai"
    assert project_settings({}).sdk == "claude"
    assert project_settings({"agent": {"sdk": "openai"}}, legacy_model="anthropic.old").model.startswith("global.openai.")
    assert runtime_settings({}).sdk == "openai"
    assert runtime_settings({"ANTHROPIC_MODEL": "global.anthropic.old"}).sdk == "claude"


@pytest.mark.parametrize("agent", [
    {"sdk": "other"}, {"sdk": "openai", "model": "anthropic.wrong"},
    {"sdk": "openai", "endpoint": "mantle"}, {"sdk": "openai", "maxTurns": 0},
    {"sdk": "claude", "glossaryModel": "global.openai.wrong"},
])
def test_invalid_deployment_selection(agent):
    with pytest.raises(ValueError):
        project_settings({"agent": agent})


@pytest.mark.parametrize("complete", [True, False])
def test_claude_stream_normalized_and_payload_cannot_select_sdk(monkeypatch, complete):
    monkeypatch.setenv("AGENT_SDK", "claude")
    monkeypatch.setenv("AGENT_MODEL", "global.anthropic.claude-opus-4-8")

    async def fake(payload, **kwargs):
        yield {"event": {"type": "content_block_start", "content_block": {"type": "text"}}}
        yield {"event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "answer"}}}
        yield {"content": [{"text": "answer"}]}  # snapshot must not double
        if complete:
            yield {"num_turns": 1, "is_error": False, "result": "answer"}

    monkeypatch.setattr(agent_lib, "run_agent", fake)

    async def drain():
        return [e async for e in engine_runner.run_agent({"prompt": "x", "sdk": "openai"})]

    events = asyncio.run(drain())
    assert [e["type"] for e in events] == ["text_delta", "run_completed" if complete else "run_failed"]
    assert [e["seq"] for e in events] == [1, 2]
    assert len({e["runId"] for e in events}) == 1
