"""Integration test for the CodeGraph MCP-over-HTTP bridge.

Starts the real FastMCP streamable-HTTP server (http_bridge) in-process, then
queries it over a real HTTP MCP client. Skips if codegraph-server / mcp absent.
"""

from __future__ import annotations

import asyncio
import json
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

import http_bridge  # noqa: E402

REPO_ROOT = str(SVC_DIR.parent)


async def _run_bridge_and_query(query: str, port: int):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=port)
    server = asyncio.create_task(app.run_streamable_http_async())
    try:
        await asyncio.sleep(3)  # let uvicorn bind
        async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                tools = [t.name for t in (await session.list_tools()).tools]
                res = await session.call_tool("codegraph_symbol_search", {"query": query})
                text = res.content[0].text if res.content else ""
                return tools, text
    finally:
        server.cancel()


def test_bridge_exposes_codegraph_tools_over_http():
    tools, text = asyncio.run(_run_bridge_and_query("to_container_path", 8911))
    assert "codegraph_symbol_search" in tools
    assert "to_container_path" in text  # real result from codegraph over HTTP


def test_bridge_result_paths_are_container_aligned():
    # Tool result must already be /mnt/repo-aligned (path_align chained in).
    _, text = asyncio.run(_run_bridge_and_query("to_container_path", 8912))
    data = json.loads(text)
    files = [r["symbol"]["location"]["file"] for r in data["results"]]
    assert any(f.startswith("/mnt/repo/") for f in files), files
    assert not any(f.startswith("./") for f in files), "raw ./-paths leaked, not aligned"
