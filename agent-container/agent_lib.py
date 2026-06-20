"""Pure, side-effect-free helpers for the source-truth agent container.

Everything here is unit-testable without the Claude Agent SDK, without network,
and without a container. ``agent.py`` is a thin shell that wires these into the
``@app.entrypoint`` streaming handler (see docs/design/agent-container_zh.md §8).

Design notes:
- ``build_options_dict`` returns a plain dict (the read-only tool allow-list,
  system prompt, model, CodeGraph MCP server config). It encodes the read-only
  evidence boundary and is fully testable on its own.
- ``build_options`` adapts that dict into a real ``ClaudeAgentOptions``. The SDK
  is imported lazily inside the function so this module imports cleanly even when
  ``claude_agent_sdk`` is absent (local dev / CI without the SDK installed).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger("agent")


def _perf(event: str, ms: float, **ctx: Any) -> None:
    """Emit one structured perf-sample log line (same schema as index-service
    perf.py): {"perf":true,"event":...,"latency_ms":...,...}. grep '"perf":true'
    | jq to reconstruct the per-request three-stage timing breakdown.

    Best-effort: a non-serializable value in ctx must NEVER crash the streaming hot
    path (this is called per-message). Swallow any logging failure."""
    try:
        logger.info(json.dumps({"event": event, "perf": True, "latency_ms": round(ms, 1), **ctx}))
    except Exception:  # noqa: BLE001 - perf logging is best-effort, never break the stream
        pass

# Read-only evidence tools: NONE of the builtins. The agent microVM mounts NO
# filesystem (EFS removed) — ALL code access goes over the index-service HTTP
# bridge: codegraph_symbol_search/get_callers/analyze_impact for the graph,
# codegraph_search_files for text search, and codegraph_read_file/glob_files
# (added in the EFS-removal) replacing the builtin Read/Glob that used to hit the
# /mnt/repo EFS mount. With ``tools=[]`` the SDK sends ``--tools ""`` (verified
# against claude-agent-sdk 0.2.103 subprocess_cli), so NO builtin tool is in the
# model's context — a strictly STRONGER read-only boundary than before (not even
# a filesystem Read exists). MCP tools are admitted via mcp_servers, unaffected
# by ``--tools``.
READONLY_TOOLS: tuple[str, ...] = ()

# Write/exec built-ins that must NEVER be reachable in the read-only MVP. Setting
# ``tools`` to the read-only whitelist already removes all non-listed built-ins,
# but this explicit blocklist is defense-in-depth: even if a future SDK/CLI
# preset re-introduces one, ``disallowed_tools`` removes it from the model's
# context entirely ("cannot be used, even if they would otherwise be allowed").
# Grep is blocklisted here too: not for safety but for SPEED — it must not be a
# slow EFS fallback the model can reach; codegraph_search_files is the only search.
WRITE_EXEC_TOOLS: tuple[str, ...] = (
    "Bash",
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
    "WebFetch",
    "WebSearch",
    # Task = subagent spawn. tools=[] + dontAsk already make it unreachable, but if a
    # future SDK preset re-introduced built-ins, a live Task could spawn a subagent
    # that inherits a DIFFERENT/looser tool set — blocklist it so the read-only
    # boundary can't be re-opened transitively (cross-review, defense-in-depth).
    "Task",
    "Grep",
    # Read/Glob/LS blocklisted too: not for safety but to GUARANTEE the agent never
    # tries a filesystem read on a microVM that has NO mount (EFS removed). All file
    # access goes through codegraph_read_file/glob_files over HTTP instead. With
    # tools=[] these aren't available anyway; blocklisting removes them from the
    # model's context entirely so it never even attempts a builtin Read that would
    # just fail with no filesystem.
    "Read",
    "Glob",
    "LS",
)

# CodeGraph MCP tools, allow-listed only when a CodeGraph endpoint is provided.
# Tool name form is mcp__<server_key>__<tool_name> (double underscores, exact).
CODEGRAPH_SERVER_KEY = "codegraph"
CODEGRAPH_TOOLS: tuple[str, ...] = (
    "mcp__codegraph__codegraph_symbol_search",
    "mcp__codegraph__codegraph_get_callers",
    "mcp__codegraph__codegraph_analyze_impact",
    # Fast text search over the index-service's LOCAL repo copy (replaces the
    # slow builtin Grep). The agent uses this for config/string/numeric lookups.
    "mcp__codegraph__codegraph_search_files",
    # File read + glob over the index-service's LOCAL repo copy, replacing the
    # builtin Read/Glob that used to hit the /mnt/repo EFS mount (EFS removed —
    # the microVM mounts no filesystem, so all file access is over HTTP).
    "mcp__codegraph__codegraph_read_file",
    "mcp__codegraph__codegraph_glob_files",
    # Read STRUCTURED/binary config tables (Excel/CSV/TSV/SQLite) that read_file
    # (UTF-8 decode) can't — parsed server-side to text. Game numeric tables.
    "mcp__codegraph__codegraph_read_table",
)

# CodeGraph MCP tools with write/state side effects. MCP tools are admitted via
# mcp_servers and are NOT gated by ``tools`` (built-ins only), so the read-only
# boundary for them would otherwise rest solely on "absent from allow-list +
# dontAsk rejects the rest". Blocklisting them explicitly is defense-in-depth:
# the codegraph server exposes these (reindex/index_*/memory_*), and a future
# allow-list change or preset must not be able to admit a graph mutation.
# NOTE: this list is NOT an exhaustive enumeration of the ~50 codegraph tools — the
# AUTHORITATIVE read-only guarantee is server-side: the index-service HTTP bridge
# (http_bridge.py) is a CLOSED allowlist — it only ``add_tool``-registers 7 read-only
# tools, so no mutating codegraph tool has an MCP descriptor for the model to name at
# all. This blocklist names only the highest-risk mutators as a redundant agent-side
# guard; completeness is intentionally delegated to the bridge's closed allowlist.
CODEGRAPH_WRITE_TOOLS: tuple[str, ...] = (
    "mcp__codegraph__codegraph_reindex_workspace",
    "mcp__codegraph__codegraph_index_directory",
    "mcp__codegraph__codegraph_index_files",
    "mcp__codegraph__codegraph_index_markdown",
    "mcp__codegraph__codegraph_memory_store",
    "mcp__codegraph__codegraph_memory_invalidate",
)

DEFAULT_SYSTEM_PROMPT_PATH = Path(__file__).resolve().parent / "prompts" / "system.md"


def _validate_codegraph_url(url: str) -> None:
    """Defense-in-depth check on the CodeGraph MCP endpoint URL.

    CODEGRAPH_MCP_URL is set by the deploy operator (deploy_runtime.py), not by
    any end user, so this is NOT a user-facing injection surface — it's a guard
    against a malformed/typo'd deploy value reaching the SDK as a silent bad
    endpoint. We only enforce scheme + structure: the legitimate value is a
    PRIVATE-IP in-VPC URL (e.g. http://10.1.1.x:8080/mcp), so we deliberately do
    NOT block private ranges (that would reject the real index-service).
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"CODEGRAPH_MCP_URL must be http(s), got scheme {parsed.scheme!r}")
    if not parsed.netloc:
        raise ValueError(f"CODEGRAPH_MCP_URL has no host: {url!r}")


def load_system_prompt(path: Path | str | None = None) -> str:
    """Load the system prompt from ``prompts/system.md`` (or a custom path).

    Raises FileNotFoundError if the file does not exist — a missing system prompt
    silently degrades the agent into a generic assistant, so we fail loudly.
    """
    p = Path(path) if path is not None else DEFAULT_SYSTEM_PROMPT_PATH
    return p.read_text(encoding="utf-8")


# Agentic-loop ceiling. Must be HIGH ENOUGH for legitimate multi-step evidence
# gathering — a real "impact analysis" question runs symbol_search → several
# get_callers → analyze_impact, with model reasoning turns interleaved, which
# empirically blew past 20 (a normal question hit error_max_turns and the user
# got a truncated failure card instead of an answer). 60 gives honest queries
# headroom while still hard-capping a runaway read→grep→read loop. Tune via
# AGENT_MAX_TURNS.
DEFAULT_MAX_TURNS = 60

# COLD-START retry budget. The MCP-init race (model narrates tool calls as text
# because the CodeGraph MCP HTTP handshake hasn't registered the tools yet) is a
# WARMUP problem: the first failed attempt establishes the connection, so a retry
# usually lands warm. But back-to-back retries with NO gap can BOTH lose the race on
# a very cold VM (e.g. right after a redeploy spins fresh microVMs) — observed live
# (card st-e70f824f…): two cold attempts → honest 查询失败, but the user shouldn't
# have hit it at all. So we (a) allow up to COLD_START_MAX_RETRIES re-runs (was a
# single retry), and (b) SLEEP a short, growing backoff BEFORE each retry so the MCP
# handshake has wall-clock time to finish on the warming VM. Total added latency is
# bounded (0.8s + 1.6s = 2.4s worst case) and only paid on a genuine cold start — a
# warm run never retries. Operator-tunable via env.
COLD_START_MAX_RETRIES = 2
COLD_START_BACKOFF_BASE_S = 0.8


def _env_cold_start_retries() -> int:
    """Cold-start retry ceiling from ``COLD_START_MAX_RETRIES`` (operator-tunable).
    Falls back to the default on unset/invalid; 0 disables retries (single attempt)."""
    raw = os.environ.get("COLD_START_MAX_RETRIES")
    if raw is None:
        return COLD_START_MAX_RETRIES
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return COLD_START_MAX_RETRIES
    return n if n >= 0 else COLD_START_MAX_RETRIES


def build_options_dict(
    *,
    system_prompt: str,
    codegraph_url: str | None = None,
    codegraph_headers: dict[str, str] | None = None,
    model: str | None = None,
    max_turns: int = DEFAULT_MAX_TURNS,
) -> dict[str, Any]:
    """Assemble the option payload as a plain dict (SDK-free, pure).

    Enforces the MVP read-only boundary at the SDK level, not by hope:

    - ``tools`` (the SDK's *availability* gate) is set to exactly the read-only
      built-ins, so Bash/Write/Edit are never even in the model's context. This
      is load-bearing: with ``tools`` unset the CLI loads the full Claude Code
      preset (``--tools default``), leaving write/exec tools callable — and
      ``allowed_tools`` only governs *auto-approval*, not availability. In a
      headless microVM (no human, no ``can_use_tool`` handler) an unapproved
      call would merely be denied/hang — accidental, not enforced. We enforce.
    - ``disallowed_tools`` blocklists write/exec built-ins as defense-in-depth.
    - ``permission_mode="dontAsk"`` denies any non-pre-approved call outright
      instead of hanging on a prompt that no one can answer (NOT
      ``bypassPermissions``, which would auto-allow everything; NOT ``plan``,
      which would also block the read tools we need).
    - ``strict_mcp_config=True`` loads only the CodeGraph MCP server we pass in,
      not any project/user/plugin ``.mcp.json`` servers that could leak in extra
      tools.
    - ``max_turns`` caps the agentic loop. Unset, the SDK loop has NO ceiling, so
      a CodeGraph result that keeps pointing the model at more files could drive
      an unbounded read→grep→read loop — runaway Bedrock spend + microVM wall-time
      with the user stuck on a "thinking" card. The cap turns that into a clean
      terminal ResultMessage (``error_max_turns``) the gateway renders as a
      failure card. Operator-tunable via ``AGENT_MAX_TURNS``.

    ``allowed_tools`` (auto-approve list) mirrors the read-only set so the
    permitted tools run without prompting under ``dontAsk``. CodeGraph MCP tools
    and server config are added only when a CodeGraph endpoint URL is supplied.
    """
    tools: list[str] = list(READONLY_TOOLS)
    allowed_tools: list[str] = list(READONLY_TOOLS)
    mcp_servers: dict[str, Any] = {}

    if codegraph_url:
        _validate_codegraph_url(codegraph_url)
        # MCP tools are provided via mcp_servers and are not gated by `tools`
        # (which governs built-ins only); they still must be auto-approved.
        allowed_tools.extend(CODEGRAPH_TOOLS)
        # McpHttpServerConfig (claude-agent-sdk 0.2.103) requires type + url;
        # headers optional. Verified against the real SDK TypedDict. This is
        # design-doc §4.1 "方案 A" — native HTTP MCP, no streamablehttp bridge.
        server: dict[str, Any] = {"type": "http", "url": codegraph_url}
        if codegraph_headers:
            server["headers"] = dict(codegraph_headers)
        mcp_servers[CODEGRAPH_SERVER_KEY] = server

    opts: dict[str, Any] = {
        "system_prompt": system_prompt,
        "tools": tools,
        "allowed_tools": allowed_tools,
        "disallowed_tools": list(WRITE_EXEC_TOOLS) + list(CODEGRAPH_WRITE_TOOLS),
        "permission_mode": "dontAsk",
        "strict_mcp_config": True,
        # ISOLATION: load NO filesystem settings. With setting_sources unset the SDK
        # defaults to loading user + project settings AND project CLAUDE.md — and our
        # cwd is /mnt/repo, the attacker-influenceable repo mount. A CLAUDE.md or
        # .claude/settings.json committed into the indexed game repo would otherwise
        # be loaded as TRUSTED PROJECT INSTRUCTIONS (the instruction channel, before
        # any tool call), bypassing the 信任边界/防注入 guard in system.md (which only
        # governs content read VIA tools). The agent's ONLY instructions must be the
        # bundled system.md passed as system_prompt. [] = full isolation. (Do NOT set
        # `skills`: a non-None skills value re-defaults setting_sources to
        # user+project via the SDK's _apply_skills_defaults; an explicit [] is kept.)
        "setting_sources": [],
        "max_turns": max_turns,
        "mcp_servers": mcp_servers,
        # Stream token-level partial messages (Anthropic content_block_delta
        # events) instead of only complete messages. Without this the SDK yields
        # the final answer as ONE complete AssistantMessage at the very end, so
        # the gateway card freezes on "正在分析…" for the whole run and then dumps
        # the entire answer at once. With it, the conclusion streams token-by-
        # token → a real typewriter. The gateway's parse-stream auto-detects the
        # delta events (backward-compatible). See parse-stream.applyStreamEvent.
        "include_partial_messages": True,
    }
    if model:
        opts["model"] = model
    # NOTE: no `cwd` is set. The agent microVM mounts NO filesystem (EFS removed)
    # and has no filesystem tools (tools=[]) — there is nothing to navigate, so
    # there's no repo dir to anchor to. The old cwd=/mnt/repo anchor (which tamed a
    # reflexive relative Glob landing in /app) is obsolete: all code access is over
    # the index-service HTTP tools, which take repo-relative / mount-aligned paths
    # directly. Leaving cwd unset keeps the SDK on the process cwd (/app), which is
    # harmless since the model can't read it.
    return opts


def build_options(**kwargs: Any) -> Any:
    """Adapt :func:`build_options_dict` into a real ``ClaudeAgentOptions`` when
    the SDK is installed; otherwise return the plain options dict.

    Returning the dict as a fallback keeps the agent loop runnable/testable
    without ``claude_agent_sdk`` present (local dev / CI).
    """
    opts = build_options_dict(**kwargs)
    try:
        from claude_agent_sdk import ClaudeAgentOptions  # lazy import
    except ImportError:
        return opts
    return ClaudeAgentOptions(**opts)


def _default_query_fn() -> Any:
    """Resolve the real ``claude_agent_sdk.query`` lazily (runtime only)."""
    from claude_agent_sdk import query  # noqa: PLC0415

    return query


def _env_max_turns() -> int:
    """Resolve the agentic-loop turn cap from ``AGENT_MAX_TURNS`` (operator-tunable).

    Falls back to ``DEFAULT_MAX_TURNS`` on unset/invalid/non-positive values — the
    loop must always be bounded (an unbounded loop is the defect this guards).
    """
    raw = os.environ.get("AGENT_MAX_TURNS")
    if raw is None:
        return DEFAULT_MAX_TURNS
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_MAX_TURNS
    return n if n > 0 else DEFAULT_MAX_TURNS


async def run_agent(
    payload: dict[str, Any],
    *,
    query_fn: Any | None = None,
    model: str | None = None,
) -> AsyncIterator[Any]:
    """Testable core of the @app.entrypoint handler.

    Parse the payload, assemble read-only options (CodeGraph endpoint from env),
    drive ``query_fn`` (defaults to the real SDK ``query``), and yield each
    message through to the caller. ``session`` is treated as opaque context.

    Raises ValueError when ``payload`` is not a dict or ``prompt`` is missing/empty.
    """
    if not isinstance(payload, dict):
        raise ValueError(f"payload must be a dict, got {type(payload).__name__}")
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("payload.prompt is required and must be a non-empty string")
    # traceId forwarded by the gateway (sigv4.buildInvokeRequest) — stamp it on EVERY
    # log line this run emits so the agent's cold-start/retry/per-tool logs join the
    # gateway's invoke_timing/card_closed on a single id. Best-effort: a missing/odd
    # value degrades to "" (logs still emit, just unjoined) rather than failing the run.
    trace_id = payload.get("traceId")
    trace_id = trace_id if isinstance(trace_id, str) and trace_id else ""
    # repos: the project's repo subdir set, forwarded by the gateway (multi-repo plan 阶段1).
    # At 阶段1 the agent does NOT yet scope retrieval by it (that's 阶段2 multi-graph) — it is
    # accepted defensively (validated to a list[str], else dropped) and logged so the
    # gateway→agent contract is observable end-to-end. An unknown/odd value never breaks the run.
    repos = payload.get("repos")
    repos = [r for r in repos if isinstance(r, str)] if isinstance(repos, list) else []

    def _plog(event: str, **ctx: Any) -> None:
        """Structured warning line, trace-stamped. Mirrors _perf's swallow-all
        contract — diagnostics must never break the streaming hot path."""
        try:
            logger.warning(json.dumps({"event": event, "traceId": trace_id, **ctx}))
        except Exception:  # noqa: BLE001 - diagnostics are best-effort
            pass

    # Observe the gateway→agent project-routing contract (multi-repo 阶段1): log the repo set
    # the gateway resolved for this project, so the contract is verifiable end-to-end even
    # before 阶段2 uses it for scoping. Only when non-empty (single-repo deploy omits it).
    if repos:
        _plog("project_repos_received", repos=repos)

    options = build_options(
        system_prompt=load_system_prompt(),
        codegraph_url=os.environ.get("CODEGRAPH_MCP_URL"),
        model=model or os.environ.get("ANTHROPIC_MODEL"),
        max_turns=_env_max_turns(),
    )

    qfn = query_fn if query_fn is not None else _default_query_fn()
    # Perf: time-to-first-message (agent loop warmup + first model turn) and total
    # run (the dominant end-to-end cost — model turns + tool round-trips). Paired
    # with the gateway's invoke_timing, this localizes "where the 55s went".
    t0 = time.perf_counter()
    first_emitted = False
    n = 0
    zero_result_retrievals = 0  # run total of empty retrieval-tool results (检索空命中)
    # Per-tool latency: a tool_use block (in an AssistantMessage) opens a timer
    # keyed by its id; the matching tool_result (in a UserMessage) closes it and
    # emits a `tool_latency` perf line per call. This is what localizes "10 Grep
    # calls on EFS" vs "model thinking" — the dominant cost in live self-test.
    pending: dict[str, tuple[str, float]] = {}  # tool_use_id → (name, start)
    # MCP-INIT-RACE detection (root cause of the "raw <invoke> XML in the card"
    # bug): on a COLD microVM the claude-code subprocess can finish the model's
    # FIRST turn before the CodeGraph MCP server's HTTP handshake registers the
    # tools. The model — still seeing the tool DESCRIPTIONS in the system prompt —
    # emits tool-call XML as TEXT, and since no tools are registered there's nothing
    # to dispatch, so the run ends at num_turns<=1 with NO tool_use ever seen. That
    # first (failed) attempt DOES establish the MCP connection, so a single retry
    # lands on a now-warm connection and succeeds. We watch these signals on the
    # stream and, iff it ends in that exact shape, transparently re-run ONCE.
    # Stream live, but HOLD each attempt's messages in a small buffer UNTIL we know
    # it's not a leak — then flush + stream the rest live. Rationale: once the failed
    # attempt's messages reach the gateway they pollute the card (its narration + a
    # fake "你可能还想问" land in the 分析过程 panel, and the two attempts' text
    # concatenate). The leak shape is num_turns<=1 with NO real tool_use, so:
    #   - the MOMENT a real tool_use appears → it's NOT a leak → flush the buffer and
    #     stream every subsequent message live (typewriter preserved for the answer,
    #     which is generated AFTER the tool round-trips),
    #   - if the attempt ENDS still having seen no tool_use + emitted tool-call markup
    #     → it's the cold-start leak → DISCARD the buffer and retry once on the
    #     now-warm MCP connection.
    # The only thing not streamed live is the brief pre-first-tool narration, which is
    # tiny; the leak attempt is at most ~1 turn so its buffer is small.
    async def _drive(p: str, *, suppress_on_leak: bool) -> AsyncIterator[Any]:
        nonlocal first_emitted, saw_tool_use, saw_markup_text, last_num_turns, saw_error_result
        nonlocal zero_result_retrievals
        buf: list[Any] = []
        committed = not suppress_on_leak  # retry attempt streams immediately
        async for message in qfn(prompt=p, options=options):
            if not first_emitted:
                first_emitted = True
                _perf("agent_first_message", (time.perf_counter() - t0) * 1000, traceId=trace_id)
            zero_result_retrievals += _track_tool_latency(message, pending)
            _maybe_log_result(message)
            if _message_has_tool_use(message):
                saw_tool_use = True
            if _message_text_has_toolcall_markup(message):
                saw_markup_text = True
            # An ERRORED terminal result (is_error=True) with no tool use is the OTHER
            # cold-start failure: the SDK/CLI errored before producing an answer (e.g.
            # MCP server unreachable on a cold microVM) → out=0, turns<=1. Track it so
            # the same single retry covers it (it usually clears on a warm connection).
            if getattr(message, "is_error", None) and getattr(message, "num_turns", None) is not None:
                saw_error_result = True
            nt = getattr(message, "num_turns", None)
            if isinstance(nt, int):
                last_num_turns = nt
            if committed:
                yield message
            else:
                buf.append(message)
                # Flush + commit as soon as it CANNOT be the leak shape: either a real
                # tool_use happened, OR the loop has run >1 turn (the cold-start leak
                # is always num_turns<=1). The >1-turn guard also bounds the buffer —
                # a long tool-free multi-turn answer no longer accumulates entirely in
                # RAM / defeats the typewriter; it streams live once turn 2 starts.
                if saw_tool_use or (last_num_turns is not None and last_num_turns > 1):
                    committed = True
                    for m in buf:
                        yield m
                    buf = []
        # Stream ended. If still uncommitted, the buffer holds the whole attempt: a
        # clean short answer (no markup) is flushed; a leak (markup, no tool) is
        # dropped by NOT yielding (the caller will retry).
        if not committed and not _is_leak_shape():
            for m in buf:
                yield m

    def _is_leak_shape() -> bool:
        # Retry the cold-start failure class (≤1 turn, no real tool use) when EITHER:
        #  - the model emitted tool-call markup as text (tools weren't registered), OR
        #  - the run ended in an ERRORED empty result (SDK/MCP errored before any
        #    answer). Both usually clear on a warm retry.
        if saw_tool_use:
            return False
        if not (last_num_turns is None or last_num_turns <= 1):
            return False
        return saw_markup_text or saw_error_result

    saw_tool_use = False
    saw_markup_text = False
    saw_error_result = False
    last_num_turns: int | None = None

    max_retries = _env_cold_start_retries()
    try:
        # Bounded cold-start retry loop. Attempt 0 is the real run; each subsequent
        # attempt re-runs ONLY when the prior one is the cold-start failure shape (leak
        # markup / errored-empty / thrown-before-output), and ONLY while nothing real has
        # streamed yet (n stays 0 across cold attempts — a leak attempt's buffer is
        # DISCARDED, never yielded). Before each retry we sleep a growing backoff so the
        # MCP handshake finishes on the warming VM (the root fix for "two cold attempts
        # back-to-back both lose the race"). The moment an attempt streams real content
        # the loop is done; a warm first attempt never enters a retry.
        attempt = 0
        while True:
            retry_due_to_raise = False
            try:
                async for message in _drive(prompt, suppress_on_leak=True):
                    n += 1
                    yield message
            except Exception as exc:  # noqa: BLE001
                # A THROWN SDK/CLI exception before any output — e.g. the contradictory
                # "Claude Code returned an error result: success" a cold microVM raises
                # when its first turn fails before producing an answer (live, esp. right
                # after a redeploy spins fresh VMs). Same cold-start class as the leak/
                # errored shapes, but it ESCAPES _is_leak_shape (raised, not a message).
                # Retry ONLY if nothing streamed yet (n == 0) so we never duplicate
                # already-streamed content; otherwise surface the error.
                if n > 0:
                    raise
                retry_due_to_raise = True
                _perf("agent_attempt_raised", (time.perf_counter() - t0) * 1000, attempt=attempt, traceId=trace_id)
                _plog("agent_attempt_raised", attempt=attempt,
                      detail="cold-start exception before any output", error=str(exc)[:200])

            # Decide whether THIS attempt was a cold-start failure that warrants a retry.
            is_cold_failure = retry_due_to_raise or _is_leak_shape()
            if not is_cold_failure:
                break  # real content streamed (or a clean short answer) → done
            if attempt >= max_retries:
                # Out of retries and still cold → emit the explicit error event the
                # gateway classifies as a failure (honest 查询失败 card + retry button),
                # rather than leaving the card with no answer and no error signal.
                _perf("mcp_init_race_exhausted", (time.perf_counter() - t0) * 1000,
                      attempts=attempt + 1, num_turns=last_num_turns, traceId=trace_id)
                _plog("mcp_init_race_exhausted", attempts=attempt + 1, num_turns=last_num_turns,
                      detail="cold-start MCP tools never registered after all retries; emitting error")
                n += 1
                yield {"error": "retrieval unavailable after retries (MCP tools not registered)",
                       "error_type": "mcp_init_race", "is_error": True}
                break

            # Back off BEFORE the next attempt so the MCP handshake has time to finish.
            backoff_s = COLD_START_BACKOFF_BASE_S * (2 ** attempt)
            _perf("mcp_init_race_retry", (time.perf_counter() - t0) * 1000,
                  attempt=attempt, num_turns=last_num_turns, backoff_s=backoff_s, traceId=trace_id)
            _plog("mcp_init_race_retry", attempt=attempt, num_turns=last_num_turns,
                  backoff_s=backoff_s, reason=("thrown" if retry_due_to_raise else "leak_shape"),
                  detail="cold-start tools not registered; backing off then retrying")
            await asyncio.sleep(backoff_s)
            # Reset the per-attempt signals for the next run.
            saw_tool_use = False
            saw_markup_text = False
            saw_error_result = False
            last_num_turns = None
            # Re-arm first_emitted so agent_first_message measures the RETRY's (real)
            # first token, not a discarded cold-start attempt's leaked first message —
            # otherwise the time-to-first metric is corrupted on exactly the cold-start
            # runs it exists to measure.
            first_emitted = False
            pending.clear()  # drop the cold attempt's unclosed tool timers so they can't mis-pair
            attempt += 1
    finally:
        _perf("agent_run_total", (time.perf_counter() - t0) * 1000, messages=n,
              zeroResultRetrieval=zero_result_retrievals, traceId=trace_id)


# Matches the tool-call markup/leak the model emits as TEXT when MCP tools aren't
# registered. THREE observed shapes:
#   - Opus/Sonnet: <invoke ...> / <function_calls> (with an optional antml: prefix)
#   - Haiku 4.5:   <attempt_{toolname}> ... </attempt_{toolname}>  (different markup)
#   - Markup-LESS: the model just NARRATES calling tools ("let me call the tool",
#     mixed JA/EN deliberation) and writes a bare tool NAME like
#     `codegraph_symbol_search(...)` — no XML at all. The robust tell is the
#     codegraph_* tool name appearing in OUTPUT text: a real answer NEVER exposes an
#     internal tool name (the system prompt forbids it; answers use business words),
#     so its presence + no real tool_use = the same cold-start MCP-init race.
# All mean "model tried to retrieve but the tool wasn't registered". Detecting all
# three is required or the leak slips the retry + strip.
#     The bare-name arm requires a trailing "(" — a LEAK narration writes the tool
#     as a CALL "codegraph_x(...)", whereas a legit dev-review citation writes it as
#     `codegraph_x` / "用 codegraph_x 去读" (no paren). Anchoring on "(" avoids
#     wrongly retrying a tool-free answer that merely NAMES a tool in prose.
#     NOTE (cross-review weighed): a mid-prose `codegraph_x(...)` could in theory be a
#     non-compliant answer that CITES a tool with parens (false positive). We KEEP
#     matching it anyway: (a) the system prompt forbids exposing tool names in answers,
#     so a compliant answer never contains it; (b) the false-positive only costs ONE
#     extra retry on a ≤1-turn tool-free answer; (c) the gateway strips such leaks
#     downstream regardless. Missing a real bare-name leak (no retry, raw call text in
#     the card) is the worse failure, so the broad match wins.
#   - FOURTH observed shape (live, cold VM): the model narrates the call in mixed
#     JA/EN + a "Tool call:" label + a ```json args block, e.g.
#         codegraph_symbol_search を呼びます。
#         **Tool call: codegraph_symbol_search**
#         ```json … ```
#     No XML, no "(" after the name — so the bare-name "(" arm missed it and it leaked
#     raw onto the card (cross-review: card st-96f2a7f42c25). Add arms for: a literal
#     "Tool call:" / "tool_use" label, the Japanese call verb (を呼/呼び), and the raw
#     mcp__ name. CUE SET KEPT NARROW (cross-review P1): the ambiguous `call|调用|調用`
#     verbs were DROPPED — they are normal review vocabulary (调用链 / "the call returns")
#     and a reproducibly tool-citing legit answer would otherwise retry twice then fail.
#     This MIRRORS the gateway's strip-toolcall-leak BARE_TOOLCALL_RE so the two detectors
#     agree on what counts as a leak. The residual zh cold-start narration (`调用
#     codegraph_x` with no paren) is caught downstream by the gateway zeroToolLeak
#     backstop (0 tool calls + a bare tool name), not by an agent retry.
_TOOLCALL_MARKUP_RE = re.compile(
    r"<(?:antml:)?invoke\b"
    r"|(?:antml:)?function_calls\b"
    r"|<attempt_[a-zA-Z0-9_]+\b"
    r"|\bcodegraph_[a-z_]+\s*\("                       # bare CALL with args
    r"|\bcodegraph_[a-z_]+\s*(?:を\s*呼|呼び)"           # name THEN Japanese call verb (…を呼びます)
    r"|^\s*\**Tool[ _]call\b"                          # "Tool call:" / "**Tool call**" label line
    r"|\bmcp__codegraph__[a-z_]+\b",                   # the raw internal mcp__ name never appears in a real answer
    re.IGNORECASE | re.MULTILINE,
)


def _message_has_tool_use(message: Any) -> bool:
    """True if the message carries a REAL tool_use block (a tool was actually
    dispatched). Duck-typed on id + name: a tool_use block has both; a tool_result
    block has tool_use_id + content (NO name); a text block has neither. We do NOT
    also require `input` non-None — a legit no-argument tool call has input={} or
    None, and requiring it would silently miss that call (dropping it from leak
    detection AND tool-latency)."""
    try:
        content = getattr(message, "content", None)
        if not isinstance(content, (list, tuple)):
            return False
        for block in content:
            if (getattr(block, "id", None) is not None
                    and getattr(block, "name", None) is not None):
                return True
    except Exception:  # noqa: BLE001 - detection must never break the stream
        return False
    return False


def _message_text_has_toolcall_markup(message: Any) -> bool:
    """True if the message's TEXT content contains tool-call markup (the model
    emitting <invoke>/<function_calls> as prose because no tools were registered).
    Duck-typed over a content-block list (AssistantMessage) or a bare ``.text``
    attribute (a TextBlock).

    NOTE: a token-delta ``StreamEvent`` has NEITHER ``.content`` NOR ``.text`` (its
    fields are uuid/session_id/event/parent_tool_use_id), so leak markup arriving via
    streaming deltas is NOT seen here — detection relies on the COMPLETE
    ``AssistantMessage`` the SDK emits at each turn boundary (which carries the full
    ``.content``). That turn-end message is what `_drive` keys the leak decision off,
    and the leaked first attempt is buffered (never streamed) until then, so the gap is
    covered for the cold-start race. If a future SDK ever stops emitting the per-turn
    AssistantMessage (pure-delta streaming), this detector would go blind — guard that
    assumption if the SDK contract changes."""
    try:
        content = getattr(message, "content", None)
        blocks = content if isinstance(content, (list, tuple)) else [message]
        for block in blocks:
            text = getattr(block, "text", None)
            if isinstance(text, str) and _TOOLCALL_MARKUP_RE.search(text):
                return True
    except Exception:  # noqa: BLE001 - detection must never break the stream
        return False
    return False


# Retrieval tools whose EMPTY result is the "检索空命中" signal (correlates with index
# staleness / blind spots). Read/glob/table tools are NOT retrieval — they return file content,
# so their "empty" (an empty file) is not a retrieval miss and must not be counted. Matched by
# suffix so it's independent of the mcp__codegraph__ prefix.
_RETRIEVAL_TOOL_SUFFIXES: tuple[str, ...] = (
    "symbol_search", "get_callers", "analyze_impact", "search_files",
)


def _result_block_text(block: Any) -> str:
    """Best-effort extract the textual payload of a tool_result block. The SDK may put the
    tool's return as a bare string in `.content`, or as a list of {type:text, text:...} blocks.
    Returns "" on any shape we don't recognize (so callers never crash on it)."""
    content = getattr(block, "content", None)
    if isinstance(content, str):
        return content
    if isinstance(content, (list, tuple)):
        parts = []
        for c in content:
            t = getattr(c, "text", None)
            if t is None and isinstance(c, dict):
                t = c.get("text")
            if isinstance(t, str):
                parts.append(t)
        return "".join(parts)
    return ""


# The result-container keys each retrieval tool puts its hits under (verified live against
# codegraph-server 0.18.5, see index-service/codegraph_session.py): an EMPTY one of these = a
# confirmed no-match. symbol_search→results, get_callers→callers, analyze_impact→impacted,
# search_files→matches. ALL FOUR must be checked, or empties from callers/impacted are missed.
_RETRIEVAL_RESULT_KEYS: tuple[str, ...] = ("results", "callers", "impacted", "matches")


def _is_empty_retrieval(name: str, block: Any) -> bool:
    """True iff `name` is a RETRIEVAL tool AND its result is a confirmed no-match. No-match shapes:
      - found-but-empty → {"results"|"callers"|"impacted"|"matches": []}
      - symbol itself not resolvable → {"error": "...symbol not found", ...}
    An is_error result is a per-tool FAILURE (counted as toolErrors), not an empty hit → excluded.

    CRITICAL ordering: parse JSON and check the result CONTAINER first; a non-empty container is a
    HIT, return False immediately. Only then consult the `error` field for the "symbol not found"
    no-match. The "symbol not found" phrase must be matched ONLY inside the error field, never in
    the raw payload — a search_files HIT embeds matched source-line text, which can legitimately
    contain that phrase (e.g. a comment), and a raw-substring check would miscount the hit as empty
    (cross-review HIGH). read_file/glob/table are excluded by the suffix gate above."""
    if not any(name.endswith(s) for s in _RETRIEVAL_TOOL_SUFFIXES):
        return False
    if getattr(block, "is_error", None):
        return False  # a failure, not an empty hit
    text = _result_block_text(block)
    if not text:
        return False
    stripped = text.strip()
    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
        except (ValueError, TypeError):
            obj = None
        if isinstance(obj, dict):
            # HIT wins: any non-empty result container → definitely not empty.
            for k in _RETRIEVAL_RESULT_KEYS:
                v = obj.get(k)
                if isinstance(v, list) and v:
                    return False
            # Empty container → no-match.
            for k in _RETRIEVAL_RESULT_KEYS:
                if isinstance(obj.get(k), list):  # present but empty (the `and v` above ruled out non-empty)
                    return True
            # No result container: a no-match only if the ERROR field says "symbol not found"
            # (scoped to error so a hit's matched-line text can't trigger it).
            err = obj.get("error")
            if isinstance(err, str) and "symbol not found" in err:
                return True
            return False
    # Non-JSON payload: be conservative — only the explicit graph "symbol not found" envelope is
    # JSON, so a non-JSON shape we don't recognize is NOT counted (avoids guessing).
    return False


def _track_tool_latency(message: Any, pending: dict[str, tuple[str, float]]) -> int:
    """Time each tool round-trip: open a timer on a tool_use block, close + emit a
    `tool_latency` perf line on the matching tool_result. Best-effort + duck-typed
    (no SDK import); a shape we don't recognize is simply ignored. The per-tool
    breakdown (esp. Grep/Read on EFS vs codegraph MCP) is the issue-#2 lever for
    deciding whether to cut tool calls or speed up file I/O.

    Returns the number of EMPTY-RETRIEVAL results closed by this message (a retrieval tool that
    came back with no match -- the 检索空命中 signal, correlates with index staleness/blind spots).
    The caller accumulates it across the run and surfaces a run total. Telemetry only.
    """
    empty_retrievals = 0
    try:
        content = getattr(message, "content", None)
        if not isinstance(content, (list, tuple)):
            return 0
        now = time.perf_counter()
        for block in content:
            tool_id = getattr(block, "id", None)
            name = getattr(block, "name", None)
            # tool_use = id + name (a tool_result has tool_use_id + content, no name).
            # Don't require input non-None — a no-arg tool call would be missed.
            if tool_id is not None and name is not None:
                pending[tool_id] = (name, now)  # tool_use opened
                continue
            result_id = getattr(block, "tool_use_id", None)
            if result_id is not None and result_id in pending:
                name, start = pending.pop(result_id)
                empty = _is_empty_retrieval(name, block)
                if empty:
                    empty_retrievals += 1
                _perf("tool_latency", (now - start) * 1000, tool=name,
                      is_error=getattr(block, "is_error", None), empty_retrieval=empty)
    except Exception as exc:  # noqa: BLE001 - perf logging must never break the stream
        logger.warning(json.dumps({"event": "tool_latency_log_failed", "error": str(exc)}))
    return empty_retrievals


def _maybe_log_result(message: Any) -> None:
    """If this is the SDK's terminal ResultMessage, emit its rich perf numbers.

    ResultMessage carries exactly the metrics needed to optimize latency vs native
    cc (issue #2): num_turns (agent-turn count — "few deep turns vs many round-
    trips"), duration_ms / duration_api_ms (model+API wall time vs total →
    separates model thinking from tool round-trips), and usage.output_tokens (→
    output tokens/sec). Native cc prints these same numbers at the end of a run,
    so this is the apples-to-apples comparison data. Duck-typed (num_turns +
    duration_ms) so this module stays SDK-import-free for unit tests; any non-
    ResultMessage simply lacks the attributes and is skipped. Best-effort: a
    malformed message must never break the answer stream."""
    try:
        num_turns = getattr(message, "num_turns", None)
        duration_ms = getattr(message, "duration_ms", None)
        if num_turns is None or duration_ms is None:
            return  # not a ResultMessage
        usage = getattr(message, "usage", None) or {}
        get = usage.get if isinstance(usage, dict) else (lambda _k: None)
        _perf(
            "agent_result",
            float(duration_ms),
            duration_api_ms=getattr(message, "duration_api_ms", None),
            num_turns=num_turns,
            input_tokens=get("input_tokens"),
            output_tokens=get("output_tokens"),
            cache_read_input_tokens=get("cache_read_input_tokens"),
            is_error=getattr(message, "is_error", None),
            subtype=getattr(message, "subtype", None),
        )
        # On an ERRORED result, also log the result text (the SDK puts the failure
        # reason in `.result`) so an is_error=True/out=0 cold-start failure is
        # diagnosable — the structured perf line alone doesn't say WHY.
        if getattr(message, "is_error", None):
            detail = getattr(message, "result", None)
            logger.warning(json.dumps({
                "event": "agent_result_error",
                "subtype": getattr(message, "subtype", None),
                "num_turns": num_turns,
                "detail": str(detail)[:500] if detail is not None else None,
            }))
    except Exception as exc:  # noqa: BLE001 - perf logging must never break the stream
        logger.warning(json.dumps({"event": "agent_result_log_failed", "error": str(exc)}))
