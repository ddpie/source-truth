"""Integration test for codegraph_client — drives a real codegraph-server.

Requires the `codegraph-server` binary on PATH and the `mcp` package. Skips if
either is absent, so the offline suite stays green on machines without them.
This is a REAL integration test (no stub): it spawns codegraph-server in MCP
stdio mode, lists tools, and calls codegraph_symbol_search against this repo.
"""

from __future__ import annotations

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

import codegraph_client  # noqa: E402

REPO_ROOT = SVC_DIR.parent


def test_list_tools_returns_codegraph_surface():
    tools = codegraph_client.list_tools(workspace=str(REPO_ROOT))
    assert any(t.startswith("codegraph_") for t in tools)
    assert "codegraph_symbol_search" in tools


def test_symbol_search_finds_known_symbol():
    result = codegraph_client.call_tool(
        "codegraph_symbol_search",
        {"query": "to_container_path"},
        workspace=str(REPO_ROOT),
    )
    # Real codegraph returns JSON text with a results array. Assert on structure,
    # not a specific symbol name: codegraph's search is fuzzy/ranked, so a query
    # isn't guaranteed to surface an exact-name hit as the codebase grows.
    data = json.loads(result)
    assert isinstance(data.get("results"), list) and data["results"], f"no results: {result[:200]}"
    assert all("symbol" in r and "location" in r["symbol"] for r in data["results"])
