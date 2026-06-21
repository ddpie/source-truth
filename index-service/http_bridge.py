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
import asyncio
import json
import logging
import os
import posixpath
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

import path_align
from codegraph_session import CodegraphSession, IndexUnhealthy
from repo_fanout import merge_fanout
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


class _Repo:
    """One served repo: its codegraph session + the paths the tools resolve against.

    name      — repo identity (workspace basename); the <repo>/ path prefix + scope key.
    workspace — index-space path codegraph indexes (for path_align index_root).
    local     — local-disk copy the file tools read (read_file/glob/search/table).
    session   — the resident CodegraphSession for this repo's graph.
    """

    __slots__ = ("name", "workspace", "local", "session")

    def __init__(self, name: str, workspace: str, local: str | None, session: Any):
        self.name = name
        self.workspace = workspace
        self.local = local
        self.session = session


def build_bridge(
    *,
    workspace: str | None = None,
    workspaces: list[tuple[str, str | None]] | None = None,
    host: str = "127.0.0.1",
    port: int = 8080,
    mount_root: str = path_align.DEFAULT_MOUNT_ROOT,
    local_workspace: str | None = None,
) -> FastMCP:
    """Build (but don't run) the FastMCP HTTP bridge for one or more CodeGraph repos.

    Single-repo (today): pass ``workspace=`` (+ optional ``local_workspace=``). Multi-repo
    (阶段2): pass ``workspaces=[(workspace, local_workspace), ...]`` — one resident session per
    repo, all served by this one bridge process. The two forms are mutually exclusive.

    Each repo's ``workspace`` is the index-service-side path codegraph-server indexes (a
    LOCAL-disk copy); returned paths are rewritten into the agent's namespace — REPO-RELATIVE
    by default (``mount_root=""``), or under a legacy ``/mnt/repo`` if a non-empty
    ``mount_root`` is given — and PREFIXED with ``<repo>/`` so the agent can tell repos apart.
    ``local_workspace`` is the copy the file tools read; post-EFS-removal it's the SAME path
    as ``workspace``.

    A graph/file tool takes an optional ``repo`` arg routed SERVER-SIDE through a whitelist
    (不变量1): out-of-scope → rejected (never routed); in-scope → that repo's session; unset
    with multiple repos → FAN OUT across all (results merged); unset with one repo → that repo.
    """
    if workspaces is None:
        if workspace is None:
            raise ValueError("build_bridge requires either workspace= or workspaces=")
        workspaces = [(workspace, local_workspace)]
    elif workspace is not None:
        raise ValueError("pass either workspace= or workspaces=, not both")
    if not workspaces:
        raise ValueError("workspaces must be non-empty")

    # ONE resident codegraph-server process per repo holds that repo's graph in memory for
    # its whole lifetime. Spawning per-query instead re-scans the repo every call (~20s cold
    # for ~8.7k files) — unusable on a request path. Each worker serializes calls on its own
    # graph (codegraph isn't concurrent-safe); warm queries are single-digit ms.
    # max_files must match the build phase, or a resident session re-scans with a different
    # limit and rebuilds instead of loading the warm graph.
    max_files = int(os.environ.get("CODEGRAPH_MAX_FILES", "10000"))

    # GRAPH-HOME COORDINATION (不变量2): codegraph locates graph.db via $HOME/.codegraph, so the
    # SERVE session MUST point at the SAME $HOME the BUILD wrote to, or it finds no graph and
    # re-scans into an empty one (→ /health 503, "0 nodes"). bootstrap's index-build@<repo> unit
    # ALWAYS builds with HOME=<workspace>/.home (per-repo, even for a single repo), so serve must
    # ALWAYS use that same per-repo HOME — NOT just when multi-repo. (An earlier version only set
    # it for >1 repo, so the single-repo serve inherited HOME=/data and served an empty
    # /data/.codegraph while the build sat at <ws>/.home — caught in the first real deploy.)
    # Per-repo HOME also gives multi-repo its required graph isolation (distinct HOME per repo).
    repos: list[_Repo] = []
    for ws, local in workspaces:
        # SINGLE-WRITER GUARD per workspace — acquired HERE (before the worker spawns
        # codegraph-server), not just in main(), so an app-factory launch (gunicorn
        # http_bridge:app --workers N) can't bypass it and spawn duplicate writers. Each
        # workspace takes its OWN flock (see acquire_singleton_writer_lock / _WRITER_LOCK_FDS).
        acquire_singleton_writer_lock(ws)
        home = ws.rstrip("/") + "/.home"
        repos.append(_Repo(
            name=posixpath.basename(ws.rstrip("/")),
            workspace=ws,
            local=local,
            session=CodegraphSession(ws, max_files=max_files, home=home),
        ))

    by_name: dict[str, _Repo] = {r.name: r for r in repos}

    # SERVER-SIDE SCOPE ENFORCEMENT (不变量1 / 阶段3 gate): the in-scope set is exactly the
    # repos this bridge was built for. resolve() rejects any out-of-scope repo (never routes
    # it — the cross-project leak this stops); returns the sole repo when unset+single; returns
    # None when unset+multi (the caller fans out across all).
    router = RepoRouter([r.name for r in repos])

    # Back-compat single-repo handles: existing tests/inspection read app.codegraph_session
    # and `session`. With one repo it IS that repo; with many, the "primary" is repos[0].
    primary = repos[0]
    session = primary.session

    app = FastMCP(
        name="codegraph-bridge", host=host, port=port,
        stateless_http=True,
    )

    async def _resolve_uri_line(repo: _Repo, query: str) -> tuple[str, int]:
        """Resolve a symbol query to an index-space (uri, 0-based line) IN ONE REPO.

        get_callers/analyze_impact need a uri+line, but the agent only ever sees
        repo-relative paths and can't supply an index-space uri. So the bridge
        resolves the query itself via THIS repo's symbol_search session, taking the
        top-ranked hit. Raises IndexUnhealthy on an unusable index; ValueError if the
        symbol can't be located.
        """
        raw = await repo.session.call_tool("codegraph_symbol_search", {"query": query})
        # Pure, null-safe parse (unit-tested in test_http_bridge_resolve.py): any
        # unusable shape (null/non-dict symbol, missing location) raises ValueError
        # → clean "symbol not found", never a generic "{tool} failed".
        return _parse_symbol_location(raw, query)

    async def _build_args(repo: _Repo, tool_name: str, query: str) -> dict[str, Any]:
        """Map the uniform `query` UX onto each tool's real argument shape (per repo)."""
        if tool_name == "codegraph_symbol_search":
            return {"query": query}
        # get_callers / analyze_impact require uri+line — resolve from the query.
        uri, line = await _resolve_uri_line(repo, query)
        return {"uri": uri, "line": line}

    async def _run_on_repo(repo: _Repo, tool_name: str, query: str) -> str:
        """Run one graph tool against ONE repo's session and return aligned JSON.

        This is the PER-(repo,query) isolation boundary: every failure mode is caught
        and turned into an error envelope JSON (never propagates), so in a fan-out one
        repo's unhealthy/error can't blank the others — merge_fanout drops error
        envelopes and only surfaces an error if EVERY repo errored.
        """
        try:
            arguments = await _build_args(repo, tool_name, query)
            raw = await repo.session.call_tool(tool_name, arguments)
            # Align against THIS repo's workspace; prefix paths with <repo>/ (path honesty).
            return _align_paths(raw, tool_name, index_root=repo.workspace, mount_root=mount_root, repo=repo.name)
        except IndexUnhealthy as exc:
            logger.error(json.dumps({"event": "refuse_unhealthy", "tool": tool_name,
                                     "repo": repo.name, "detail": str(exc)}))
            return json.dumps({"error": "index unavailable", "detail": str(exc)})
        except ValueError as exc:
            # Symbol not locatable for a caller/impact query — not an index fault, so
            # report it as a normal "no match" without flipping health.
            logger.info(json.dumps({"event": "tool_no_match", "tool": tool_name,
                                     "repo": repo.name, "detail": str(exc)}))
            return json.dumps({"error": f"{tool_name}: symbol not found", "detail": str(exc)})
        except Exception as exc:  # noqa: BLE001 - isolate one (repo,query) failure
            # Generic detail only — str(exc) on an internal/transport error can carry
            # host paths/frames that must not reach the group-visible card.
            logger.error(json.dumps({"event": "tool_error", "tool": tool_name,
                                     "repo": repo.name, "error": str(exc)}))
            return json.dumps({"error": f"{tool_name} failed", "detail": "internal error (see service logs)"})

    def _make_tool(tool_name: str):
        # Uniform `query` arg → FastMCP generates a clean JSON schema and the
        # agent has one consistent UX. For tools that actually need uri+line
        # (get_callers, analyze_impact) the bridge resolves query→uri+line via
        # symbol_search internally (see _build_args) — the agent can't supply an
        # index-space uri because it only ever sees repo-relative paths.
        async def _tool(query: str, repo: str | None = None) -> str:
            # SERVER-SIDE SCOPE GATE FIRST (不变量1): resolve the agent's `repo` arg
            # through the whitelist before ANY session work. out-of-scope → reject
            # (never route); a specific in-scope repo → run there; unset + multiple
            # repos → fan out across all and merge; unset + single → that sole repo.
            try:
                resolved = router.resolve(repo)
            except RepoOutOfScope as exc:
                logger.warning(json.dumps({"event": "repo_out_of_scope", "tool": tool_name, "detail": str(exc)}))
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})

            if resolved is not None:
                # Single target repo (explicit in-scope, or the sole repo when unset).
                return await _run_on_repo(by_name[resolved], tool_name, query)

            # FAN OUT: unset repo + multiple in scope → query each concurrently, merge.
            # Each _run_on_repo isolates its own failure into an error envelope, so a
            # gather here can't raise; merge_fanout drops errored repos and only surfaces
            # an error if every repo errored.
            per_repo = await asyncio.gather(*[_run_on_repo(r, tool_name, query) for r in repos])
            return merge_fanout(tool_name, list(per_repo))

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

    # Fast file-content search/read over the LOCAL repo copy (replaces the agent's
    # builtin Grep/Read, which hit EFS/NFS at ~20-47s per whole-repo search; local is
    # ~0.2s). Registered only when EVERY served repo has a local copy on disk (single-
    # repo: that's `local_workspace`; multi-repo: each repo's `.local`).
    file_repos_ok = all(r.local and os.path.isdir(r.local) for r in repos)
    if file_repos_ok:
        import file_read
        import file_search
        import file_table

        def _repo_for_path(path: str, explicit: str | None) -> _Repo:
            """Route a PATH-based file tool (read_file/read_table) to ONE repo.

            explicit `repo` (if given) wins and is whitelist-validated (out-of-scope →
            RepoOutOfScope). Otherwise: single repo → the sole repo; multiple repos →
            INFER from the path's leading ``<repo>/`` segment (graph/search prefix every
            citation with it). If a multi-repo path has no recognizable prefix, refuse
            rather than guess (the agent must prefix it or pass repo=)."""
            resolved = router.resolve(explicit)  # explicit out-of-scope → RepoOutOfScope; unset+multi → None
            if resolved is not None:
                return by_name[resolved]
            seg = (path or "").replace("\\", "/").lstrip("/").split("/", 1)[0]
            if router.is_in_scope(seg):
                return by_name[seg]
            raise ValueError(
                f"cannot tell which repo {path!r} is in — prefix it with '<repo>/' "
                f"(one of {[r.name for r in repos]}) or pass repo="
            )

        def _file_targets(explicit: str | None) -> list[_Repo]:
            """Route a PATTERN-based file tool (search/glob) to a repo SET.

            explicit in-scope → [that repo]; out-of-scope → RepoOutOfScope; unset+single →
            [the sole repo]; unset+multiple → ALL repos (fan out across the project)."""
            resolved = router.resolve(explicit)
            return [by_name[resolved]] if resolved is not None else list(repos)

        def _merge_file_fanout(list_key: str, per_repo_json: list[str]) -> str:
            """Concatenate per-repo file-tool results (paths/matches already <repo>/-prefixed,
            so repos stay distinguishable). Mirrors graph fan-out: a per-repo error contributes
            nothing; if every repo errored, surface the first error (never a misleading empty)."""
            merged: dict[str, Any] = {list_key: [], "truncated": False, "count": 0}
            if list_key == "matches":
                merged["deduped"] = 0
            first_error: str | None = None
            saw_ok = False
            for raw in per_repo_json:
                try:
                    d = json.loads(raw)
                except (ValueError, TypeError):
                    continue
                if not isinstance(d, dict):
                    continue
                if "error" in d:
                    first_error = first_error or raw
                    continue
                saw_ok = True
                merged[list_key].extend(d.get(list_key, []) if isinstance(d.get(list_key), list) else [])
                merged["truncated"] = merged["truncated"] or bool(d.get("truncated"))
                if list_key == "matches":
                    merged["deduped"] += int(d.get("deduped", 0) or 0)
            if not saw_ok and first_error is not None:
                return first_error
            merged["count"] = len(merged[list_key])
            return json.dumps(merged, ensure_ascii=False)

        def _safe_file_call(fn, repo_name: str, what: str):
            """Run one repo's file-tool call inside the fan-out, isolating its failure into
            an error envelope (mirrors the graph fan-out's _run_on_repo). Without this, one
            repo raising would abort the whole list comprehension and blank the HEALTHY repos'
            results — violating "one repo's error must not blank the others"."""
            try:
                return fn()
            except ValueError as exc:
                # Recoverable input error (bad pattern) — echoes only agent input, safe.
                return json.dumps({"error": f"bad {what} pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one repo's failure
                # str(exc) may carry a host path → log it, return a generic detail only.
                logger.error(json.dumps({"event": f"{what}_error", "repo": repo_name, "error": str(exc)}))
                return json.dumps({"error": f"{what} failed on {repo_name}",
                                   "detail": "internal error (see service logs)"})

        async def codegraph_search_files(pattern: str, glob: str | None = None, repo: str | None = None) -> str:
            """Fast text search across the codebase (paths returned repo-relative,
            e.g. `Assets/Scripts/Foo.cs`; multi-repo prefixes them `<repo>/...`). `pattern`
            is a regex; optional `glob` narrows by filename (e.g. "*.cs", "*.json"); optional
            `repo` scopes to one repo (omit to search ALL repos in the project). Use this
            instead of shell grep."""
            try:
                targets = _file_targets(repo)
            except RepoOutOfScope as exc:
                logger.warning(json.dumps({"event": "repo_out_of_scope", "tool": "search_files", "detail": str(exc)}))
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})
            try:
                if len(targets) == 1:
                    t = targets[0]
                    return file_search.search_to_json(
                        pattern, local_root=t.local, mount_root=mount_root, glob=glob, repo=t.name,
                    )
                # FAN-OUT: each repo isolated via _safe_file_call so one repo's failure can't
                # blank the others (merge drops error envelopes; all-errored surfaces first).
                per_repo = [
                    _safe_file_call(
                        lambda t=t: file_search.search_to_json(
                            pattern, local_root=t.local, mount_root=mount_root, glob=glob, repo=t.name),
                        t.name, "search")
                    for t in targets
                ]
                return _merge_file_fanout("matches", per_repo)
            except ValueError as exc:
                # ValueError only echoes the agent-supplied pattern (no host path) → safe to return.
                return json.dumps({"error": "bad search pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                # str(exc) on an OSError/RuntimeError can embed an absolute HOST path
                # (/data/repo/...) — log it for the operator, but NEVER return it to the
                # model (it reaches the group-visible card). Generic detail only.
                logger.error(json.dumps({"event": "search_error", "error": str(exc)}))
                return json.dumps({"error": "search failed", "detail": "internal error (see service logs)"})

        async def codegraph_read_file(path: str, offset: int = 0, limit: int | None = None) -> str:
            """Read a source/config file's contents by its path (the path codegraph/search
            returns, e.g. `Assets/Scripts/Foo.cs` or `<repo>/Assets/Scripts/Foo.cs` —
            pass it back verbatim). Optional `offset` (0-based line) + `limit` page large
            files. Use this instead of a shell `cat` or builtin Read."""
            try:
                t = _repo_for_path(path, None)
            except RepoOutOfScope as exc:
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})
            except ValueError as exc:
                return json.dumps({"error": "cannot read file", "detail": str(exc)})
            try:
                return file_read.read_to_json(
                    path, local_root=t.local, mount_root=mount_root, offset=offset, limit=limit, repo=t.name,
                )
            except ValueError as exc:
                # ValueError echoes only the agent-supplied path (no host path) → safe.
                return json.dumps({"error": "cannot read file", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                # An OSError from open() serializes the absolute HOST path (/data/repo/...);
                # log it but return a generic detail so it can't leak into the group card.
                logger.error(json.dumps({"event": "read_error", "error": str(exc)}))
                return json.dumps({"error": "read failed", "detail": "internal error (see service logs)"})

        async def codegraph_glob_files(pattern: str, repo: str | None = None) -> str:
            """List files matching a glob `pattern` (e.g. "**/*.cs", "Config/*.json"),
            interpreted relative to the repo root. Returns paths in the agent's namespace
            (multi-repo prefixes them `<repo>/...`). Optional `repo` scopes to one repo
            (omit to glob ALL repos). Use this instead of a shell `ls`/`find` or builtin Glob."""
            try:
                targets = _file_targets(repo)
            except RepoOutOfScope as exc:
                logger.warning(json.dumps({"event": "repo_out_of_scope", "tool": "glob_files", "detail": str(exc)}))
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})
            try:
                if len(targets) == 1:
                    t = targets[0]
                    return file_read.glob_to_json(pattern, local_root=t.local, mount_root=mount_root, repo=t.name)
                # FAN-OUT: per-repo isolation so one repo's failure can't blank the others.
                per_repo = [
                    _safe_file_call(
                        lambda t=t: file_read.glob_to_json(pattern, local_root=t.local, mount_root=mount_root, repo=t.name),
                        t.name, "glob")
                    for t in targets
                ]
                return _merge_file_fanout("paths", per_repo)
            except ValueError as exc:
                return json.dumps({"error": "bad glob pattern", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "glob_error", "error": str(exc)}))
                return json.dumps({"error": "glob failed", "detail": "internal error (see service logs)"})

        async def codegraph_read_table(path: str) -> str:
            """Read a STRUCTURED config table that read_file can't (Excel .xlsx/.xls,
            .csv, .tsv, or a SQLite .db) — parsed server-side into plain text rows.
            Pass the path verbatim (a `<repo>/...` prefix is fine). Use this when the data
            lives in a spreadsheet/database config file (common for game numeric tables);
            for plain-text source/config use read_file."""
            try:
                t = _repo_for_path(path, None)
            except RepoOutOfScope as exc:
                return json.dumps({"error": "repo not in scope", "detail": str(exc)})
            except ValueError as exc:
                return json.dumps({"error": "cannot read table", "detail": str(exc)})
            try:
                return file_table.read_table_to_json(path, local_root=t.local, mount_root=mount_root, repo=t.name)
            except ValueError as exc:
                return json.dumps({"error": "cannot read table", "detail": str(exc)})
            except Exception as exc:  # noqa: BLE001 - isolate one query's failure
                logger.error(json.dumps({"event": "read_table_error", "error": str(exc)}))
                return json.dumps({"error": "read table failed", "detail": "internal error (see service logs)"})

        # Ship the FULL docstrings as the tool description (FastMCP uses `description or
        # __doc__`, so passing a terse description= DROPS the docstring the model needs to
        # disambiguate the tools). Per Anthropic "writing tools for agents": the description
        # is the primary signal the model uses to pick + call a tool correctly.
        app.add_tool(codegraph_search_files, name="codegraph_search_files",
                     description=(codegraph_search_files.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        app.add_tool(codegraph_read_file, name="codegraph_read_file",
                     description=(codegraph_read_file.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        app.add_tool(codegraph_glob_files, name="codegraph_glob_files",
                     description=(codegraph_glob_files.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        app.add_tool(codegraph_read_table, name="codegraph_read_table",
                     description=(codegraph_read_table.__doc__ or "").strip(),
                     annotations=READONLY_ANNOT)
        logger.info(json.dumps({"event": "search_tool_enabled", "repos": [r.name for r in repos],
                                "file_tools": ["codegraph_search_files", "codegraph_read_file",
                                               "codegraph_glob_files", "codegraph_read_table"]}))
    else:
        logger.warning(json.dumps({"event": "search_tool_disabled",
                                   "reason": "a served repo has no local copy on disk",
                                   "repos": [{"name": r.name, "local": r.local} for r in repos]}))

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
        # MULTI-REPO: heal EVERY repo's session and treat the bridge as healthy only
        # when ALL repos are healthy (one repo's empty/corrupt graph = degraded bridge;
        # the agent could otherwise answer "not found" off a broken repo). The detail
        # names the first unhealthy repo so ops can pinpoint which graph is down.
        for r in repos:
            await r.session.maybe_self_heal()
        unhealthy = [r for r in repos if not r.session.healthy]
        ok = not unhealthy
        if unhealthy:
            first = unhealthy[0]
            detail = (f"{len(unhealthy)}/{len(repos)} repo(s) unhealthy; "
                      f"first: {first.name}: {first.session.health_detail}")
        else:
            detail = session.health_detail
        # LOCAL repo read probe — A HEALTH GATE, not just telemetry. The agent reads
        # source over THIS bridge (read_file/glob_files/search_files) off the local
        # repo copy. codegraph answers from its IN-MEMORY graph (session.healthy
        # stays true) even if the on-disk copy becomes unreadable (disk fault, the
        # extract dir got wiped) — but then every agent file read fails and the user
        # gets a broken answer while /health lied 200. So a probe FAILURE flips
        # /health to unhealthy. A consecutive-fail counter avoids flapping on a
        # single transient error. Probes EACH repo's local copy (file tools read off it);
        # any one unreadable flips the bridge unhealthy. Falls back to the indexed
        # workspace when a repo has no separate local copy (same path post-EFS-removal).
        disk_ms = -1.0
        probe_ok = True
        try:
            import os
            import time as _t
            t0 = _t.perf_counter()
            total_entries = 0
            for r in repos:
                pr = r.local or r.workspace
                entries = os.listdir(pr)  # 1 metadata read per repo
                total_entries += len(entries)
                if entries:
                    os.stat(os.path.join(pr, entries[0]))  # stat read
            disk_ms = round((_t.perf_counter() - t0) * 1000, 1)
            logger.info(json.dumps({"event": "repo_probe", "perf": True,
                                    "latency_ms": disk_ms, "entries": total_entries,
                                    "repos": len(repos)}))
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

    # Start EACH repo's resident codegraph worker now, so it's running on EVERY serving
    # path (main() and tests alike) — not only when main() remembers to start it.
    # FastMCP's `lifespan=` is the MCP-session lifespan, NOT the ASGI startup
    # hook, so starting there never fired under the real server. Each worker owns
    # its own thread + event loop, so start() is safe here (returns immediately, warms
    # the graph in the background) and is idempotent.
    for r in repos:
        r.session.start()

    # Expose the sessions so callers can inspect health / stop them. `codegraph_session`
    # is the PRIMARY (back-compat: existing tests/inspection use it); `codegraph_sessions`
    # is the full list for multi-repo callers.
    app.codegraph_session = primary.session  # type: ignore[attr-defined]
    app.codegraph_sessions = [r.session for r in repos]  # type: ignore[attr-defined]
    app.codegraph_repos = repos  # type: ignore[attr-defined]
    return app


def pair_workspaces(workspace: list[str], local_workspace: list[str]) -> list[tuple[str, str | None]]:
    """Pair repeatable --workspace with --local-workspace BY POSITION → build_bridge input.

    Pure (no I/O) so it's unit-testable. Each --workspace[i] pairs with --local-workspace[i];
    a missing local (fewer --local-workspace than --workspace) → None for that repo. Rules:
      - at least one --workspace (fail-loud — a bridge with no repo is a deploy error);
      - --local-workspace count must not EXCEED --workspace count (a stray local with no
        matching workspace is a config mistake, not silently dropped);
      - duplicate workspace paths are rejected (two sessions on one graph.db → corruption).
    """
    if not workspace:
        raise ValueError("at least one --workspace is required")
    if len(local_workspace) > len(workspace):
        raise ValueError(
            f"--local-workspace given {len(local_workspace)}x but only {len(workspace)} "
            f"--workspace; each local pairs with a workspace by position")
    seen: set[str] = set()
    pairs: list[tuple[str, str | None]] = []
    for i, ws in enumerate(workspace):
        key = ws.rstrip("/")
        if key in seen:
            raise ValueError(f"duplicate --workspace {ws!r} (two sessions on one graph.db → corruption)")
        seen.add(key)
        local = local_workspace[i] if i < len(local_workspace) else None
        pairs.append((ws, local))
    return pairs


def main() -> int:
    p = argparse.ArgumentParser()
    # Repeatable for multi-repo: one --workspace per repo this bridge serves, each paired
    # BY POSITION with a --local-workspace. Single-repo passes one of each (unchanged).
    p.add_argument("--workspace", action="append", default=[],
                   help="repo path codegraph-server indexes (repeat for multi-repo)")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--mount-root", default=path_align.DEFAULT_MOUNT_ROOT)
    p.add_argument("--local-workspace", action="append", default=[],
                   help="local-disk copy for fast file search; pairs with --workspace by position "
                        "(grep over EFS is ~225x slower). Repeat for multi-repo.")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")

    try:
        pairs = pair_workspaces(args.workspace, args.local_workspace)
    except ValueError as exc:
        logger.error(json.dumps({"event": "bridge_bad_args", "detail": str(exc)}))
        return 2

    # SINGLE-WRITER HARD GUARD — take EACH workspace flock early so a conflict exits
    # cleanly (return 1) before any worker work. build_bridge() re-calls these (idempotent
    # per workspace) so an app-factory launch that bypasses main() is still guarded.
    try:
        for ws, _local in pairs:
            acquire_singleton_writer_lock(ws)
    except SingleWriterConflict:
        return 1  # the helper already logged bridge_singleton_conflict

    logger.info(json.dumps({"event": "bridge_start",
                            "workspaces": [ws for ws, _ in pairs],
                            "host": args.host, "port": args.port}))
    # build_bridge starts each repo's resident worker (warming in background).
    app = build_bridge(
        workspaces=pairs, host=args.host, port=args.port, mount_root=args.mount_root,
    )
    app.run(transport="streamable-http")
    return 0


if __name__ == "__main__":
    sys.exit(main())
