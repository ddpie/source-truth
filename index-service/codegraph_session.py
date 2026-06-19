"""Persistent codegraph-server MCP session (the resident half of the bridge).

The naive client (codegraph_client.acall_tool) spawns a fresh codegraph-server
process per query. For a large repo on EFS that means re-scanning ~8.7k files on
every call (~20s cold) — unusable on a user request path. codegraph-server keeps
the call graph in memory for the lifetime of one ``--mcp`` process, so the fix is
to hold ONE long-lived process and relay every query into it: first query warms
the graph (~20s), every subsequent query is single-digit milliseconds.

Why a dedicated thread + private event loop (not an asyncio task in the bridge's
loop): the bridge runs FastMCP with ``stateless_http=True`` over uvicorn/anyio,
which cancels child tasks created in its lifespan scope and runs each HTTP
request in its own task scope — an ``stdio_client`` subprocess opened there gets
torn down. Owning the subprocess in a SEPARATE thread with its own asyncio loop
isolates it completely from FastMCP's scopes; the bridge submits queries with
``run_coroutine_threadsafe`` and awaits the result.

Reliability contract (POC prime directive: code is the only source of truth):
- Health is asserted at warmup AND re-validated on every response. ANY response
  that isn't a well-formed non-empty-graph result (parse failure, error envelope,
  ``isError``, missing ``results`` list, or a "0 nodes" warning) marks the session
  UNHEALTHY. An unhealthy session makes the bridge REFUSE (explicit error), never
  return empty results that would fabricate a "not found" answer.
- If the codegraph subprocess dies, the next call detects it, marks unhealthy,
  and restarts the worker once (single-flight) so the service self-heals.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from datetime import timedelta
from time import perf_counter
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from perf import perf_entry

logger = logging.getLogger("codegraph-session")

DEFAULT_EXCLUDES = ("node_modules", ".venv", ".git")

# Bounded timeouts so a hung codegraph-server can never wedge the service forever.
# Without these, session.call_tool awaits indefinitely WHILE HOLDING _call_lock →
# every other request blocks on the lock, the liveness probe (same lock) can't run,
# _healthy never flips, /health lies 200, and the self-heal never fires. A timeout
# converts that permanent wedge into a TimeoutError → unhealthy → worker exits →
# _needs_restart() respawns a fresh process (single-writer preserved by the join
# guard). WARMUP is generous (cold graph load from EFS ~20s, headroom to 90s);
# QUERY bounds a pathological traversal; LIVENESS is short so health tracks reality.
WARMUP_TIMEOUT_S = 90.0
QUERY_TIMEOUT_S = 30.0
LIVENESS_TIMEOUT_S = 8.0


class IndexUnhealthy(RuntimeError):
    """Raised when the codegraph session is not serving a valid, non-empty graph."""


class CodegraphSession:
    """Owns one long-lived codegraph-server ``--mcp`` process in its own thread."""

    def __init__(
        self,
        workspace: str,
        *,
        graph_only: bool = True,
        max_files: int = 10000,
        excludes: tuple[str, ...] = DEFAULT_EXCLUDES,
    ) -> None:
        self._workspace = workspace
        self._graph_only = graph_only
        self._max_files = max_files
        self._excludes = excludes
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._session: ClientSession | None = None
        self._call_lock: asyncio.Lock | None = None  # lives on the worker loop
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._restart_lock: asyncio.Lock | None = None  # lives on the bridge loop
        # Health: True only when warmup confirmed a non-empty graph AND no
        # subsequent response has signalled degradation. The bridge refuses to
        # serve when this is False (never answers on a broken/empty index).
        self._healthy = False
        self._health_detail = "starting"

    def _params(self) -> StdioServerParameters:
        args = ["--mcp", "--workspace", self._workspace]
        if self._graph_only:
            args.append("--graph-only")
        args += ["--max-files", str(self._max_files)]
        for ex in self._excludes:
            args += ["--exclude", ex]
        return StdioServerParameters(command="codegraph-server", args=args)

    # ---- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        """Launch the worker thread (idempotent). Returns immediately."""
        if self._thread is not None and self._thread.is_alive():
            return
        # Fresh sync primitives for a fresh worker (start may be a restart).
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._session = None
        self._loop = None
        self._thread = threading.Thread(target=self._thread_main, name="codegraph-session", daemon=True)
        self._thread.start()

    def _thread_main(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._serve())
        except Exception as exc:  # noqa: BLE001
            self._healthy = False
            self._health_detail = "worker died: %s" % str(exc)
            logger.error(json.dumps({"event": "worker_died", "error": str(exc)}))
        finally:
            # Clear references so a stale call can't run on a closed loop; the
            # next call_tool sees thread-dead and restarts cleanly.
            self._session = None
            self._loop = None
            self._ready.set()  # unblock any waiter so it sees the (unhealthy) state
            try:
                loop.close()
            except Exception:  # noqa: BLE001
                pass

    async def _serve(self) -> None:
        """Own the subprocess + session for the thread's whole lifetime."""
        self._call_lock = asyncio.Lock()
        async with stdio_client(self._params()) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                self._session = session
                logger.info(json.dumps({"event": "session_started", "workspace": self._workspace}))
                # Warm the graph (pays the cold ~20s index/EFS-load cost here) and
                # assert it is non-empty before declaring the session healthy.
                warm_t0 = perf_counter()
                try:
                    # Bounded: a warmup that hangs (codegraph stuck on a blocked EFS
                    # read) must not leave _ready unset forever — that would wedge
                    # every request at wait_ready for 120s on repeat with no restart.
                    # On timeout we flip unhealthy, set _ready, and fall through to
                    # return from _serve so the thread exits and _needs_restart()
                    # respawns a fresh worker.
                    result = await session.call_tool(
                        "codegraph_symbol_search", {"query": "__warmup__"},
                        read_timeout_seconds=timedelta(seconds=WARMUP_TIMEOUT_S),
                    )
                    warm_ms = (perf_counter() - warm_t0) * 1000
                    unhealthy, reason = self._classify(result)
                    if unhealthy:
                        self._healthy = False
                        self._health_detail = "warmup: %s" % reason
                        logger.error(json.dumps({"event": "warmup_unhealthy", "reason": reason}))
                    else:
                        self._healthy = True
                        self._health_detail = "ok"
                        logger.info(json.dumps({"event": "warmup_done", "workspace": self._workspace}))
                    # Perf: warmup is the cold graph-load-from-EFS cost — the single
                    # biggest one-time latency; logged so it's visible in analysis.
                    logger.info(perf_entry("codegraph_warmup", warm_ms, workspace=self._workspace,
                                           healthy=not unhealthy))
                except Exception as exc:  # noqa: BLE001
                    self._healthy = False
                    self._health_detail = "warmup failed: %s" % str(exc)
                    logger.error(json.dumps({"event": "warmup_failed", "error": str(exc)}))
                    # A hung/failed warmup must self-heal: unblock waiters and exit
                    # _serve so the thread ends → _needs_restart() (dead thread) →
                    # _restart() brings up a fresh worker on the next call.
                    self._ready.set()
                    return
                self._ready.set()
                # Keep the loop (and subprocess) alive until stop() is requested,
                # AND actively probe liveness so an IDLE subprocess death is caught
                # proactively. Without this, codegraph-server dying while no traffic
                # flows (OOM/crash of the grandchild process — systemd's
                # Restart=always only watches the python bridge, not the grandchild)
                # leaves _session non-None and _healthy True, so /health lies (200
                # over a dead graph) until the NEXT user query happens to fail. We
                # send a cheap symbol_search every few seconds (serialized through
                # the same _call_lock, so it can't race a real query) and flip
                # unhealthy + exit _serve the moment it fails — _needs_restart()
                # then recovers on the next request, and /health reflects reality
                # within one probe interval instead of waiting for a user to hit it.
                probe_every = 5.0
                since_probe = 0.0
                while not self._stop.is_set():
                    await asyncio.sleep(0.5)
                    since_probe += 0.5
                    if since_probe < probe_every:
                        continue
                    since_probe = 0.0
                    try:
                        async with self._call_lock:
                            probe = await session.call_tool(
                                "codegraph_symbol_search", {"query": "__liveness__"},
                                read_timeout_seconds=timedelta(seconds=LIVENESS_TIMEOUT_S),
                            )
                        unhealthy, reason = self._classify(probe)
                        if unhealthy:
                            self._healthy = False
                            self._health_detail = "liveness: %s" % reason
                            logger.error(json.dumps({"event": "liveness_unhealthy", "reason": reason}))
                            return  # exit _serve → thread ends → _needs_restart() recovers
                        # A successful probe re-affirms health (recovers a transient
                        # blip that a failed user query may have flipped).
                        self._healthy = True
                        self._health_detail = "ok"
                    except Exception as exc:  # noqa: BLE001 - subprocess/stream died
                        self._healthy = False
                        self._health_detail = "liveness probe failed: %s" % str(exc)
                        logger.error(json.dumps({"event": "liveness_failed", "error": str(exc)}))
                        return  # exit _serve → thread ends → next call restarts worker

    async def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            await asyncio.get_running_loop().run_in_executor(None, self._thread.join, 10)
            if self._thread.is_alive():
                logger.error(json.dumps({"event": "stop_timeout", "detail": "worker thread still alive after 10s"}))
            self._thread = None

    # ---- health classification ----------------------------------------------

    # The "non-empty container" key each exposed tool returns on a healthy graph.
    # _classify only asserts that the key is a list (it MAY be empty — a legit
    # "no callers"/"no symbol" answer on a healthy graph). The shapes were
    # verified live against codegraph-server 0.18.5; warmup always uses
    # symbol_search, so an unknown/None tool name falls back to its contract.
    _RESULT_KEY_BY_TOOL = {
        "codegraph_symbol_search": "results",
        "codegraph_get_callers": "callers",
        "codegraph_analyze_impact": "impacted",
    }

    @classmethod
    def _classify(cls, result: Any, tool_name: str | None = None) -> tuple[bool, str]:
        """Return (unhealthy, reason) for a codegraph CallToolResult.

        Anything that isn't a well-formed, non-empty-graph result is treated as
        unhealthy — we refuse rather than risk fabricating a "not found" answer.
        Tool-aware: each exposed tool returns a different top-level container
        (results / callers / impacted), so the missing-container check keys off
        the tool name instead of assuming every response has a ``results`` list.
        """
        # MCP-level tool error (isError) or no content block at all → unhealthy.
        if getattr(result, "isError", False):
            return True, "tool returned isError"
        content = getattr(result, "content", None)
        if not content:
            return True, "empty content (no result block)"
        if not isinstance(content, (list, tuple)):
            return True, "content is not a list"
        text = getattr(content[0], "text", None)
        if not text:
            return True, "empty result text"
        try:
            data = json.loads(text)
        except (ValueError, TypeError):
            return True, "response was not valid JSON"
        if not isinstance(data, dict):
            return True, "response JSON was not an object"
        if data.get("error") or data.get("exception"):
            return True, "response carried an error/exception field"
        # The container must be a list (it may be EMPTY — a healthy "no match" /
        # "no callers" answer). Only symbol_search carries the 0-nodes warning.
        result_key = cls._RESULT_KEY_BY_TOOL.get(tool_name or "codegraph_symbol_search", "results")
        if not isinstance(data.get(result_key), list):
            return True, f"response missing a {result_key} list"
        warning = str(data.get("warning", ""))
        if "0 nodes" in warning or "only 0" in warning:
            return True, "graph has 0 nodes (corrupt/unindexed)"
        return False, "ok"

    @property
    def healthy(self) -> bool:
        # AND-gate on the worker thread actually being alive: _healthy is a flag
        # flipped by warmup / responses / the liveness probe, but between probe
        # ticks a just-dead worker could still read True. Requiring a live thread
        # means /health can never out-live a dead worker. (_needs_restart() will
        # bring a fresh worker up on the next call_tool.)
        return self._healthy and self._thread is not None and self._thread.is_alive()

    @property
    def health_detail(self) -> str:
        return self._health_detail

    async def wait_ready(self, timeout: float = 120.0) -> bool:
        """Block (cooperatively) until warmup finishes, then report health.

        Polls the worker's readiness flag with ``asyncio.sleep`` — no executor
        thread per caller, so a burst of concurrent first requests can't exhaust
        the thread pool. Distinguishes "still warming up" (wait) from "unhealthy"
        (the boolean return) so callers refuse only on genuine breakage.
        """
        if self._thread is None or not self._thread.is_alive():
            self.start()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while not self._ready.is_set():
            if loop.time() > deadline:
                return False
            await asyncio.sleep(0.2)
        return self._healthy

    # ---- query path ----------------------------------------------------------

    async def _do_call(self, name: str, arguments: dict[str, Any]) -> str:
        assert self._session is not None and self._call_lock is not None
        # Timing spans the single-writer lock too: lock-wait under concurrent
        # load is itself a latency source worth seeing (RocksDB serializes here),
        # so measure wait+call as one number rather than hiding the queueing.
        t0 = perf_counter()
        async with self._call_lock:  # codegraph isn't concurrent-safe on its graph
            # Bounded: a pathological query must not hold _call_lock forever (which
            # would head-of-line-block every other caller AND freeze the liveness
            # probe). On timeout the MCP layer raises → _do_call's caller flips
            # unhealthy and the worker recovers, rather than wedging permanently.
            result = await self._session.call_tool(
                name, arguments, read_timeout_seconds=timedelta(seconds=QUERY_TIMEOUT_S)
            )
        logger.info(perf_entry("codegraph_call", (perf_counter() - t0) * 1000, tool=name))
        # Re-validate health on every response — a graph that degrades after
        # startup must flip us unhealthy, not silently serve garbage. Tool-aware:
        # each tool's healthy envelope has a different container (results/callers/
        # impacted), so pass the name through.
        unhealthy, reason = self._classify(result, name)
        if unhealthy:
            self._healthy = False
            self._health_detail = reason
            raise IndexUnhealthy(reason)
        return getattr(result.content[0], "text", "")

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> str:
        """Relay one tool call into the resident worker; self-heals once on death.

        Called from the bridge's event loop. Bridges to the worker loop with
        ``run_coroutine_threadsafe``. If the worker/subprocess has died, restarts
        it once (single-flight) before failing — so a crashed codegraph recovers
        on the next request instead of wedging the service permanently.
        """
        if self._restart_lock is None:
            self._restart_lock = asyncio.Lock()

        # Recover from BOTH failure modes: a dead worker thread, AND a thread
        # that is alive but wedged unhealthy. The decision is made INSIDE the
        # restart lock (see _restart) so two concurrent requests can't each fire
        # a restart and have the 2nd kill the 1st's freshly-warming worker
        # (churn). _restart re-checks _needs_restart under the lock and no-ops if
        # another caller already recovered.
        if self._needs_restart():
            await self._restart()

        healthy = await self.wait_ready()
        if not healthy:
            raise IndexUnhealthy(self._health_detail)

        loop = self._loop
        if loop is None or self._session is None:
            raise IndexUnhealthy("worker not running")
        try:
            cf = asyncio.run_coroutine_threadsafe(self._do_call(name, arguments), loop)
            return await asyncio.wrap_future(cf)
        except IndexUnhealthy:
            raise
        except Exception as exc:  # noqa: BLE001 - subprocess/loop died mid-call
            self._healthy = False
            self._health_detail = "call failed: %s" % str(exc)
            logger.error(json.dumps({"event": "call_failed", "tool": name, "error": str(exc)}))
            raise IndexUnhealthy(self._health_detail) from exc

    async def maybe_self_heal(self) -> None:
        """Restart the worker if it's dead/wedged — WITHOUT needing a user query.

        Crash recovery is otherwise request-triggered (only call_tool restarts), so
        an IDLE instance whose subprocess died would sit unhealthy until traffic
        resumes — and a health-gated load balancer polling /health would never see
        it recover (it might even pull the instance from rotation). Calling this from
        the /health probe makes recovery autonomous: each poll heals a dead/wedged
        worker. Single-flight + idempotent (shares _restart's lock), so concurrent
        /health polls + a real query can't spawn two writers. Best-effort: a failed
        restart leaves health False (the next poll retries), never raises."""
        if self._restart_lock is None:
            self._restart_lock = asyncio.Lock()
        if not self._needs_restart():
            return
        try:
            await self._restart()
        except Exception as exc:  # noqa: BLE001 - health probe must never raise
            logger.warning(json.dumps({"event": "self_heal_failed", "error": str(exc)}))

    def _needs_restart(self) -> bool:
        """Whether the worker must be (re)started: dead thread, or alive-but-wedged.

        A thread that is alive but whose FIRST warmup hasn't finished yet
        (_ready not set) is NOT wedged — it's still coming up, so we wait rather
        than restart. Only an alive thread that finished warmup AND is unhealthy
        counts as wedged (failed warmup / post-success degradation).
        """
        if self._thread is None or not self._thread.is_alive():
            return True
        return self._ready.is_set() and not self._healthy

    async def _restart(self) -> None:
        """Single-flight restart of the worker (recovery from crash OR wedge).

        Idempotent under concurrency: the restart DECISION is re-evaluated INSIDE
        the lock, so if another caller already recovered (worker healthy, or a
        fresh worker still warming up), this no-ops — preventing two concurrent
        requests from each restarting and the 2nd killing the 1st's new worker.
        """
        assert self._restart_lock is not None
        async with self._restart_lock:
            if not self._needs_restart():
                return  # someone else already restarted (healthy, or warming up)
            logger.error(json.dumps({"event": "worker_restart", "workspace": self._workspace,
                                      "detail": self._health_detail}))
            # Signal any wedged-but-alive worker to exit, then start fresh — but
            # ONLY after confirming the old worker is actually gone. If we spawned
            # a new worker while the old one's codegraph subprocess were still
            # alive, BOTH would write the same graph.db → RocksDB corruption (the
            # single-writer invariant the whole design rests on). So if the old
            # thread won't die within the join window, refuse rather than risk a
            # second writer; a later call_tool will retry the restart.
            self._stop.set()
            if self._thread is not None and self._thread.is_alive():
                await asyncio.get_running_loop().run_in_executor(None, self._thread.join, 12)
                if self._thread.is_alive():
                    self._healthy = False
                    self._health_detail = "old worker still alive; refusing to spawn a second writer"
                    logger.error(json.dumps({"event": "restart_blocked",
                                             "detail": "old worker did not exit; not starting a second writer"}))
                    raise IndexUnhealthy(self._health_detail)
            self._thread = None
            self._healthy = False
            self._health_detail = "restarting"
            self.start()
