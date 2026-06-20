"""CodeGraph MCP-over-HTTP bridge (the HTTP half of index-service).

codegraph-server speaks MCP over stdio only and its socket can't cross a
Firecracker microVM. This bridge wraps the stdio client (codegraph_client) in a
FastMCP streamable-HTTP server so session containers can query CodeGraph over
HTTP. It also serves the repo's file content (read_file/glob_files) and text
search (search_files) off the LOCAL repo copy, so the agent microVM needs NO
filesystem mount — all code access is over HTTP. Tool results have their file
paths rewritten via path_align into REPO-RELATIVE form (mount_root defaults to
""; a legacy /mnt/repo mount_root is still accepted for back-compat) before
returning.

Run as a resident service:
    python -m http_bridge --workspace /data/repo/<subdir> --host 0.0.0.0 --port 8080 \
        --mount-root "" --local-workspace /data/repo/<subdir>
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import posixpath
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

import path_align
from codegraph_session import CodegraphSession, IndexUnhealthy
from repo_router import RepoRouter, RepoOutOfScope

# NOTE: the bridge uses the RESIDENT CodegraphSession exclusively. The older
# per-call spawner codegraph_client.py still exists (exercised by its own
# integration tests) but is deliberately NOT imported here — spawning a fresh
# codegraph process per query is the corruption-risk pattern the resident
# session replaced, so it must never re-enter the production path.

# Per-WORKSPACE writer-lock fds, module-global so the GC can't collect them and
# release the flocks mid-run. Keyed by the normalized workspace path → held fd, so a
# multi-repo bridge that serves N workspaces in one process takes N DISTINCT flocks
# (one per graph.db), NOT one process-wide lock. See acquire_singleton_writer_lock().
_WRITER_LOCK_FDS: dict[str, Any] = {}

# Back-compat shim for older tests/inspection that referenced a single fd. It mirrors
# the MOST-RECENTLY acquired lock fd (None when none held). The authoritative state is
# _WRITER_LOCK_FDS; this is only a convenience view. (Setting it to None and calling
# acquire still works — the per-workspace dict is what gates idempotency.)
_SINGLETON_FD: Any = None


class SingleWriterConflict(RuntimeError):
    """Raised when another process already holds this workspace's writer flock."""


def _lock_key(workspace: str) -> str:
    """Normalize a workspace path to a stable lock-registry key (so '/d/r' and '/d/r/'
    are the same lock). Mirrors the lock_path derivation."""
    return workspace.rstrip("/")


def acquire_singleton_writer_lock(workspace: str) -> None:
    """SINGLE-WRITER HARD GUARD (do NOT rely on a comment). The whole no-corruption
    invariant rests on exactly ONE process owning the codegraph-server that writes a
    given graph.db. Take a process-lifetime exclusive flock keyed PER WORKSPACE BEFORE
    that workspace's worker starts; if another process already holds it, raise instead
    of becoming a second writer.

    PER-WORKSPACE (multi-repo): a bridge process that serves N workspaces calls this
    once per workspace and holds N independent flocks — locking workspace A must NOT
    suppress locking workspace B (the bug a single process-wide fd would cause: repos
    2..N silently unguarded → concurrent writers on their graph.db → 0-node corruption).

    Called from build_bridge() (NOT just main()) so it also guards an app-factory launch
    — `gunicorn http_bridge:app --workers N` imports `app` and bypasses main(), so a flock
    only in main() would let N forked workers each spawn a writer (cross-review H1).
    Idempotent PER WORKSPACE: if THIS process already holds this workspace's lock, it's a
    no-op (same fd kept). A DIFFERENT process gets BlockingIOError on the non-blocking
    acquire → SingleWriterConflict.
    """
    global _SINGLETON_FD
    key = _lock_key(workspace)
    if key in _WRITER_LOCK_FDS:
        return  # this process already owns THIS workspace's lock
    import fcntl
    # Workspace-keyed lock file (stable across restarts; one per indexed repo). Lives
    # next to the repo copy so it shares the graph.db's local disk (a real fs, not a
    # tmpfs a container restart wipes). The held fd is kept in the module-global dict so
    # it is not GC'd (which would release the lock) for the process lifetime.
    lock_path = key + ".bridge.lock"
    fd = open(lock_path, "w")  # noqa: SIM115 - held for process life
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError) as exc:
        fd.close()
        logger.error(json.dumps({"event": "bridge_singleton_conflict", "lock": lock_path,
                                 "detail": "another bridge already owns this workspace; refusing to start a second graph.db writer",
                                 "error": str(exc)}))
        raise SingleWriterConflict(lock_path) from exc
    fd.write(str(os.getpid()))
    fd.flush()
    _WRITER_LOCK_FDS[key] = fd
    _SINGLETON_FD = fd  # back-compat view: most-recent lock

logger = logging.getLogger("codegraph-bridge")

# CodeGraph tools exposed over HTTP. Kept small + read-only (MVP evidence set).
EXPOSED_TOOLS = (
    "codegraph_symbol_search",
    "codegraph_get_callers",
    "codegraph_analyze_impact",
)


def _align_one(path: Any, *, index_root: str, mount_root: str, repo: str = "") -> Any:
    """Rewrite a single path into mount space, or None if it escapes the repo."""
    if not isinstance(path, str) or not path:
        return path
    try:
        return path_align.to_container_path(path, index_root=index_root, mount_root=mount_root, repo=repo)
    except ValueError:
        # Path escaped repo root — drop it rather than leak an out-of-repo path.
        return None


def _align_paths(raw_json: str, tool_name: str, *, index_root: str, mount_root: str, repo: str = "") -> str:
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
            loc["file"] = _align_one(loc.get("file"), index_root=index_root, mount_root=mount_root, repo=repo)
        # get_callers entries also carry a call_site with its own file path.
        call_site = item.get("call_site") if isinstance(item, dict) else None
        if isinstance(call_site, dict) and "file" in call_site:
            call_site["file"] = _align_one(call_site.get("file"), index_root=index_root, mount_root=mount_root, repo=repo)

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
                        item["path"] = _align_one(item.get("path"), index_root=index_root, mount_root=mount_root, repo=repo)
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
    (a LOCAL-disk copy); its returned paths are rewritten from there into the
    agent's namespace — REPO-RELATIVE by default (``mount_root=""``), or under a
    legacy ``/mnt/repo`` if a non-empty ``mount_root`` is given. ``local_workspace``
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
    # SINGLE-WRITER GUARD — acquired HERE (before the worker spawns codegraph-server),
    # not just in main(), so an app-factory launch (gunicorn http_bridge:app --workers N)
    # can't bypass it and spawn N writers. Idempotent if main() already took it.
    acquire_singleton_writer_lock(workspace)
    session = CodegraphSession(workspace, max_files=max_files)

    # SERVER-SIDE SCOPE ENFORCEMENT (multi-repo 不变量1 / 阶段3 gate): the repo NAME this
    # bridge serves is the workspace basename (e.g. /data/repo/code-5x → "code-5x"). Every
    # tool takes an optional `repo` arg routed through this router BEFORE touching the
    # session: an out-of-scope repo is rejected here, never routed (the cross-project leak
    # this stops). Today N=1 (one workspace) so it resolves to the sole repo or rejects a
    # wrong name; it generalizes unchanged to N workspaces once bootstrap builds them.
    repo_name = posixpath.basename(workspace.rstrip("/"))
    router = RepoRouter([repo_name])

    def _route(repo: str | None) -> str:
        """Resolve the agent's `repo` arg to an in-scope repo (or raise RepoOutOfScope,
        a ValueError the per-query handler turns into a clean 'no such repo')."""
        resolved = router.resolve(repo)
        # N=1: resolve() returns the sole repo for None; for N>1 a None means fan-out, not
        # yet wired (single workspace today), so treat None as the sole/first repo.
        return resolved if resolved is not None else router.repos[0]

    app = FastMCP(
        name="codegraph-bridge", host=host, port=port,
        stateless_http=True,
    )

    async def _resolve_uri_line(query: str) -> tuple[str, int]:
        """Resolve a symbol query to an index-space (uri, 0-based line).

        get_callers/analyze_impact need a uri+line, but the agent only ever sees
        repo-relative paths and can't supply an index-space uri. So the bridge
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
        # index-space uri because it only ever sees repo-relative paths.
        async def _tool(query: str, repo: str | None = None) -> str:
            # Wait for warmup (don't refuse mid-startup), then refuse only on a
            # genuinely unhealthy (empty/corrupt) index. Returning an explicit
            # error — not empty results — keeps the agent from answering "not
            # found" off a broken graph (POC rule: code is the only truth).
            try:
                # SERVER-SIDE SCOPE GATE FIRST: reject an out-of-scope `repo` before any
                # session work (不变量1). Raises RepoOutOfScope (a ValueError) → the handler
                # below turns it into a clean "no such repo" result, never a fallback.
                resolved_repo = _route(repo)
                arguments = await _build_args(tool_name, query)
                raw = await session.call_tool(tool_name, arguments)
                # Path alignment is INSIDE the try so an unexpected envelope shape
                # can't escape this per-query isolation boundary into FastMCP — it
                # falls to the generic handler below and returns an error JSON. The
                # resolved repo prefixes returned paths as <repo>/… (path honesty §4.4).
                return _align_paths(raw, tool_name, index_root=workspace, mount_root=mount_root, repo=resolved_repo)
            except RepoOutOfScope as exc:
                logger.warning(json.dumps({"event": "repo_out_of_scope", "tool": tool_name, "detail": str(exc)}))
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})
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
                # Generic detail only — str(exc) on an internal/transport error can
                # carry host paths/frames that must not reach the group-visible card.
                logger.error(json.dumps({"event": "tool_error", "tool": tool_name, "error": str(exc)}))
                return json.dumps({"error": f"{tool_name} failed", "detail": "internal error (see service logs)"})

        _tool.__name__ = tool_name
        return _tool

    # All six tools are READ-ONLY, IDEMPOTENT, and CLOSED-DOMAIN (they only query the
    # local repo copy / in-memory graph — no writes, no external/open-world calls). The
    # MCP spec's tool annotations default to the pessimistic (destructive, non-idempotent,
    # open-world) when unset, so we set them explicitly: this is both honest metadata and
    # lets a client safely auto-approve these evidence calls. (Annotations are advisory —
    # the actual read-only guarantee is enforced by the closed allowlist + agent-side
    # disallowed_tools, not by these hints.)
    from mcp.types import ToolAnnotations
    READONLY_ANNOT = ToolAnnotations(readOnlyHint=True, destructiveHint=False,
                                     idempotentHint=True, openWorldHint=False)

    # Action-oriented descriptions so the model picks the right graph tool (the bare
    # f"CodeGraph {name}" gave it nothing to disambiguate on). Per Anthropic "writing
    # tools for agents": the description is the primary tool-selection signal.
    GRAPH_TOOL_DESC = {
        "codegraph_symbol_search": "Find a class/function/method by name or concept. "
            "YOUR STARTING POINT when you don't yet know where code lives. `query` is a "
            "symbol name or natural-language description; returns ranked matches with "
            "repo-relative file:line locations.",
        "codegraph_get_callers": "Find everything that calls a given symbol (reverse call "
            "graph) — use for 'who uses X' / usage + impact. `query` is the symbol name "
            "(resolved to the top match); returns the callers with repo-relative locations.",
        "codegraph_analyze_impact": "Predict the blast radius of changing a symbol — what "
            "depends on it. `query` is the symbol name (resolved to the top match). NOTE: "
            "static call graph only; cross-check dynamic/reflection/config-driven uses with "
            "codegraph_search_files.",
    }
    for name in EXPOSED_TOOLS:
        app.add_tool(_make_tool(name), name=name,
                     description=GRAPH_TOOL_DESC.get(name, f"CodeGraph {name} (read-only)."),
                     annotations=READONLY_ANNOT)

    # Fast file-content search over the LOCAL repo copy (replaces the agent's
    # builtin Grep, which hit EFS/NFS at ~20-47s per whole-repo search; local is
    # ~0.2s). Registered only when a local workspace was provided AND exists.
    if local_workspace and os.path.isdir(local_workspace):
        import file_search

        async def codegraph_search_files(pattern: str, glob: str | None = None) -> str:
            """Fast text search across the codebase (paths returned repo-relative,
            e.g. `Assets/Scripts/Foo.cs`). `pattern` is a regex; optional `glob`
            narrows by filename (e.g. "*.cs", "*.json"). Use this instead of shell grep."""
            try:
                return file_search.search_to_json(
                    pattern, local_root=local_workspace, mount_root=mount_root, glob=glob, repo=repo_name,
                )
            except ValueError as exc:
                # ValueError only echoes the agent-supplied pattern (no host path) → safe to return.
                return json.dumps({"error": "bad search pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                # str(exc) on an OSError/RuntimeError can embed an absolute HOST path
                # (/data/repo/...) — log it for the operator, but NEVER return it to the
                # model (it reaches the group-visible card). Generic detail only.
                logger.error(json.dumps({"event": "search_error", "error": str(exc)}))
                return json.dumps({"error": "search failed", "detail": "internal error (see service logs)"})

        app.add_tool(codegraph_search_files, name="codegraph_search_files",
                     description=(codegraph_search_files.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)

        # read_file / glob_files over the SAME local copy — these replace the
        # agent's builtin Read/Glob so the agent microVM needs NO filesystem mount
        # (EFS removal): all code access is over this HTTP bridge. Both confine the
        # agent-supplied path to the local repo via path_align.to_local_path
        # (lexical + realpath symlink-escape guard) before touching disk.
        import file_read

        async def codegraph_read_file(path: str, offset: int = 0, limit: int | None = None) -> str:
            """Read a source/config file's contents by its path (the repo-relative
            path codegraph/search returns, e.g. `Assets/Scripts/Foo.cs` — pass it
            back verbatim, don't add any prefix). Optional `offset` (0-based line) +
            `limit` page large files. Use this instead of a shell `cat` or builtin Read."""
            try:
                return file_read.read_to_json(
                    path, local_root=local_workspace, mount_root=mount_root, offset=offset, limit=limit, repo=repo_name,
                )
            except ValueError as exc:
                # ValueError echoes only the agent-supplied path (no host path) → safe.
                return json.dumps({"error": "cannot read file", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                # An OSError from open() serializes the absolute HOST path (/data/repo/...);
                # log it but return a generic detail so it can't leak into the group card.
                logger.error(json.dumps({"event": "read_error", "error": str(exc)}))
                return json.dumps({"error": "read failed", "detail": "internal error (see service logs)"})

        async def codegraph_glob_files(pattern: str) -> str:
            """List files matching a glob `pattern` (e.g. "**/*.cs", "Config/*.json"),
            interpreted relative to the repo root. Returns repo-relative paths
            (e.g. `Assets/Scripts/Foo.cs`). Use this instead of a shell `ls`/`find`
            or builtin Glob."""
            try:
                return file_read.glob_to_json(pattern, local_root=local_workspace, mount_root=mount_root, repo=repo_name)
            except ValueError as exc:
                return json.dumps({"error": "bad glob pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "glob_error", "error": str(exc)}))
                return json.dumps({"error": "glob failed", "detail": "internal error (see service logs)"})

        # read_table: parse STRUCTURED/binary config files (Excel/CSV/TSV/SQLite) to
        # text. read_file decodes as UTF-8, so an Excel/SQLite config table comes back
        # as garbage and the agent can't use it — yet that's where game-dev numbers
        # often live. read_table parses them server-side (read-only) into compact text.
        import file_table

        async def codegraph_read_table(path: str) -> str:
            """Read a STRUCTURED config table that read_file can't (Excel .xlsx/.xls,
            .csv, .tsv, or a SQLite .db) — parsed server-side into plain text rows.
            Use this when the data lives in a spreadsheet/database config file (common
            for game numeric tables); for plain-text source/config use read_file."""
            try:
                return file_table.read_table_to_json(path, local_root=local_workspace, mount_root=mount_root, repo=repo_name)
            except ValueError as exc:
                return json.dumps({"error": "cannot read table", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "read_table_error", "error": str(exc)}))
                return json.dumps({"error": "read table failed", "detail": "internal error (see service logs)"})

        # Ship the FULL docstrings as the tool description (FastMCP uses `description or
        # __doc__`, so passing a terse description= DROPS the docstring the model needs to
        # disambiguate the tools). Per Anthropic "writing tools for agents": the description
        # is the primary signal the model uses to pick + call a tool correctly.
        app.add_tool(codegraph_read_file, name="codegraph_read_file",
                     description=(codegraph_read_file.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        app.add_tool(codegraph_glob_files, name="codegraph_glob_files",
                     description=(codegraph_glob_files.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        app.add_tool(codegraph_read_table, name="codegraph_read_table",
                     description=(codegraph_read_table.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        logger.info(json.dumps({"event": "search_tool_enabled", "local_workspace": local_workspace,
                                "file_tools": ["codegraph_read_file", "codegraph_glob_files", "codegraph_read_table"]}))
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
        # Autonomous recovery: heal a dead/wedged worker on a health poll, so an
        # IDLE instance (no user traffic) recovers without waiting for a query —
        # otherwise a health-gated load balancer would see 503 forever. Single-
        # flight + best-effort (never raises); a no-op when the worker is healthy.
        await session.maybe_self_heal()
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
        # CONCURRENCY: this read-modify-write is NOT guarded by a lock, and is safe ONLY
        # because the bridge runs a SINGLE uvicorn worker = ONE event loop, and there is
        # NO `await` between the read and the write below (the only await in this handler
        # is maybe_self_heal() far above). Concurrent stateless_http handlers are asyncio
        # tasks on that one loop; without an await between them they cannot interleave, so
        # the RMW is effectively atomic (cross-review flagged a race assuming truly-parallel
        # handlers — there aren't any here). If a future change adds an await between these
        # lines, or moves the bridge to threaded/multi-worker serving, guard this with a
        # lock. (Same single-loop assumption the CodegraphSession single-writer rests on.)
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

    # SINGLE-WRITER HARD GUARD — take the workspace flock early so a conflict exits
    # cleanly (return 1) before any worker work. build_bridge() re-calls this (it's
    # idempotent — no-op when this process already holds it) so an app-factory launch
    # that bypasses main() is still guarded. See acquire_singleton_writer_lock().
    try:
        acquire_singleton_writer_lock(args.workspace)
    except SingleWriterConflict:
        return 1  # the helper already logged bridge_singleton_conflict

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
