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
    for forbidden in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "Task"):
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


# ── MCP-init-race detection + retry (the "raw <invoke> XML in card" root cause) ──
class _TextBlock:
    def __init__(self, text):
        self.text = text


class _ResultMsg:
    def __init__(self, num_turns, is_error=False):
        self.num_turns = num_turns
        self.is_error = is_error


def test_message_has_tool_use_detects_real_dispatch():
    assert agent_lib._message_has_tool_use(_MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])) is True
    # A text-only message (model emitting markup as prose) is NOT a real tool_use.
    assert agent_lib._message_has_tool_use(_MsgWith([_TextBlock("<invoke name=\"x\">")])) is False
    assert agent_lib._message_has_tool_use(_MsgWith("not-a-list")) is False


def test_message_has_tool_use_detects_a_NO_INPUT_tool_call():
    # A real no-argument tool call has input=None/{} — keying on id+name (not input)
    # must still detect it, else it's silently dropped from leak detection + latency.
    class _NoInputToolUse:
        def __init__(self):
            self.id = "t9"
            self.name = "codegraph_list"
            self.input = None  # no-arg tool
    assert agent_lib._message_has_tool_use(_MsgWith([_NoInputToolUse()])) is True
    # A tool_result block (tool_use_id + content, NO name) is NOT a tool_use.
    assert agent_lib._message_has_tool_use(_MsgWith([_ToolResultBlock("t9")])) is False


def test_message_text_has_toolcall_markup_matches_bare_and_antml():
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("先搜一下\n<invoke name=\"codegraph_search_files\">")])) is True
    # antml: namespace prefix (the dominant real Claude shape)
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("<" + "antml:invoke name=\"x\">")])) is True
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("function" + "_calls")])) is True
    # Haiku 4.5 shape: <attempt_{toolname}> ... </attempt_{toolname}>
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("先查\n<attempt_codegraph_symbol_search>\n{}")])) is True
    # Markup-LESS variant: the model narrates calling the tool by NAME without any
    # XML ("Let me call codegraph_symbol_search"). A real answer never names an
    # internal tool, so this is a leak tell.
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("Let me call codegraph_symbol_search(query=\"LevelUp\")")])) is True
    # FOURTH shape (live cold-VM, card st-96f2a7f42c25): JA/EN narration + "Tool call:"
    # label + a tool name with a "calling" cue, no XML, no "(".
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("codegraph_symbol_search を呼びます。")])) is True
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("**Tool call: codegraph_symbol_search**")])) is True
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("mcp__codegraph__codegraph_read_file")])) is True
    # A clean answer that merely mentions the word invoke/attempt is NOT markup.
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("这个函数会 invoke 回调")])) is False
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("第一次 attempt 失败后重试")])) is False
    # FALSE-POSITIVE GUARD (cross-review P1): the ambiguous call-cues 调用/調用/call were
    # dropped from the cue set because they are normal review vocabulary. A legitimate
    # dev-review citation that names a tool next to 调用链 / "call returns" must NOT be
    # flagged as a leak (the residual zh cold-start narration is caught by the gateway's
    # zeroToolLeak backstop instead). Only an UNAMBIGUOUS cue — "(" or the Japanese 呼 —
    # still counts.
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("研发可查 codegraph_search_files 调用链确认")])) is False
    assert agent_lib._message_text_has_toolcall_markup(_MsgWith([_TextBlock("the codegraph_search_files call returns a list")])) is False


def test_run_agent_retries_on_haiku_attempt_leak():
    # Haiku's <attempt_tool> leak shape must also trigger the retry.
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] == 1:
            yield _MsgWith([_TextBlock("先定位\n<attempt_codegraph_symbol_search>\n{\"pattern\":\"负重\"}\n</attempt_codegraph_symbol_search>")])
            yield _ResultMsg(num_turns=1)
        else:
            yield _MsgWith([_ToolUseBlock("t1", "codegraph_symbol_search")])
            yield _MsgWith([_TextBlock("负重上限 = 力量 × 1.5。")])
            yield _ResultMsg(num_turns=3)

    msgs = _collect(agent_lib.run_agent({"prompt": "负重上限"}, query_fn=fake_query))
    assert calls["n"] == 2, "haiku attempt-leak must retry once"
    texts = [getattr(b, "text", "") for m in msgs for b in getattr(m, "content", []) or [] if hasattr(b, "text")]
    assert any(s.startswith("负重上限 =") for s in texts)
    assert not any("attempt_" in s for s in texts), "failed haiku attempt must be discarded"


def _collect(agen):
    import asyncio

    async def _run():
        out = []
        async for m in agen:
            out.append(m)
        return out

    return asyncio.run(_run())


def test_run_agent_retries_once_on_mcp_init_race(monkeypatch):
    # Attempt 1: leak shape — text with <invoke> markup, NO tool_use, num_turns=1.
    # Attempt 2 (retry): real tool_use + a healthy result. The retry must fire and
    # its messages must be yielded after the failed attempt's.
    async def _no_sleep(_s):
        return None
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _no_sleep)  # skip the cold-start backoff
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] == 1:
            yield _MsgWith([_TextBlock("先搜一下\n<invoke name=\"codegraph_search_files\">")])
            yield _ResultMsg(num_turns=1)
        else:
            yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
            yield _MsgWith([_TextBlock("怪物生命值写在 EnemyBasics.cs。")])
            yield _ResultMsg(num_turns=4)

    msgs = _collect(agent_lib.run_agent({"prompt": "怪物生命值怎么设定"}, query_fn=fake_query))
    assert calls["n"] == 2, "must retry exactly once on the leak shape"

    def _texts(ms):
        out = []
        for m in ms:
            for b in getattr(m, "content", []) or []:
                tx = getattr(b, "text", None)
                if isinstance(tx, str):
                    out.append(tx)
        return out

    yielded = _texts(msgs)
    # The retry's real answer must be present in the yielded stream.
    assert any(s.startswith("怪物生命值写在") for s in yielded)
    # CRITICAL: the FAILED attempt's leaked-markup narration must NOT be yielded —
    # otherwise it pollutes the 分析过程 panel (the live-observed bug). The buffer
    # for a leak attempt is DISCARDED, not flushed.
    assert not any("先搜一下" in s or "<invoke" in s for s in yielded), \
        "failed-attempt narration must be discarded, not yielded"


def test_run_agent_emits_error_when_ALL_attempts_leak(monkeypatch):
    # EVERY attempt is a cold-start leak (MCP never registered: index-service down, or a
    # string of cold VMs). No attempt may be streamed raw (that would hand the gateway
    # dirty <invoke> markup + a clean ResultMessage → rendered as a finish); instead the
    # agent exhausts its bounded retry budget and emits ONE error event so the gateway
    # shows an honest failure card. With COLD_START_MAX_RETRIES re-runs the total attempt
    # count is 1 + retries; the backoff sleep is monkeypatched to 0 to keep the test fast.
    monkeypatch.setattr(agent_lib, "_env_cold_start_retries", lambda: 2)

    async def _no_sleep(_s):
        return None
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _no_sleep)

    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        # Same leak shape on EVERY attempt.
        yield _MsgWith([_TextBlock("先搜一下\n<invoke name=\"codegraph_search_files\">")])
        yield _ResultMsg(num_turns=1)

    msgs = _collect(agent_lib.run_agent({"prompt": "x"}, query_fn=fake_query))
    assert calls["n"] == 3, "must run the initial attempt + 2 cold-start retries"
    # An error event (top-level error string, no content array) must be emitted ONCE.
    errs = [m for m in msgs if isinstance(m, dict) and m.get("error")]
    assert len(errs) == 1, "a single error event must be emitted when all attempts leak"
    assert errs[0].get("is_error") is True
    # The leaked narration from neither attempt may be yielded.
    texts = []
    for m in msgs:
        for b in getattr(m, "content", []) or []:
            tx = getattr(b, "text", None)
            if isinstance(tx, str):
                texts.append(tx)
    assert not any("先搜一下" in s or "<invoke" in s for s in texts), \
        "neither leaked attempt may reach the stream"


def test_run_agent_retries_once_on_thrown_cold_start_exception(monkeypatch):
    # Attempt 1 RAISES before any output (the contradictory CLI error
    # "Claude Code returned an error result: success" on a cold microVM). This
    # escapes _is_leak_shape (it's a raised exception, not a message), so the retry
    # must be driven by the n==0 thrown-exception path. Attempt 2 succeeds.
    async def _no_sleep(_s):
        return None
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _no_sleep)
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("Claude Code returned an error result: success")
            yield  # pragma: no cover - makes this an async generator
        yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
        yield _MsgWith([_TextBlock("耐力影响负重和疲劳。")])
        yield _ResultMsg(num_turns=3)

    msgs = _collect(agent_lib.run_agent({"prompt": "耐力的作用"}, query_fn=fake_query))
    assert calls["n"] == 2, "a thrown cold-start exception before any output must retry once"
    texts = []
    for m in msgs:
        for b in getattr(m, "content", []) or []:
            tx = getattr(b, "text", None)
            if isinstance(tx, str):
                texts.append(tx)
    assert any(s.startswith("耐力影响") for s in texts), "retry's real answer must be yielded"


def test_run_agent_does_not_retry_thrown_exception_after_output():
    # If attempt 1 already yielded real content THEN raised, we must NOT retry
    # (would duplicate streamed content) — the exception propagates.
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
        yield _MsgWith([_TextBlock("部分答案……")])
        raise RuntimeError("mid-stream blow up")

    import pytest
    with pytest.raises(RuntimeError):
        _collect(agent_lib.run_agent({"prompt": "x"}, query_fn=fake_query))
    assert calls["n"] == 1, "must NOT retry once real content was already streamed"


def test_run_agent_does_not_retry_on_healthy_run():
    # A healthy run (real tool_use, multi-turn) must NOT trigger a retry.
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        yield _MsgWith([_ToolUseBlock("t1", "codegraph_read_file")])
        yield _MsgWith([_TextBlock("答案在这里。")])
        yield _ResultMsg(num_turns=5)

    _collect(agent_lib.run_agent({"prompt": "x"}, query_fn=fake_query))
    assert calls["n"] == 1, "healthy run must not retry"


def test_run_agent_retries_on_errored_empty_result(monkeypatch):
    # The OTHER cold-start failure: is_error=True, out=0, num_turns=1, no tool_use,
    # no markup (the SDK/MCP errored before any answer). Must retry once.
    async def _no_sleep(_s):
        return None
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _no_sleep)
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] == 1:
            yield _ResultMsg(num_turns=1, is_error=True)  # errored empty result
        else:
            yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
            yield _MsgWith([_TextBlock("升级每级加 1 点力量。")])
            yield _ResultMsg(num_turns=3)

    msgs = _collect(agent_lib.run_agent({"prompt": "力量怎么长"}, query_fn=fake_query))
    assert calls["n"] == 2, "errored empty cold-start result must retry once"
    texts = [getattr(b, "text", "") for m in msgs for b in getattr(m, "content", []) or [] if hasattr(b, "text")]
    assert any(s.startswith("升级每级加") for s in texts)


def test_run_agent_does_not_retry_when_no_markup():
    # num_turns=1 but NO tool-call markup (a legit short answer) → no retry.
    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        yield _MsgWith([_TextBlock("这个值是 100。")])
        yield _ResultMsg(num_turns=1)

    _collect(agent_lib.run_agent({"prompt": "x"}, query_fn=fake_query))
    assert calls["n"] == 1, "a clean short answer must not retry"


def test_run_agent_recovers_on_second_retry_after_two_cold_attempts(monkeypatch):
    # ROOT-FIX regression: the live failure (card st-e70f824f…) was TWO back-to-back
    # cold attempts both losing the MCP-init race. With a bounded backoff retry budget,
    # a VM that's still cold on attempt 2 but warm by attempt 3 must now SUCCEED instead
    # of surfacing 查询失败. Also asserts the backoff sleep is actually awaited between
    # cold attempts (the wall-clock that lets the handshake finish).
    monkeypatch.setattr(agent_lib, "_env_cold_start_retries", lambda: 2)
    sleeps = []

    async def _rec_sleep(s):
        sleeps.append(s)
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _rec_sleep)

    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] <= 2:  # first two attempts: cold-start leak
            yield _MsgWith([_TextBlock("先搜一下\n<invoke name=\"codegraph_search_files\">")])
            yield _ResultMsg(num_turns=1)
        else:  # third attempt: warm, real answer
            yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
            yield _MsgWith([_TextBlock("背包上限是力量 × 1.5。")])
            yield _ResultMsg(num_turns=4)

    msgs = _collect(agent_lib.run_agent({"prompt": "背包上限"}, query_fn=fake_query))
    assert calls["n"] == 3, "must keep retrying through two cold attempts to the warm one"
    # Backoff grew between attempts and was awaited twice (before retry 1 and retry 2).
    assert sleeps == [agent_lib.COLD_START_BACKOFF_BASE_S,
                      agent_lib.COLD_START_BACKOFF_BASE_S * 2], "backoff must grow per retry"
    texts = [getattr(b, "text", "") for m in msgs for b in getattr(m, "content", []) or [] if hasattr(b, "text")]
    assert any(s.startswith("背包上限是力量") for s in texts), "the warm attempt's answer must be yielded"
    # No error event — it recovered.
    assert not any(isinstance(m, dict) and m.get("error") for m in msgs)
    # The discarded cold attempts' leaked narration must NOT leak into the stream.
    assert not any("先搜一下" in s or "<invoke" in s for s in texts)


def test_run_agent_stamps_traceid_on_logs(monkeypatch, caplog):
    # traceId from the payload must appear on the agent's structured logs so they join
    # the gateway's lines on one id. A cold-start run exercises the warn path too.
    monkeypatch.setattr(agent_lib, "_env_cold_start_retries", lambda: 1)

    async def _no_sleep(_s):
        return None
    monkeypatch.setattr(agent_lib.asyncio, "sleep", _no_sleep)

    calls = {"n": 0}

    async def fake_query(prompt, options):
        calls["n"] += 1
        if calls["n"] == 1:
            yield _MsgWith([_TextBlock("先搜\n<invoke name=\"codegraph_search_files\">")])
            yield _ResultMsg(num_turns=1)
        else:
            yield _MsgWith([_ToolUseBlock("t1", "codegraph_search_files")])
            yield _MsgWith([_TextBlock("答案。")])
            yield _ResultMsg(num_turns=3)

    import logging as _logging
    with caplog.at_level(_logging.WARNING, logger="agent"):
        _collect(agent_lib.run_agent(
            {"prompt": "x", "traceId": "st-abc123"}, query_fn=fake_query))
    # The retry warn line must carry the trace id.
    retry_lines = [r.getMessage() for r in caplog.records if "mcp_init_race_retry" in r.getMessage()]
    assert retry_lines, "a cold-start retry must have been logged"
    assert any('"trace": "st-abc123"' in line for line in retry_lines), \
        "the traceId must be stamped on the agent's retry log"
