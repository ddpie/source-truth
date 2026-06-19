"""CodeGraph MCP-over-HTTP bridge (the HTTP half of index-service).

codegraph-server speaks MCP over stdio only and its socket can't cross a
Firecracker microVM. This bridge wraps the stdio client (codegraph_client) in a
FastMCP streamable-HTTP server so session containers can query CodeGraph over
HTTP. It also serves the repo's file content (read_file/glob_files) and text
search (search_files) off the LOCAL repo copy, so the agent microVM needs NO
filesystem mount — all code access is over HTTP. Tool results have their file
paths rewritten into the agent's mount-aligned space (/mnt/repo) via path_align
before returning.

Run as a resident service:
    python -m http_bridge --workspace /data/repo/<subdir> --host 0.0.0.0 --port 8080 \
        --local-workspace /data/repo/<subdir>
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
        # Null-safe chain: `item.get("symbol", {})` only defaults a MISSING key,
        # not a JSON-null value, so a `{"symbol": null}` node (a real partial/
        # unresolved codegraph result) would crash `None.get(...)`. Guard each hop.
        sym = item.get("symbol") if isinstance(item, dict) else None
        loc = sym.get("location") if isinstance(sym, dict) else None
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


def _parse_symbol_location(raw: str, query: str) -> tuple[str, int]:
    """Pure parse of a symbol_search payload → index-space (uri, 0-based line).

    Split out of _resolve_uri_line so the null-safe extraction is unit-testable
    without a live codegraph subprocess. Raises ValueError for any unusable shape
    (no results, null/non-dict symbol, missing location/line) so the caller
    surfaces a clean "symbol not found" rather than a generic "{tool} failed".
    """
    data = json.loads(raw)
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list) or not results:
        raise ValueError(f"no symbol matched query {query!r}")
    # Null-safe chain (mirrors _align_paths.fix_location): a real partial hit can
    # be `{"symbol": null}` or a non-dict; `.get("symbol", {})` only defaults a
    # MISSING key, so a null VALUE would make `None.get("location")` raise
    # AttributeError → mislabelled as an internal "{tool} failed".
    top = results[0]
    sym = top.get("symbol") if isinstance(top, dict) else None
    loc = sym.get("location") if isinstance(sym, dict) else None
    index_file = loc.get("file") if isinstance(loc, dict) else None
    line = loc.get("line") if isinstance(loc, dict) else None
    if not index_file or not isinstance(line, int):
        raise ValueError(f"symbol match for {query!r} has no usable location")
    # codegraph identifies a symbol by file URI + 0-based line (verified live).
    return f"file://{index_file}", line


def build_bridge(
    *,
    workspace: str,
    host: str = "127.0.0.1",
    port: int = 8080,
    mount_root: str = path_align.DEFAULT_MOUNT_ROOT,
    local_workspace: str | None = None,
) -> FastMCP:
    """Build (but don't run) the FastMCP HTTP bridge for a CodeGraph workspace.

    ``workspace`` is the index-service-side repo path codegraph-server indexes
    (a LOCAL-disk copy); its returned paths are rewritten from there onto
    ``mount_root`` (the agent's /mnt/repo-aligned namespace). ``local_workspace``
    is the LOCAL-disk repo copy the file tools (read_file/glob_files/search_files)
    read; post-EFS-removal it's the SAME path as ``workspace``.
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
        # Pure, null-safe parse (unit-tested in test_http_bridge_resolve.py): any
        # unusable shape (null/non-dict symbol, missing location) raises ValueError
        # → clean "symbol not found", never a generic "{tool} failed".
        return _parse_symbol_location(raw, query)

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
                # Path alignment is INSIDE the try so an unexpected envelope shape
                # can't escape this per-query isolation boundary into FastMCP — it
                # falls to the generic handler below and returns an error JSON.
                return _align_paths(raw, tool_name, index_root=workspace, mount_root=mount_root)
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

        _tool.__name__ = tool_name
        return _tool

    for name in EXPOSED_TOOLS:
        app.add_tool(_make_tool(name), name=name, description=f"CodeGraph {name} (read-only).")

    # Fast file-content search over the LOCAL repo copy (replaces the agent's
    # builtin Grep, which hit EFS/NFS at ~20-47s per whole-repo search; local is
    # ~0.2s). Registered only when a local workspace was provided AND exists.
    if local_workspace and os.path.isdir(local_workspace):
        import file_search

        async def codegraph_search_files(pattern: str, glob: str | None = None) -> str:
            """Fast text search across the codebase (paths returned in /mnt/repo
            space). `pattern` is a regex; optional `glob` narrows by filename
            (e.g. "*.cs", "*.json"). Use this instead of shell grep."""
            try:
                return file_search.search_to_json(
                    pattern, local_root=local_workspace, mount_root=mount_root, glob=glob,
                )
            except ValueError as exc:
                return json.dumps({"error": "bad search pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "search_error", "error": str(exc)}))
                return json.dumps({"error": "search failed", "detail": str(exc)})

        app.add_tool(codegraph_search_files, name="codegraph_search_files",
                     description="Fast regex text search over the repo (local-disk; replaces grep).")

        # read_file / glob_files over the SAME local copy — these replace the
        # agent's builtin Read/Glob so the agent microVM needs NO filesystem mount
        # (EFS removal): all code access is over this HTTP bridge. Both confine the
        # agent-supplied path to the local repo via path_align.to_local_path
        # (lexical + realpath symlink-escape guard) before touching disk.
        import file_read

        async def codegraph_read_file(path: str, offset: int = 0, limit: int | None = None) -> str:
            """Read a source/config file's contents by its path (the /mnt/repo-aligned
            path codegraph/search returns). Optional `offset` (0-based line) + `limit`
            page large files. Use this instead of a shell `cat` or builtin Read."""
            try:
                return file_read.read_to_json(
                    path, local_root=local_workspace, mount_root=mount_root, offset=offset, limit=limit,
                )
            except ValueError as exc:
                return json.dumps({"error": "cannot read file", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "read_error", "error": str(exc)}))
                return json.dumps({"error": "read failed", "detail": str(exc)})

        async def codegraph_glob_files(pattern: str) -> str:
            """List files matching a glob `pattern` (e.g. "**/*.cs", "Config/*.json"),
            interpreted relative to the repo root. Returns /mnt/repo-aligned paths.
            Use this instead of a shell `ls`/`find` or builtin Glob."""
            try:
                return file_read.glob_to_json(pattern, local_root=local_workspace, mount_root=mount_root)
            except ValueError as exc:
                return json.dumps({"error": "bad glob pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "glob_error", "error": str(exc)}))
                return json.dumps({"error": "glob failed", "detail": str(exc)})

        app.add_tool(codegraph_read_file, name="codegraph_read_file",
                     description="Read a file's contents by path (local-disk; replaces builtin Read).")
        app.add_tool(codegraph_glob_files, name="codegraph_glob_files",
                     description="List files matching a glob pattern (local-disk; replaces builtin Glob).")
        logger.info(json.dumps({"event": "search_tool_enabled", "local_workspace": local_workspace,
                                "file_tools": ["codegraph_read_file", "codegraph_glob_files"]}))
    else:
        logger.warning(json.dumps({"event": "search_tool_disabled",
                                   "reason": "no local_workspace", "given": local_workspace}))

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
        detail = session.health_detail
        # LOCAL repo read probe — A HEALTH GATE, not just telemetry. The agent reads
        # source over THIS bridge (read_file/glob_files/search_files) off the local
        # repo copy. codegraph answers from its IN-MEMORY graph (session.healthy
        # stays true) even if the on-disk copy becomes unreadable (disk fault, the
        # extract dir got wiped) — but then every agent file read fails and the user
        # gets a broken answer while /health lied 200. So a probe FAILURE flips
        # /health to unhealthy. A consecutive-fail counter avoids flapping on a
        # single transient error. Probes local_workspace if given, else the indexed
        # workspace (same local path post-EFS-removal).
        probe_root = local_workspace or workspace
        disk_ms = -1.0
        probe_ok = True
        try:
            import os
            import time as _t
            t0 = _t.perf_counter()
            entries = os.listdir(probe_root)  # 1 metadata read
            if entries:
                p = os.path.join(probe_root, entries[0])
                os.stat(p)                    # stat read
            disk_ms = round((_t.perf_counter() - t0) * 1000, 1)
            logger.info(json.dumps({"event": "repo_probe", "perf": True,
                                    "latency_ms": disk_ms, "entries": len(entries)}))
        except Exception as exc:  # noqa: BLE001
            probe_ok = False
            logger.warning(json.dumps({"event": "repo_probe_failed", "error": str(exc)}))
        # Track consecutive failures on the app object (survives across requests).
        fails = getattr(app, "_repo_probe_fails", 0)
        fails = 0 if probe_ok else fails + 1
        app._repo_probe_fails = fails  # type: ignore[attr-defined]
        repo_down = fails >= 2  # two strikes → treat repo as unreadable (avoid single-blip flap)
        if repo_down:
            ok = False
            detail = f"repo copy unreadable ({fails} consecutive probe failures): {detail}"
        return JSONResponse(
            {"healthy": ok, "detail": detail, "repo_probe_ms": disk_ms},
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
    p.add_argument("--local-workspace", default=None,
                   help="local-disk copy of the repo for fast file search (grep over EFS is ~225x slower)")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logger.info(json.dumps({"event": "bridge_start", "workspace": args.workspace,
                            "host": args.host, "port": args.port,
                            "local_workspace": args.local_workspace}))
    # build_bridge already started the resident worker (warming in background).
    app = build_bridge(
        workspace=args.workspace, host=args.host, port=args.port, mount_root=args.mount_root,
        local_workspace=args.local_workspace,
    )
    app.run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    sys.exit(main())
