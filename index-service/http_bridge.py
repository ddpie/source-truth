"""CodeGraph MCP-over-HTTP bridge (the HTTP half of index-service).

codegraph-server speaks MCP over stdio only and its socket can't cross a
Firecracker microVM. This bridge wraps the stdio client (codegraph_client) in a
FastMCP streamable-HTTP server so session containers can query CodeGraph over
HTTP. Tool results have their file paths rewritten into the container mount
space (/mnt/repo) via path_align before returning.

Run as a resident service:
    python -m http_bridge --workspace /mnt/efs/repo --host 0.0.0.0 --port 8080
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys

from mcp.server.fastmcp import FastMCP

import codegraph_client
import path_align

logger = logging.getLogger("codegraph-bridge")

# CodeGraph tools exposed over HTTP. Kept small + read-only (MVP evidence set).
EXPOSED_TOOLS = (
    "codegraph_symbol_search",
    "codegraph_get_callers",
    "codegraph_analyze_impact",
)


def _align_paths(raw_json: str, *, index_root: str, mount_root: str) -> str:
    """Rewrite symbol.location.file in a codegraph result into mount space.

    Best-effort: if the payload isn't the expected shape, return it unchanged
    (the bridge must not corrupt results it doesn't understand).
    """
    try:
        data = json.loads(raw_json)
    except (ValueError, TypeError):
        return raw_json
    results = data.get("results")
    if not isinstance(results, list):
        return raw_json
    for item in results:
        loc = item.get("symbol", {}).get("location") if isinstance(item, dict) else None
        if isinstance(loc, dict) and loc.get("file"):
            try:
                loc["file"] = path_align.to_container_path(
                    loc["file"], index_root=index_root, mount_root=mount_root
                )
            except ValueError:
                # Path escaped repo root — drop the location rather than leak it.
                loc["file"] = None
    return json.dumps(data, ensure_ascii=False)


def build_bridge(
    *,
    workspace: str,
    host: str = "127.0.0.1",
    port: int = 8080,
    mount_root: str = path_align.DEFAULT_MOUNT_ROOT,
) -> FastMCP:
    """Build (but don't run) the FastMCP HTTP bridge for a CodeGraph workspace.

    ``workspace`` is the index-service-side repo path codegraph-server indexes;
    its returned paths are rewritten from there onto ``mount_root``.
    """
    app = FastMCP(name="codegraph-bridge", host=host, port=port, stateless_http=True)

    # Serialize access to codegraph-server: each acall_tool spawns a fresh
    # codegraph-server process against the same graph.db, and concurrent
    # processes contend on the RocksDB lock (one loses → empty index). Until
    # this is replaced by a resident --serve engine + thin --connect clients,
    # a lock keeps concurrent HTTP queries correct (serialized, not parallel).
    cg_lock = asyncio.Lock()

    def _make_tool(tool_name: str):
        # Single explicit `query` arg → FastMCP generates a clean JSON schema.
        # (MVP evidence tools all take a query; richer args added per-tool later.)
        async def _tool(query: str) -> str:
            try:
                async with cg_lock:
                    raw = await codegraph_client.acall_tool(
                        tool_name, {"query": query}, workspace=workspace
                    )
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "tool_error", "tool": tool_name, "error": str(exc)}))
                return json.dumps({"error": f"{tool_name} failed", "detail": str(exc)})
            return _align_paths(raw, index_root=workspace, mount_root=mount_root)

        _tool.__name__ = tool_name
        return _tool

    for name in EXPOSED_TOOLS:
        app.add_tool(_make_tool(name), name=name, description=f"CodeGraph {name} (read-only).")

    return app


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--workspace", required=True, help="repo path codegraph-server indexes")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--mount-root", default=path_align.DEFAULT_MOUNT_ROOT)
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logger.info(json.dumps({"event": "bridge_start", "workspace": args.workspace,
                            "host": args.host, "port": args.port}))
    app = build_bridge(
        workspace=args.workspace, host=args.host, port=args.port, mount_root=args.mount_root
    )
    app.run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    sys.exit(main())
