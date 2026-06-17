"""HTTP bridge concurrency + error isolation.

- Several concurrent queries over the same bridge all return real results.
- A query that errors inside the tool returns an error payload (not a crash),
  and the bridge keeps serving subsequent queries.
Skips if codegraph-server / mcp absent.
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


async def _serve(port: int):
    app = http_bridge.build_bridge(workspace=REPO_ROOT, host="127.0.0.1", port=port)
    task = asyncio.create_task(app.run_streamable_http_async())
    await asyncio.sleep(3)
    return task


def test_concurrent_queries_all_return():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async def one(query: str):
        async with streamablehttp_client("http://127.0.0.1:8921/mcp") as (r, w, _):
            async with ClientSession(r, w) as s:
                await s.initialize()
                res = await s.call_tool("codegraph_symbol_search", {"query": query})
                return res.content[0].text if res.content else ""

    async def run():
        task = await _serve(8921)
        try:
            results = await asyncio.gather(
                one("to_container_path"), one("build_options"), one("resolve_match"),
            )
            return results
        finally:
            task.cancel()

    results = asyncio.run(run())
    assert len(results) == 3
    # Each returns valid JSON with a results array (real codegraph response).
    for text in results:
        assert "results" in json.loads(text)


def test_error_isolated_and_server_survives():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async def run():
        task = await _serve(8922)
        try:
            async with streamablehttp_client("http://127.0.0.1:8922/mcp") as (r, w, _):
                async with ClientSession(r, w) as s:
                    await s.initialize()
                    # Empty query may make codegraph error; bridge must not crash.
                    bad = await s.call_tool("codegraph_symbol_search", {"query": ""})
                    bad_text = bad.content[0].text if bad.content else ""
                    # Server still serves a good query afterwards.
                    good = await s.call_tool("codegraph_symbol_search", {"query": "to_container_path"})
                    good_text = good.content[0].text if good.content else ""
                    return bad_text, good_text
        finally:
            task.cancel()

    bad_text, good_text = asyncio.run(run())
    # The bad query returns a response (server didn't crash on it), and the
    # follow-up query still gets a well-formed JSON response → server survived.
    # (We assert survival/validity, not symbol hit: codegraph re-indexes per
    # spawn, so hit timing is a separate concern from error isolation.)
    assert bad_text, "bad query produced no response (server may have crashed)"
    assert "results" in json.loads(good_text), "follow-up query response malformed"
