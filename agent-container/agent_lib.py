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

import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

# Read-only evidence tools (no Bash/Write/Edit — read-only boundary, MVP).
READONLY_TOOLS: tuple[str, ...] = ("Read", "Glob", "Grep")

# CodeGraph MCP tools, allow-listed only when a CodeGraph endpoint is provided.
# Tool name form is mcp__<server_key>__<tool_name> (double underscores, exact).
CODEGRAPH_SERVER_KEY = "codegraph"
CODEGRAPH_TOOLS: tuple[str, ...] = (
    "mcp__codegraph__codegraph_symbol_search",
    "mcp__codegraph__codegraph_get_callers",
    "mcp__codegraph__codegraph_analyze_impact",
)

DEFAULT_SYSTEM_PROMPT_PATH = Path(__file__).resolve().parent / "prompts" / "system.md"


def load_system_prompt(path: Path | str | None = None) -> str:
    """Load the system prompt from ``prompts/system.md`` (or a custom path).

    Raises FileNotFoundError if the file does not exist — a missing system prompt
    silently degrades the agent into a generic assistant, so we fail loudly.
    """
    p = Path(path) if path is not None else DEFAULT_SYSTEM_PROMPT_PATH
    return p.read_text(encoding="utf-8")


def build_options_dict(
    *,
    system_prompt: str,
    codegraph_url: str | None = None,
    codegraph_headers: dict[str, str] | None = None,
    model: str | None = None,
) -> dict[str, Any]:
    """Assemble the option payload as a plain dict (SDK-free, pure).

    The allow-list always includes the read-only built-in tools and never the
    write/exec ones. CodeGraph MCP tools and server config are added only when a
    CodeGraph endpoint URL is supplied.
    """
    allowed_tools: list[str] = list(READONLY_TOOLS)
    mcp_servers: dict[str, Any] = {}

    if codegraph_url:
        allowed_tools.extend(CODEGRAPH_TOOLS)
        server: dict[str, Any] = {"url": codegraph_url}
        if codegraph_headers:
            server["headers"] = dict(codegraph_headers)
        mcp_servers[CODEGRAPH_SERVER_KEY] = server

    opts: dict[str, Any] = {
        "system_prompt": system_prompt,
        "allowed_tools": allowed_tools,
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

    Raises ValueError when ``prompt`` is missing/empty.
    """
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("payload.prompt is required and must be a non-empty string")

    options = build_options(
        system_prompt=load_system_prompt(),
        codegraph_url=os.environ.get("CODEGRAPH_MCP_URL"),
        model=model or os.environ.get("ANTHROPIC_MODEL"),
    )

    qfn = query_fn if query_fn is not None else _default_query_fn()
    async for message in qfn(prompt=prompt, options=options):
        yield message
