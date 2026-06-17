"""Async entry points for codegraph_client (needed by the HTTP bridge, which
runs inside an event loop and cannot use the sync asyncio.run wrappers).

Real integration test: skips if codegraph-server / mcp absent.
"""

from __future__ import annotations

import asyncio
import shutil
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")
if shutil.which("codegraph-server") is None:
    pytest.skip("codegraph-server not on PATH", allow_module_level=True)

import codegraph_client  # noqa: E402

REPO_ROOT = SVC_DIR.parent


def test_async_call_tool_works_inside_event_loop():
    # The whole point: callable from within a running loop (no asyncio.run).
    async def run():
        return await codegraph_client.acall_tool(
            "codegraph_symbol_search",
            {"query": "to_container_path"},
            workspace=str(REPO_ROOT),
        )

    result = asyncio.run(run())
    assert "to_container_path" in result
    assert "path_align" in result


def test_async_list_tools():
    async def run():
        return await codegraph_client.alist_tools(workspace=str(REPO_ROOT))

    tools = asyncio.run(run())
    assert "codegraph_symbol_search" in tools
