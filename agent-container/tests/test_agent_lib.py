"""Unit tests for agent_lib pure functions — no SDK import, no network, no container.

Run: pytest agent-container/tests/  (discovered by scripts/test.sh unit layer)
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# agent_lib lives in agent-container/ (sibling of tests/); make it importable.
AGENT_DIR = Path(__file__).resolve().parent.parent
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))

import agent_lib  # noqa: E402


# ── load_system_prompt ─────────────────────────────────────────────────────
def test_load_system_prompt_reads_prompts_system_md():
    text = agent_lib.load_system_prompt()
    assert isinstance(text, str)
    assert text.strip(), "system prompt must be non-empty"


def test_load_system_prompt_encodes_code_as_truth():
    text = agent_lib.load_system_prompt()
    # Core invariant: code is the single source of truth.
    assert "代码为" in text or "code" in text.lower()


def test_load_system_prompt_accepts_custom_path(tmp_path):
    p = tmp_path / "custom.md"
    p.write_text("hello prompt", encoding="utf-8")
    assert agent_lib.load_system_prompt(p) == "hello prompt"


def test_load_system_prompt_missing_path_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        agent_lib.load_system_prompt(tmp_path / "nope.md")


# ── build_options_dict (pure, SDK-free) ────────────────────────────────────
def test_build_options_dict_readonly_tools_only():
    opts = agent_lib.build_options_dict(system_prompt="x")
    tools = opts["allowed_tools"]
    assert "Read" in tools and "Glob" in tools and "Grep" in tools
    # Read-only boundary: no write/exec tools.
    for forbidden in ("Bash", "Write", "Edit"):
        assert forbidden not in tools


def test_build_options_dict_includes_system_prompt():
    opts = agent_lib.build_options_dict(system_prompt="SYSTEM-XYZ")
    assert opts["system_prompt"] == "SYSTEM-XYZ"


def test_build_options_dict_codegraph_endpoint_adds_mcp_tools():
    opts = agent_lib.build_options_dict(
        system_prompt="x",
        codegraph_url="https://idx.internal/mcp",
    )
    # CodeGraph MCP tools must be allow-listed with the mcp__ prefix.
    assert any(t.startswith("mcp__codegraph__") for t in opts["allowed_tools"])
    assert "codegraph" in opts["mcp_servers"]
    cg = opts["mcp_servers"]["codegraph"]
    assert cg["url"] == "https://idx.internal/mcp"
    # Real McpHttpServerConfig (claude-agent-sdk 0.2.103) REQUIRES type="http".
    assert cg["type"] == "http"


def test_build_options_dict_matches_real_sdk_options():
    # The assembled dict must be accepted by the real ClaudeAgentOptions.
    sdk = pytest.importorskip("claude_agent_sdk")
    opts = agent_lib.build_options_dict(
        system_prompt="x",
        codegraph_url="https://idx.internal/mcp",
        codegraph_headers={"Authorization": "Bearer t"},
    )
    real = sdk.ClaudeAgentOptions(**opts)
    assert real.mcp_servers["codegraph"]["type"] == "http"
    assert "Read" in real.allowed_tools


def test_build_options_dict_no_codegraph_when_url_absent():
    opts = agent_lib.build_options_dict(system_prompt="x")
    assert opts["mcp_servers"] == {}
    assert not any(t.startswith("mcp__codegraph__") for t in opts["allowed_tools"])


def test_build_options_dict_model_passthrough():
    opts = agent_lib.build_options_dict(system_prompt="x", model="global.anthropic.claude-foo:0")
    assert opts["model"] == "global.anthropic.claude-foo:0"
