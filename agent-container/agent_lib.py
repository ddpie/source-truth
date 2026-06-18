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

import json
import logging
import os
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger("agent")


def _perf(event: str, ms: float, **ctx: Any) -> None:
    """Emit one structured perf-sample log line (same schema as index-service
    perf.py): {"perf":true,"event":...,"latency_ms":...,...}. grep '"perf":true'
    | jq to reconstruct the per-request three-stage timing breakdown."""
    logger.info(json.dumps({"event": event, "perf": True, "latency_ms": round(ms, 1), **ctx}))

# Read-only evidence tools (no Bash/Write/Edit — read-only boundary, MVP).
READONLY_TOOLS: tuple[str, ...] = ("Read", "Glob", "Grep")

# Write/exec built-ins that must NEVER be reachable in the read-only MVP. Setting
# ``tools`` to the read-only whitelist already removes all non-listed built-ins,
# but this explicit blocklist is defense-in-depth: even if a future SDK/CLI
# preset re-introduces one, ``disallowed_tools`` removes it from the model's
# context entirely ("cannot be used, even if they would otherwise be allowed").
WRITE_EXEC_TOOLS: tuple[str, ...] = (
    "Bash",
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
    "WebFetch",
    "WebSearch",
)

# CodeGraph MCP tools, allow-listed only when a CodeGraph endpoint is provided.
# Tool name form is mcp__<server_key>__<tool_name> (double underscores, exact).
CODEGRAPH_SERVER_KEY = "codegraph"
CODEGRAPH_TOOLS: tuple[str, ...] = (
    "mcp__codegraph__codegraph_symbol_search",
    "mcp__codegraph__codegraph_get_callers",
    "mcp__codegraph__codegraph_analyze_impact",
)

# CodeGraph MCP tools with write/state side effects. MCP tools are admitted via
# mcp_servers and are NOT gated by ``tools`` (built-ins only), so the read-only
# boundary for them would otherwise rest solely on "absent from allow-list +
# dontAsk rejects the rest". Blocklisting them explicitly is defense-in-depth:
# the codegraph server exposes these (reindex/index_*/memory_*), and a future
# allow-list change or preset must not be able to admit a graph mutation.
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
        "max_turns": max_turns,
        "mcp_servers": mcp_servers,
    }
    if model:
        opts["model"] = model
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
    try:
        async for message in qfn(prompt=prompt, options=options):
            if not first_emitted:
                first_emitted = True
                _perf("agent_first_message", (time.perf_counter() - t0) * 1000)
            n += 1
            yield message
    finally:
        _perf("agent_run_total", (time.perf_counter() - t0) * 1000, messages=n)
