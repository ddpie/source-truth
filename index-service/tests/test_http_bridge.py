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


async def _run_bridge_and_call(tool: str, query: str, port: int):
    """Start the bridge, warm up, and call one tool with a uniform {query} arg.

    All three exposed tools accept `query` over HTTP; the bridge maps it onto
    each tool's real argument shape (symbol_search uses it directly; get_callers
    / analyze_impact resolve query→uri+line internally). Returns (tools, text).
    """
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=port)
    server = asyncio.create_task(app.run_streamable_http_async())
    try:
        await asyncio.sleep(3)  # let uvicorn bind
        # build_bridge starts the resident worker; wait for warmup to finish
        # before querying, or the health gate (correctly) refuses with
        # "index unavailable" while the graph is still indexing. Assert the
        # precondition so a warmup timeout / unhealthy graph fails HERE with a
        # clear message, not indirectly via a malformed query response later.
        ready = await app.codegraph_session.wait_ready(timeout=90)  # type: ignore[attr-defined]
        assert ready, f"index-service did not warm up healthy: {app.codegraph_session.health_detail}"  # type: ignore[attr-defined]
        async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                tools = [t.name for t in (await session.list_tools()).tools]
                res = await session.call_tool(tool, {"query": query})
                text = res.content[0].text if res.content else ""
                return tools, text
    finally:
        server.cancel()
        await app.codegraph_session.stop()  # type: ignore[attr-defined]


async def _run_bridge_and_query(query: str, port: int):
    return await _run_bridge_and_call("codegraph_symbol_search", query, port)


def test_bridge_exposes_codegraph_tools_over_http():
    tools, text = asyncio.run(_run_bridge_and_query("to_container_path", 8911))
    assert "codegraph_symbol_search" in tools
    # Real result from codegraph over HTTP. Assert on structure, not a specific
    # symbol name: codegraph's search is fuzzy/ranked, so a query doesn't
    # guarantee an exact-name hit as the codebase grows. A healthy graph returns
    # a results array with real symbol locations (the bridge would instead return
    # {"error": "index unavailable"} on an empty/corrupt graph).
    data = json.loads(text)
    assert isinstance(data.get("results"), list) and data["results"], f"no results: {text[:200]}"
    assert all("symbol" in r and "location" in r["symbol"] for r in data["results"])


def test_bridge_result_paths_are_container_aligned():
    # Tool result must already be /mnt/repo-aligned (path_align chained in).
    _, text = asyncio.run(_run_bridge_and_query("to_container_path", 8912))
    data = json.loads(text)
    files = [r["symbol"]["location"]["file"] for r in data["results"]]
    assert any(f.startswith("/mnt/repo/") for f in files), files
    assert not any(f.startswith("./") for f in files), "raw ./-paths leaked, not aligned"


def test_bridge_get_callers_resolves_query_and_stays_healthy():
    # get_callers needs uri+line; the bridge must resolve query→uri+line via
    # symbol_search internally. Before the fix this returned "no starting node"
    # AND flipped the resident session unhealthy (its envelope has no `results`
    # list). Now it must return a real callers envelope and the index stays
    # healthy (a successful evidence call must never wedge the session).
    tools, text = asyncio.run(
        _run_bridge_and_call("codegraph_get_callers", "build_options_dict", 8913)
    )
    assert "codegraph_get_callers" in tools
    data = json.loads(text)
    assert "error" not in data, f"get_callers errored: {text[:300]}"
    # Healthy envelope: a callers list (may be empty for a leaf, but build_options
    # is called by build_options_dict's wrapper, so we expect ≥0 and no error).
    assert isinstance(data.get("callers"), list), f"no callers list: {text[:300]}"
    # Any returned caller path must be container-aligned, never a raw index path.
    for c in data["callers"]:
        loc = c.get("symbol", {}).get("location", {})
        if loc.get("file"):
            assert loc["file"].startswith("/mnt/repo/"), loc["file"]


def test_bridge_analyze_impact_resolves_query_and_aligns_paths():
    # analyze_impact requires uri+line and returns an `impacted` envelope (no
    # `results` key) — must resolve from query, return real impact, stay healthy.
    tools, text = asyncio.run(
        _run_bridge_and_call("codegraph_analyze_impact", "build_options_dict", 8914)
    )
    assert "codegraph_analyze_impact" in tools
    data = json.loads(text)
    assert "error" not in data, f"analyze_impact errored: {text[:300]}"
    assert isinstance(data.get("impacted"), list), f"no impacted list: {text[:300]}"
    for item in data["impacted"]:
        if isinstance(item, dict) and item.get("path"):
            assert item["path"].startswith("/mnt/repo/"), item["path"]


def test_bridge_caller_query_does_not_wedge_symbol_search():
    # Regression for the health-wedge bug: a get_callers call must not flip the
    # shared session unhealthy. After one, symbol_search must still work on the
    # SAME resident session.
    async def run():
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client

        app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=8915)
        server = asyncio.create_task(app.run_streamable_http_async())
        try:
            await asyncio.sleep(3)
            ready = await app.codegraph_session.wait_ready(timeout=90)  # type: ignore[attr-defined]
            assert ready, app.codegraph_session.health_detail  # type: ignore[attr-defined]
            async with streamablehttp_client("http://127.0.0.1:8915/mcp") as (r, w, _):
                async with ClientSession(r, w) as s:
                    await s.initialize()
                    await s.call_tool("codegraph_get_callers", {"query": "build_options_dict"})
                    # The resident session must still be healthy afterwards.
                    assert app.codegraph_session.healthy, (  # type: ignore[attr-defined]
                        f"get_callers wedged the session: {app.codegraph_session.health_detail}"  # type: ignore[attr-defined]
                    )
                    res = await s.call_tool("codegraph_symbol_search", {"query": "to_container_path"})
                    return res.content[0].text if res.content else ""
        finally:
            server.cancel()
            await app.codegraph_session.stop()  # type: ignore[attr-defined]

    text = asyncio.run(run())
    assert "results" in json.loads(text), f"symbol_search broke after get_callers: {text[:200]}"
