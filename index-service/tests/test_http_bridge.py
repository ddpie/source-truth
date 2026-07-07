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


async def _list_full_tools(port: int):
    """Start the bridge and return the FULL tool objects (name+description+annotations)
    over a real MCP client, so we can assert the best-practice metadata the model sees."""
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=port,
                                   local_workspace=REPO_ROOT)
    server = asyncio.create_task(app.run_streamable_http_async())
    try:
        await asyncio.sleep(3)
        async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                return (await session.list_tools()).tools
    finally:
        server.cancel()
        await app.codegraph_session.stop()  # type: ignore[attr-defined]


async def _list_tools_with_project(port: int, project: str, glossary_root: str):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    # Point glossary_read at the temp root for this in-process build.
    import glossary_read
    orig = glossary_read.DEFAULT_GLOSSARY_ROOT
    glossary_read.DEFAULT_GLOSSARY_ROOT = glossary_root
    app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=port,
                                   local_workspace=REPO_ROOT, project=project)
    server = asyncio.create_task(app.run_streamable_http_async())
    try:
        await asyncio.sleep(3)
        async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                idx = await session.call_tool("codegraph_glossary_index", {})
                idx_text = idx.content[0].text if idx.content else ""
                return tools, idx_text
    finally:
        server.cancel()
        await app.codegraph_session.stop()  # type: ignore[attr-defined]
        glossary_read.DEFAULT_GLOSSARY_ROOT = orig


def test_glossary_tools_register_and_serve_when_project_set(tmp_path):
    # The two glossary tools must appear in the closed read-only allowlist when a project
    # id is set, be read-only-annotated, and serve the project's term index over HTTP.
    import glossary
    proj_dir = tmp_path / "gloss" / "mangos"
    proj_dir.mkdir(parents=True)
    glossary.write_entries(str(proj_dir / "entries.jsonl"), [
        glossary.Entry("combat_power", "symbol", "combatPower", "src/Player.cpp", 42, "high"),
        glossary.Entry("combat_power", "alias", "战力", "src/Player.cpp", 40, "high"),
    ])
    tools, idx_text = asyncio.run(
        _list_tools_with_project(8917, "mangos", str(tmp_path / "gloss")))
    by_name = {t.name: t for t in tools}
    for name in ("codegraph_glossary_index", "codegraph_glossary_lookup"):
        assert name in by_name, f"missing {name}"
        ann = by_name[name].annotations
        assert ann is not None and ann.readOnlyHint is True, f"{name}: not read-only"
    assert "combat_power" in idx_text and "战力" in idx_text


def test_glossary_tools_absent_when_no_project():
    # Without a project id the glossary tools must NOT be registered (no per-project data).
    tools = asyncio.run(_list_full_tools(8918))
    names = {t.name for t in tools}
    assert "codegraph_glossary_index" not in names
    assert "codegraph_glossary_lookup" not in names


def test_tools_carry_readonly_annotations_and_rich_descriptions():
    # MCP best practice (spec tool annotations + Anthropic "writing tools for agents"):
    # read-only tools should declare readOnlyHint/idempotentHint/openWorldHint (else
    # clients default to destructive/non-idempotent/open-world), and the description —
    # the model's primary tool-selection signal — must be substantive, not a bare name.
    tools = asyncio.run(_list_full_tools(8916))
    by_name = {t.name: t for t in tools}
    # All six evidence tools must be present and read-only-annotated.
    expected = {"codegraph_symbol_search", "codegraph_get_callers", "codegraph_analyze_impact",
                "codegraph_search_files", "codegraph_read_file", "codegraph_glob_files"}
    assert expected <= set(by_name), f"missing tools: {expected - set(by_name)}"
    for name in expected:
        t = by_name[name]
        ann = t.annotations
        assert ann is not None, f"{name}: no annotations (defaults to destructive/open-world)"
        assert ann.readOnlyHint is True, f"{name}: not marked readOnlyHint"
        assert ann.idempotentHint is True, f"{name}: not marked idempotentHint"
        assert ann.openWorldHint is False, f"{name}: should be closed-domain"
        # Description must be substantive (not the old bare "CodeGraph <name> (read-only).").
        desc = t.description or ""
        assert len(desc) >= 40, f"{name}: thin description ({len(desc)} chars): {desc!r}"
        assert name not in desc or len(desc) >= 60, f"{name}: description looks like the bare-name stub"


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


def test_bridge_result_paths_are_repo_relative():
    # Tool result paths must be REPO-RELATIVE (path_align chained in).
    # The agent has no filesystem mount, so paths are plain relative, never the raw
    # codegraph ./-prefixed form and never an absolute host/index path.
    _, text = asyncio.run(_run_bridge_and_query("to_container_path", 8912))
    data = json.loads(text)
    files = [r["symbol"]["location"]["file"] for r in data["results"]]
    assert files, "no result files"
    assert not any(f.startswith("/") for f in files), f"absolute path leaked: {files}"
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
    # Any returned caller path must be repo-relative, never a raw/absolute index path.
    for c in data["callers"]:
        loc = c.get("symbol", {}).get("location", {})
        if loc.get("file"):
            assert not loc["file"].startswith(("/", "./")), loc["file"]


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
            assert not item["path"].startswith(("/", "./")), item["path"]


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
