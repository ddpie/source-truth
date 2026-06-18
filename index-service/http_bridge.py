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
import json
import logging
import os
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

import path_align
from codegraph_session import CodegraphSession, IndexUnhealthy

# NOTE: the bridge uses the RESIDENT CodegraphSession exclusively. The older
# per-call spawner codegraph_client.py still exists (exercised by its own
# integration tests) but is deliberately NOT imported here — spawning a fresh
# codegraph process per query is the corruption-risk pattern the resident
# session replaced, so it must never re-enter the production path.

logger = logging.getLogger("codegraph-bridge")

# CodeGraph tools exposed over HTTP. Kept small + read-only (MVP evidence set).
EXPOSED_TOOLS = (
    "codegraph_symbol_search",
    "codegraph_get_callers",
    "codegraph_analyze_impact",
)


def _align_one(path: Any, *, index_root: str, mount_root: str) -> Any:
    """Rewrite a single path into mount space, or None if it escapes the repo."""
    if not isinstance(path, str) or not path:
        return path
    try:
        return path_align.to_container_path(path, index_root=index_root, mount_root=mount_root)
    except ValueError:
        # Path escaped repo root — drop it rather than leak an out-of-repo path.
        return None


def _align_paths(raw_json: str, tool_name: str, *, index_root: str, mount_root: str) -> str:
    """Rewrite every file path in a codegraph result into mount space.

    Tool-aware: each of the three exposed tools returns a DIFFERENT envelope
    (verified live against codegraph-server 0.18.5):
      - symbol_search  → {"results": [{"symbol": {"location": {"file": ...}}}]}
      - get_callers    → {"callers": [{"symbol": {"location": {"file": ...}},
                                       "call_site": {"file": ...}}]}
      - analyze_impact → {"impacted": [{"path": ...}], "indirect_impacted": [...]}

    Best-effort: if the payload isn't the expected shape, return it unchanged
    (the bridge must not corrupt results it doesn't understand).
    """
    try:
        data = json.loads(raw_json)
    except (ValueError, TypeError):
        return raw_json
    if not isinstance(data, dict):
        return raw_json

    def fix_location(item: Any) -> None:
        loc = item.get("symbol", {}).get("location") if isinstance(item, dict) else None
        if isinstance(loc, dict) and "file" in loc:
            loc["file"] = _align_one(loc.get("file"), index_root=index_root, mount_root=mount_root)
        # get_callers entries also carry a call_site with its own file path.
        call_site = item.get("call_site") if isinstance(item, dict) else None
        if isinstance(call_site, dict) and "file" in call_site:
            call_site["file"] = _align_one(call_site.get("file"), index_root=index_root, mount_root=mount_root)

    if tool_name == "codegraph_symbol_search":
        for item in data.get("results", []) if isinstance(data.get("results"), list) else []:
            fix_location(item)
    elif tool_name == "codegraph_get_callers":
        for item in data.get("callers", []) if isinstance(data.get("callers"), list) else []:
            fix_location(item)
    elif tool_name == "codegraph_analyze_impact":
        for key in ("impacted", "indirect_impacted", "direct_impacted"):
            seq = data.get(key)
            if isinstance(seq, list):
                for item in seq:
                    if isinstance(item, dict) and "path" in item:
                        item["path"] = _align_one(item.get("path"), index_root=index_root, mount_root=mount_root)
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
    # ONE resident codegraph-server process holds the graph in memory for its
    # whole lifetime. Spawning per-query instead re-scans the repo every call
    # (~20s cold on EFS for ~8.7k files) — unusable on a request path. The
    # worker task serializes calls internally (codegraph isn't concurrent-safe
    # on its graph); warm queries are single-digit ms so serialized is fine.
    # max_files must match the build phase, or the resident session re-scans
    # with a different limit and rebuilds instead of loading the warm graph.
    max_files = int(os.environ.get("CODEGRAPH_MAX_FILES", "10000"))
    session = CodegraphSession(workspace, max_files=max_files)

    app = FastMCP(
        name="codegraph-bridge", host=host, port=port,
        stateless_http=True,
    )

    async def _resolve_uri_line(query: str) -> tuple[str, int]:
        """Resolve a symbol query to an index-space (uri, 0-based line).

        get_callers/analyze_impact need a uri+line, but the agent only ever sees
        /mnt/repo-aligned paths and can't supply an index-space uri. So the bridge
        resolves the query itself via symbol_search (the same resident session,
        index space), taking the top-ranked hit. Raises IndexUnhealthy on an
        unusable index; ValueError if the symbol can't be located.
        """
        raw = await session.call_tool("codegraph_symbol_search", {"query": query})
        data = json.loads(raw)
        results = data.get("results")
        if not isinstance(results, list) or not results:
            raise ValueError(f"no symbol matched query {query!r}")
        loc = results[0].get("symbol", {}).get("location", {})
        index_file = loc.get("file")
        line = loc.get("line")
        if not index_file or not isinstance(line, int):
            raise ValueError(f"symbol match for {query!r} has no usable location")
        # codegraph identifies a symbol by file URI + 0-based line (verified live).
        return f"file://{index_file}", line

    async def _build_args(tool_name: str, query: str) -> dict[str, Any]:
        """Map the uniform `query` UX onto each tool's real argument shape."""
        if tool_name == "codegraph_symbol_search":
            return {"query": query}
        # get_callers / analyze_impact require uri+line — resolve from the query.
        uri, line = await _resolve_uri_line(query)
        return {"uri": uri, "line": line}

    def _make_tool(tool_name: str):
        # Uniform `query` arg → FastMCP generates a clean JSON schema and the
        # agent has one consistent UX. For tools that actually need uri+line
        # (get_callers, analyze_impact) the bridge resolves query→uri+line via
        # symbol_search internally (see _build_args) — the agent can't supply an
        # index-space uri because it only ever sees /mnt/repo-aligned paths.
        async def _tool(query: str) -> str:
            # Wait for warmup (don't refuse mid-startup), then refuse only on a
            # genuinely unhealthy (empty/corrupt) index. Returning an explicit
            # error — not empty results — keeps the agent from answering "not
            # found" off a broken graph (POC rule: code is the only truth).
            try:
                arguments = await _build_args(tool_name, query)
                raw = await session.call_tool(tool_name, arguments)
            except IndexUnhealthy as exc:
                logger.error(json.dumps({"event": "refuse_unhealthy", "tool": tool_name,
                                         "detail": str(exc)}))
                return json.dumps({"error": "index unavailable", "detail": str(exc)})
            except ValueError as exc:
                # Symbol not locatable for a caller/impact query — not an index
                # fault, so report it as a normal "no match" without flipping health.
                logger.info(json.dumps({"event": "tool_no_match", "tool": tool_name, "detail": str(exc)}))
                return json.dumps({"error": f"{tool_name}: symbol not found", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "tool_error", "tool": tool_name, "error": str(exc)}))
                return json.dumps({"error": f"{tool_name} failed", "detail": str(exc)})
            return _align_paths(raw, tool_name, index_root=workspace, mount_root=mount_root)

        _tool.__name__ = tool_name
        return _tool

    for name in EXPOSED_TOOLS:
        app.add_tool(_make_tool(name), name=name, description=f"CodeGraph {name} (read-only).")

    # Plain HTTP /health so deploy orchestration (and load balancers) can poll
    # readiness: 200 only once the graph warmed up non-empty, 503 otherwise.
    # Registered unconditionally — if this fails the bridge is misbuilt and we
    # want it to fail loudly at startup, not silently 404 and cause an opaque
    # 8-minute health-wait timeout in deploy. (starlette ships with uvicorn.)
    from starlette.requests import Request
    from starlette.responses import JSONResponse

    @app.custom_route("/health", methods=["GET"])
    async def _health(_req: Request) -> JSONResponse:  # pragma: no cover - thin
        ok = session.healthy
        return JSONResponse(
            {"healthy": ok, "detail": session.health_detail},
            status_code=200 if ok else 503,
        )

    # Start the resident codegraph worker now, so it's running on EVERY serving
    # path (main() and tests alike) — not only when main() remembers to start it.
    # FastMCP's `lifespan=` is the MCP-session lifespan, NOT the ASGI startup
    # hook, so starting there never fired under the real server. The worker owns
    # its own thread + event loop, so start() is safe to call here (returns
    # immediately, warms the graph in the background) and is idempotent.
    session.start()

    # Expose the session so callers can inspect health / stop it.
    app.codegraph_session = session  # type: ignore[attr-defined]
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
    # build_bridge already started the resident worker (warming in background).
    app = build_bridge(
        workspace=args.workspace, host=args.host, port=args.port, mount_root=args.mount_root
    )
    app.run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    sys.exit(main())
