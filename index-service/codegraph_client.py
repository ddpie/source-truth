"""Thin client that drives codegraph-server's MCP interface over stdio.

This is the stdio half of the index-service bridge: index-service spawns
codegraph-server in ``--mcp`` mode and relays tool calls. The HTTP half (exposing
this to session containers as MCP-over-HTTP) wraps these functions.

Verified live against codegraph-server 0.18.5: list_tools() returns 42 tools,
call_tool("codegraph_symbol_search", ...) returns the real results JSON.

Requires the ``mcp`` package and the ``codegraph-server`` binary on PATH.
"""

from __future__ import annotations

import asyncio
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

DEFAULT_EXCLUDES = ("node_modules", ".venv", ".git")


def _server_params(workspace: str, *, graph_only: bool) -> StdioServerParameters:
    args = ["--mcp", "--workspace", workspace]
    if graph_only:
        args.append("--graph-only")
    for ex in DEFAULT_EXCLUDES:
        args += ["--exclude", ex]
    return StdioServerParameters(command="codegraph-server", args=args)


async def alist_tools(*, workspace: str, graph_only: bool = True) -> list[str]:
    """Async: names of MCP tools codegraph-server exposes for ``workspace``.

    Use this from inside a running event loop (e.g. the HTTP bridge); the sync
    ``list_tools`` wrapper cannot be called there (nested asyncio.run).
    """
    async with stdio_client(_server_params(workspace, graph_only=graph_only)) as (r, w):
        async with ClientSession(r, w) as session:
            await session.initialize()
            resp = await session.list_tools()
            return [t.name for t in resp.tools]


async def acall_tool(
    name: str,
    arguments: dict[str, Any],
    *,
    workspace: str,
    graph_only: bool = True,
) -> str:
    """Async: call one codegraph MCP tool, return its text result (JSON string).

    Event-loop safe — the HTTP bridge awaits this directly.
    """
    async with stdio_client(_server_params(workspace, graph_only=graph_only)) as (r, w):
        async with ClientSession(r, w) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)
            if not result.content:
                return ""
            # codegraph returns a single text content block (JSON string).
            first = result.content[0]
            return getattr(first, "text", str(first))


def list_tools(*, workspace: str, graph_only: bool = True) -> list[str]:
    """Sync wrapper over :func:`alist_tools` (not for use inside an event loop)."""
    return asyncio.run(alist_tools(workspace=workspace, graph_only=graph_only))


def call_tool(
    name: str,
    arguments: dict[str, Any],
    *,
    workspace: str,
    graph_only: bool = True,
) -> str:
    """Sync wrapper over :func:`acall_tool` (not for use inside an event loop)."""
    return asyncio.run(
        acall_tool(name, arguments, workspace=workspace, graph_only=graph_only)
    )
