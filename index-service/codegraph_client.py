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
import os
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

DEFAULT_EXCLUDES = ("node_modules", ".venv", ".git")

# SINGLE-WRITER TRIPWIRE (machine-enforced, not just a comment). This module spawns a
# FRESH codegraph-server per call — and `--graph-only` is a SCOPE flag, not read-only,
# so every spawn WRITES graph.db. The live serving path uses the resident
# CodegraphSession exclusively and must NEVER reach here: a spawn from inside the
# running bridge would be a SECOND concurrent writer on the same graph.db → silent
# 0-node corruption (the project's #1 invariant). The bridge's flock lives in
# http_bridge.main(), which does NOT catch an in-process second spawn — so guard the
# spawn primitive itself. Allowed only when explicitly opted in (tests set this); the
# bridge never does. Fail LOUD rather than risk corruption.
def _assert_spawn_allowed() -> None:
    if os.environ.get("CODEGRAPH_ALLOW_PERCALL_SPAWN") != "1":
        raise RuntimeError(
            "codegraph_client spawns a per-call codegraph-server (a graph.db WRITER); "
            "it must not run on the resident serving path (would be a 2nd writer → "
            "graph.db corruption). Set CODEGRAPH_ALLOW_PERCALL_SPAWN=1 only in tests."
        )


def _server_params(workspace: str, *, graph_only: bool) -> StdioServerParameters:
    _assert_spawn_allowed()
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
