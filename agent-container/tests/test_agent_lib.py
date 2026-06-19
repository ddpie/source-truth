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
def test_build_options_dict_no_builtin_tools():
    opts = agent_lib.build_options_dict(system_prompt="x")
    tools = opts["allowed_tools"]
    # EFS removed: the microVM mounts NO filesystem, so NO builtin tool is used —
    # not even Read/Glob (they hit the old /mnt/repo EFS mount). All file access
    # goes through the index-service HTTP tools. tools=[] → SDK sends --tools "".
    assert agent_lib.READONLY_TOOLS == ()
    for forbidden in ("Read", "Glob", "Grep", "Bash", "Write", "Edit"):
        assert forbidden not in tools


def test_build_options_dict_grep_replaced_by_fast_search():
    # The builtin Grep must be both ABSENT from availability and blocklisted, and
    # the fast MCP search tool present (only when a codegraph endpoint is wired).
    assert "Grep" not in agent_lib.READONLY_TOOLS
    assert "Grep" in agent_lib.WRITE_EXEC_TOOLS  # blocklisted (speed, not safety)
    opts = agent_lib.build_options_dict(system_prompt="x", codegraph_url="http://10.1.1.5:8080/mcp")
    assert "mcp__codegraph__codegraph_search_files" in opts["allowed_tools"]
    assert "Grep" in opts["disallowed_tools"]


def test_build_options_dict_read_glob_replaced_by_mcp_file_tools():
    # EFS removal: builtin Read/Glob (which hit the /mnt/repo EFS mount) are
    # blocklisted, and the index-service HTTP read_file/glob_files tools take over.
    assert "Read" not in agent_lib.READONLY_TOOLS
    assert "Glob" not in agent_lib.READONLY_TOOLS
    assert "Read" in agent_lib.WRITE_EXEC_TOOLS and "Glob" in agent_lib.WRITE_EXEC_TOOLS
    opts = agent_lib.build_options_dict(system_prompt="x", codegraph_url="http://10.1.1.5:8080/mcp")
    assert "mcp__codegraph__codegraph_read_file" in opts["allowed_tools"]
    assert "mcp__codegraph__codegraph_glob_files" in opts["allowed_tools"]
    # read_table (Excel/CSV/SQLite config tables) is also allow-listed.
    assert "mcp__codegraph__codegraph_read_table" in opts["allowed_tools"]
    assert "Read" in opts["disallowed_tools"] and "Glob" in opts["disallowed_tools"]


def test_build_options_dict_no_filesystem_mount_cwd():
    # The microVM mounts no filesystem (EFS removed), so build_options_dict must
    # NOT pin cwd to /mnt/repo. (cwd may still be set in a local dev tree where the
    # path happens to exist, but never to the removed mount.)
    opts = agent_lib.build_options_dict(system_prompt="x")
    assert opts.get("cwd") != "/mnt/repo"


def test_build_options_dict_enforces_readonly_availability():
    # The read-only boundary must be ENFORCED, not merely "not auto-approved".
    # `tools` is the SDK availability gate: with it set to the read-only set,
    # Bash/Write/Edit are never in the model's context. Asserting only their
    # absence from allowed_tools (auto-approval) would green-light an UNENFORCED
    # boundary, since unset `tools` loads the full Claude Code preset.
    opts = agent_lib.build_options_dict(system_prompt="x")
    assert opts["tools"] == list(agent_lib.READONLY_TOOLS)
    for forbidden in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"):
        assert forbidden not in opts["tools"], f"{forbidden} must not be AVAILABLE"
        assert forbidden in opts["disallowed_tools"], f"{forbidden} must be blocklisted"
    # Headless runtime: deny non-pre-approved calls, never hang on a prompt.
    assert opts["permission_mode"] == "dontAsk"
    # Only the CodeGraph MCP server we pass may load — no project/user/plugin leak.
    assert opts["strict_mcp_config"] is True
    # ISOLATION: load NO filesystem settings. Unset, the SDK loads user+project
    # settings AND project CLAUDE.md from cwd (=/mnt/repo, the attacker-influenceable
    # repo mount) as TRUSTED INSTRUCTIONS — an instruction-channel injection that
    # bypasses the in-prompt 防注入 guard. [] = full isolation; this is load-bearing.
    assert opts["setting_sources"] == []
    # Token-level streaming MUST be on, or the gateway card freezes on "正在分析…"
    # for the whole run then dumps the answer at once (no typewriter).
    assert opts["include_partial_messages"] is True


def test_build_options_dict_blocklists_codegraph_write_tools():
    # Defense-in-depth: MCP tools are NOT gated by `tools` (built-ins only) and
    # are admitted via mcp_servers, so the read-only boundary for CodeGraph rests
    # solely on "not in allowed_tools + dontAsk rejects the rest". The codegraph
    # server actually exposes write/state tools (reindex, index_*, memory_store/
    # invalidate); blocklist them explicitly so they're removed from context even
    # if a future allow-list change or preset would otherwise admit them.
    opts = agent_lib.build_options_dict(
        system_prompt="x", codegraph_url="http://10.1.1.5:8080/mcp",
    )
    for write_tool in (
        "mcp__codegraph__codegraph_reindex_workspace",
        "mcp__codegraph__codegraph_index_directory",
        "mcp__codegraph__codegraph_index_files",
        "mcp__codegraph__codegraph_index_markdown",
        "mcp__codegraph__codegraph_memory_store",
        "mcp__codegraph__codegraph_memory_invalidate",
    ):
        assert write_tool in opts["disallowed_tools"], f"{write_tool} must be blocklisted"
        assert write_tool not in opts["allowed_tools"], f"{write_tool} must not be auto-approved"


def test_build_options_dict_codegraph_tools_not_in_availability_gate():
    # `tools` governs BUILT-INS only; MCP tools arrive via mcp_servers. The
    # availability gate must stay the read-only built-in set even with CodeGraph
    # wired, while the MCP tools are auto-approved via allowed_tools.
    opts = agent_lib.build_options_dict(
        system_prompt="x", codegraph_url="http://10.1.1.5:8080/mcp",
    )
    assert opts["tools"] == list(agent_lib.READONLY_TOOLS)
    assert any(t.startswith("mcp__codegraph__") for t in opts["allowed_tools"])
    assert not any(t.startswith("mcp__codegraph__") for t in opts["tools"])


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
    # File access is via MCP tools now (EFS removed), not builtin Read.
    assert "mcp__codegraph__codegraph_read_file" in real.allowed_tools
    # The enforcing fields must round-trip onto the real options object, so the
    # CLI transport emits --tools / --disallowedTools / --permission-mode and the
    # read-only boundary is genuinely enforced (not just a dict we hand-built).
    assert real.tools == list(agent_lib.READONLY_TOOLS)
    assert "Bash" in real.disallowed_tools
    assert real.permission_mode == "dontAsk"
    assert real.strict_mcp_config is True
    # The agentic loop must be bounded (no unbounded read→grep→read runaway).
    assert real.max_turns == agent_lib.DEFAULT_MAX_TURNS


def test_build_options_dict_bounds_agentic_loop():
    # max_turns must always be set (default), and honor an explicit override.
    assert agent_lib.build_options_dict(system_prompt="x")["max_turns"] == agent_lib.DEFAULT_MAX_TURNS
    assert agent_lib.build_options_dict(system_prompt="x", max_turns=7)["max_turns"] == 7


def test_env_max_turns_resolution(monkeypatch):
    # Operator override via AGENT_MAX_TURNS; invalid/non-positive → safe default.
    monkeypatch.setenv("AGENT_MAX_TURNS", "35")
    assert agent_lib._env_max_turns() == 35
    monkeypatch.setenv("AGENT_MAX_TURNS", "0")
    assert agent_lib._env_max_turns() == agent_lib.DEFAULT_MAX_TURNS
    monkeypatch.setenv("AGENT_MAX_TURNS", "not-an-int")
    assert agent_lib._env_max_turns() == agent_lib.DEFAULT_MAX_TURNS
    monkeypatch.delenv("AGENT_MAX_TURNS", raising=False)
    assert agent_lib._env_max_turns() == agent_lib.DEFAULT_MAX_TURNS


def test_build_options_dict_no_codegraph_when_url_absent():
    opts = agent_lib.build_options_dict(system_prompt="x")
    assert opts["mcp_servers"] == {}
    assert not any(t.startswith("mcp__codegraph__") for t in opts["allowed_tools"])


def test_build_options_dict_model_passthrough():
    opts = agent_lib.build_options_dict(system_prompt="x", model="global.anthropic.claude-foo:0")
    assert opts["model"] == "global.anthropic.claude-foo:0"


def test_codegraph_url_accepts_private_ip_http():
    # The real deploy value is an in-VPC private IP http URL — must be accepted
    # (we deliberately do NOT block private ranges, that's the legit endpoint).
    opts = agent_lib.build_options_dict(
        system_prompt="x", codegraph_url="http://10.1.1.159:8080/mcp",
    )
    assert opts["mcp_servers"]["codegraph"]["url"] == "http://10.1.1.159:8080/mcp"


def test_codegraph_url_rejects_non_http_scheme():
    # Defense-in-depth: a malformed/typo'd deploy value fails loudly, not silently.
    for bad in ("file:///etc/passwd", "gopher://x", "not-a-url", "ftp://h/x"):
        with pytest.raises(ValueError):
            agent_lib.build_options_dict(system_prompt="x", codegraph_url=bad)


# ── _maybe_log_result: ResultMessage perf extraction (issue #2 instrumentation) ──
class _FakeResult:
    """Duck-typed stand-in for the SDK ResultMessage (the attrs _maybe_log_result reads)."""
    def __init__(self):
        self.num_turns = 7
        self.duration_ms = 12345
        self.duration_api_ms = 9000
        self.usage = {"input_tokens": 5000, "output_tokens": 800, "cache_read_input_tokens": 4000}
        self.is_error = False
        self.subtype = "success"


def test_maybe_log_result_emits_perf_for_resultmessage(caplog):
    import json as _json
    import logging
    with caplog.at_level(logging.INFO, logger="agent"):
        agent_lib._maybe_log_result(_FakeResult())
    rows = [_json.loads(r.message) for r in caplog.records if '"agent_result"' in r.message]
    assert len(rows) == 1, "exactly one agent_result perf line expected"
    row = rows[0]
    assert row["perf"] is True
    assert row["num_turns"] == 7
    assert row["output_tokens"] == 800
    assert row["latency_ms"] == 12345.0  # duration_ms is the headline latency


def test_maybe_log_result_ignores_non_resultmessage(caplog):
    import logging
    # An AssistantMessage-like object lacking num_turns/duration_ms must be skipped.
    class _Msg:
        content = [{"text": "hi"}]
    with caplog.at_level(logging.INFO, logger="agent"):
        agent_lib._maybe_log_result(_Msg())
    assert not any("agent_result" in r.message for r in caplog.records)


def test_maybe_log_result_never_raises_on_garbage():
    # Best-effort: a malformed message must never break the answer stream.
    for junk in (None, 42, "str", object()):
        agent_lib._maybe_log_result(junk)  # must not raise


# ── _track_tool_latency: per-tool round-trip timing (issue #2 / Grep latency) ──
class _ToolUseBlock:
    def __init__(self, tid, name):
        self.id = tid
        self.name = name
        self.input = {}


class _ToolResultBlock:
    def __init__(self, tid, is_error=False):
        self.tool_use_id = tid
        self.is_error = is_error


class _MsgWith:
    def __init__(self, content):
        self.content = content


def test_track_tool_latency_emits_one_line_per_completed_tool(caplog):
    import json as _json
    import logging
    pending: dict = {}
    with caplog.at_level(logging.INFO, logger="agent"):
        # tool_use opens (AssistantMessage), tool_result closes (UserMessage)
        agent_lib._track_tool_latency(_MsgWith([_ToolUseBlock("t1", "Grep")]), pending)
        assert "t1" in pending  # timer opened
        agent_lib._track_tool_latency(_MsgWith([_ToolResultBlock("t1")]), pending)
    assert "t1" not in pending  # timer closed
    rows = [_json.loads(r.message) for r in caplog.records if '"tool_latency"' in r.message]
    assert len(rows) == 1
    assert rows[0]["tool"] == "Grep"
    assert rows[0]["perf"] is True
    assert rows[0]["latency_ms"] >= 0


def test_track_tool_latency_ignores_unmatched_result(caplog):
    import logging
    pending: dict = {}
    with caplog.at_level(logging.INFO, logger="agent"):
        # a result with no prior tool_use → no perf line, no crash
        agent_lib._track_tool_latency(_MsgWith([_ToolResultBlock("ghost")]), pending)
    assert not any("tool_latency" in r.message for r in caplog.records)


def test_track_tool_latency_ignores_non_content_messages():
    # A message without a content list (e.g. a StreamEvent token) is skipped.
    pending: dict = {}
    for junk in (None, 42, "str", _MsgWith("not-a-list")):
        agent_lib._track_tool_latency(junk, pending)  # must not raise
    assert pending == {}
