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
import os
import re
import signal
import subprocess
import threading
import time
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
# A SINGLE failed liveness probe must NOT end the worker: an 8s probe can be lost
# to a transient blip — a GC pause, or a heavy real query holding _call_lock past
# the probe's timeout — and a full cold restart (~20s reindex) over a transient
# blip is a self-inflicted outage (the "restart storm" risk). Only TREAT the worker
# as dead after this many CONSECUTIVE probe failures; any success resets the count.
# A real subprocess death fails every probe, so it's still caught within
# THRESHOLD × probe_every (~10s) — fast enough for /health to track reality.
LIVENESS_FAILURE_THRESHOLD = 2
# After this many CONSECUTIVE blocked restarts (wedged thread / unverifiable orphan),
# self-exit so systemd (Restart=always) brings up a clean process — see _blocked_restarts.
MAX_BLOCKED_RESTARTS = 5


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
        # Created EAGERLY (not lazily on first call_tool): an asyncio.Lock() since
        # py3.10 binds to the running loop on first await, not at construction, so
        # this is safe in __init__. Eager creation removes the `if is None:` lazy
        # blocks whose non-atomicity was only ever safe because there's exactly ONE
        # bridge event loop. SINGLE-WRITER INVARIANT: that one-loop assumption is
        # load-bearing — the bridge MUST run uvicorn single-worker. If anyone sets
        # uvicorn workers>1, each worker process gets its own CodegraphSession →
        # multiple graph.db writers → corruption. The flock guards cross-PROCESS
        # races; this lock guards in-process restart churn. Keep both.
        # Restart/stop mutual exclusion. A THREADING lock, NOT asyncio.Lock: an
        # asyncio.Lock binds to whichever event loop first awaits it, and
        # maybe_self_heal() is invoked from the FastMCP /health route which can run
        # in a DIFFERENT anyio task scope than call_tool/stop. If /health acquired
        # first, a later `await` from the bridge loop would raise "Future attached to
        # a different loop" or silently fail to serialize — defeating the single-
        # writer guard exactly when stop() races a self-heal. A threading.Lock is
        # loop-agnostic and correct regardless of caller loop/thread; the async
        # callers acquire it off-loop via run_in_executor so they never block the loop.
        self._restart_lock = threading.Lock()
        # Health: True only when warmup confirmed a non-empty graph AND no
        # subsequent response has signalled degradation. The bridge refuses to
        # serve when this is False (never answers on a broken/empty index).
        self._healthy = False
        self._health_detail = "starting"
        # Count CONSECUTIVE restarts that were BLOCKED (old thread won't die, or the
        # orphan set couldn't be verified). Such a block is usually PERSISTENT — the
        # worker thread is wedged in a C call join() can't interrupt — so every later
        # /health poll re-hits the same block and the service stays 503 FOREVER. The
        # bridge's systemd unit is Restart=always but only watches the python PROCESS,
        # which is still alive, so it can't recover a wedged thread. After
        # MAX_BLOCKED_RESTARTS in a row we self-exit so systemd restarts the whole
        # process clean — the only thing that can clear a wedged thread (cross-review F2).
        self._blocked_restarts = 0

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
        # ORDERING INVARIANT (load-bearing for the no-concurrent-call guarantee, cross-
        # review): _call_lock MUST be assigned here BEFORE _ready is set (below, after
        # warmup). call_tool gates every query on wait_ready() (which blocks on _ready),
        # so no _do_call can reach `async with self._call_lock` until _ready is set — by
        # which point this fresh lock exists. That, plus _restart fully join()ing the old
        # worker thread before start()ing a new one, is what guarantees two _do_call
        # coroutines never run the codegraph call concurrently across a restart. Do NOT
        # move _ready.set() before this line, and do NOT reset _call_lock in start().
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
                consecutive_failures = 0  # only end the worker after THRESHOLD in a row
                while not self._stop.is_set():
                    await asyncio.sleep(0.5)
                    since_probe += 0.5
                    if since_probe < probe_every:
                        continue
                    since_probe = 0.0
                    # A probe is "bad" if it errored OR classified unhealthy. We flip
                    # _healthy False immediately on a bad probe (so /health reflects the
                    # blip honestly), but only EXIT the worker — triggering a full cold
                    # restart — after THRESHOLD consecutive bad probes. A single good
                    # probe resets the streak and re-affirms health, so a transient blip
                    # (GC pause / a heavy query that held _call_lock past the timeout)
                    # self-recovers without a needless ~20s reindex.
                    bad = False
                    reason = ""
                    try:
                        async with self._call_lock:
                            probe = await session.call_tool(
                                "codegraph_symbol_search", {"query": "__liveness__"},
                                read_timeout_seconds=timedelta(seconds=LIVENESS_TIMEOUT_S),
                            )
                        unhealthy, why = self._classify(probe)
                        if unhealthy:
                            bad, reason = True, why
                    except Exception as exc:  # noqa: BLE001 - subprocess/stream died
                        bad, reason = True, "probe failed: %s" % str(exc)
                    consecutive_failures, should_exit = self._record_probe(consecutive_failures, bad)
                    if bad:
                        self._healthy = False
                        self._health_detail = "liveness: %s" % reason
                        logger.error(json.dumps({"event": "liveness_unhealthy", "reason": reason,
                                                 "consecutive": consecutive_failures}))
                        if should_exit:
                            logger.error(json.dumps({"event": "liveness_worker_exit",
                                                     "detail": "%d consecutive failed probes" % consecutive_failures}))
                            return  # exit _serve → thread ends → _needs_restart() recovers
                    else:
                        # A successful probe re-affirms health and clears the streak
                        # (recovers a transient blip a failed user query may have flipped).
                        self._healthy = True
                        self._health_detail = "ok"

    async def _acquire_restart_lock(self) -> None:
        """Acquire the (threading) restart lock WITHOUT blocking the event loop AND
        without parking an executor thread per waiter.

        The lock is a threading.Lock (loop-agnostic — see __init__). Two pitfalls:
          - a blocking .acquire() on the loop thread freezes the whole bridge;
          - submitting a BLOCKING .acquire() to the default executor (the old impl)
            parks one pool thread per waiter. Under a restart STORM (a burst of N
            concurrent requests all seeing _needs_restart() True) that exhausts the
            default ThreadPoolExecutor (~min(32, cpu+4), i.e. ~12), so the holder's
            OWN join()/reap() — also run_in_executor(None, …) — can never get a
            thread → the whole bridge deadlocks and /health stays 503 forever
            (cross-review CONFIRMED F1). Instead, poll a NON-blocking try-acquire with
            a cooperative asyncio.sleep: no executor thread is held while waiting, so
            the holder's join/reap always has the pool to itself."""
        while not self._restart_lock.acquire(blocking=False):
            await asyncio.sleep(0.05)

    async def stop(self) -> None:
        # Hold _restart_lock so shutdown is mutually exclusive with _restart /
        # maybe_self_heal. Without it, a /health-poll-triggered self-heal could
        # start() a NEW worker while stop() is draining the OLD one — leaving a live
        # worker thread with _thread=None (an orphaned codegraph-server subprocess
        # stop() can't join and `healthy` can't see).
        await self._acquire_restart_lock()
        try:
            self._stop.set()
            if self._thread is not None:
                await asyncio.get_running_loop().run_in_executor(None, self._thread.join, 10)
                if self._thread.is_alive():
                    logger.error(json.dumps({"event": "stop_timeout", "detail": "worker thread still alive after 10s"}))
                self._thread = None
        finally:
            self._restart_lock.release()

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
        cf = asyncio.run_coroutine_threadsafe(self._do_call(name, arguments), loop)
        try:
            return await asyncio.wrap_future(cf)
        except asyncio.CancelledError:
            # The bridge-side request was cancelled (client disconnected / gateway
            # gave up). wrap_future's cancellation only drops the bridge-side wrapper;
            # it does NOT cancel the _do_call coroutine already running on the WORKER
            # loop, which keeps holding _call_lock until QUERY_TIMEOUT_S (~30s) —
            # head-of-line-blocking every other request and the liveness probe, and
            # can cascade into needless cold restarts (cross-review CONFIRMED F2).
            # Propagate the cancel across the loop boundary so the worker releases
            # _call_lock promptly. The future returned by run_coroutine_threadsafe is
            # cancel-thread-safe: cf.cancel() schedules cancellation of the underlying
            # coroutine on the worker loop (best-effort — if it's mid blocking C call
            # it lands at the next await, still far sooner than the 30s timeout).
            cf.cancel()
            raise
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
        if not self._needs_restart():
            return
        try:
            await self._restart()
        except Exception as exc:  # noqa: BLE001 - health probe must never raise
            logger.warning(json.dumps({"event": "self_heal_failed", "error": str(exc)}))

    @staticmethod
    def _record_probe(consecutive_failures: int, bad: bool) -> tuple[int, bool]:
        """Pure streak bookkeeping for the liveness probe. Returns the updated
        consecutive-failure count and whether the worker should EXIT (restart).
        A good probe resets the streak; the worker exits only once the streak
        reaches LIVENESS_FAILURE_THRESHOLD so a transient blip can't force a
        full cold restart. Extracted (pure) so the threshold logic is unit-tested
        without driving the live _serve subprocess loop."""
        if not bad:
            return 0, False
        consecutive_failures += 1
        return consecutive_failures, consecutive_failures >= LIVENESS_FAILURE_THRESHOLD

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
        await self._acquire_restart_lock()
        try:
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
                    self._note_blocked_restart("wedged_thread")
                    raise IndexUnhealthy(self._health_detail)
            self._thread = None
            self._healthy = False
            self._health_detail = "restarting"
            # BACKSTOP (single-writer): the join above proved the old worker THREAD
            # is dead, but the thread's death does not by itself guarantee its
            # codegraph-server CHILD was reaped (stdio_client's __aexit__ sends
            # SIGTERM + waits, but a hard loop teardown could skip that). flock is
            # held once by THIS python pid for its whole life, so it does NOT stop a
            # second child of the same pid from writing graph.db. Before spawning a
            # fresh worker, kill any surviving codegraph-server orphan — at this exact
            # point (old thread confirmed dead, new not yet started) ANY live one is
            # an orphan that would become a second writer.
            # The reaper returns False if it could NOT verify the orphan set (every
            # pgrep query errored/timed out). In that case we don't KNOW whether an
            # orphan survives, so spawning would risk a second writer → graph.db
            # corruption. Mirror the "old worker still alive" branch above: refuse and
            # let a later call_tool retry, rather than start blind (cross-review HIGH —
            # close the silent-second-writer gap when verification itself fails).
            verified = await asyncio.get_running_loop().run_in_executor(None, self._reap_orphan_servers)
            if not verified:
                self._healthy = False
                self._health_detail = "orphan check unverifiable; refusing to spawn a second writer"
                logger.error(json.dumps({"event": "restart_blocked",
                                         "detail": "orphan reaper could not verify; not starting a second writer"}))
                self._note_blocked_restart("unverifiable_orphan")
                raise IndexUnhealthy(self._health_detail)
            # Got past both single-writer guards → a fresh worker is about to start.
            # Clear the blocked-restart streak (the wedge cleared).
            self._blocked_restarts = 0
            self.start()
        finally:
            self._restart_lock.release()

    def _note_blocked_restart(self, reason: str) -> None:
        """A restart was refused by a single-writer guard. Such blocks are usually
        PERSISTENT (a thread wedged in a C call, or pgrep persistently failing), so
        every later /health poll re-hits it and the service stays 503 forever while
        systemd's Restart=always (it only watches the live python process) can't help.
        After MAX_BLOCKED_RESTARTS in a row, self-exit so systemd restarts the whole
        process clean — the only way to clear a wedged thread. SIGTERM first (lets the
        unit stop gracefully), os._exit as a hard backstop (cross-review F2)."""
        self._blocked_restarts += 1
        if self._blocked_restarts >= MAX_BLOCKED_RESTARTS:
            logger.error(json.dumps({
                "event": "restart_blocked_giving_up",
                "detail": "%d consecutive blocked restarts (%s); self-exiting for a clean systemd restart"
                          % (self._blocked_restarts, reason),
            }))
            # Best-effort graceful stop, then hard exit if the signal doesn't take.
            try:
                os.kill(os.getpid(), signal.SIGTERM)
            except Exception:  # noqa: BLE001
                pass
            os._exit(1)

    def _scan_orphan_servers(self) -> tuple[set[int], bool]:
        """ONE point-in-time scan for codegraph-server processes bound to OUR workspace.
        Returns (pids, queried_ok). stdlib-only (no psutil); never raises.

        Match by TWO pgrep queries, unioned:
          (a) direct children of this pid (`-P self`), AND
          (b) ANY process whose cmdline contains `codegraph-server … --workspace <ours>`.
        (b) is the critical one: a hard worker-loop teardown can leave the
        codegraph-server REPARENTED to init (PPID=1), which `-P self` never sees —
        that reparented orphan is exactly the silent second-writer the old code missed
        (cross-review C1). The `--workspace <ours>` anchor keeps us from touching an
        unrelated codegraph-server serving a different repo on the same host.

        ``queried_ok`` is True iff at least one pgrep ran cleanly (exit 0 = matched,
        1 = no match — both valid empty results; >=2 = a real error). If NO query could
        run we never actually looked, so the caller must NOT treat an empty pid set as
        proof of "no orphan"."""
        pids: set[int] = set()
        any_query_ok = False
        # pgrep -f treats the pattern as a regex; re.escape the workspace path so a
        # metachar in it (e.g. a '.' or '+') can't broaden the match to a sibling
        # workspace (…/code-5x matching …/code-5x.bak) — exact-anchor to OUR server.
        ws_re = re.escape(self._workspace)
        queries = (
            ["pgrep", "-P", str(os.getpid()), "-f", "codegraph-server"],
            ["pgrep", "-f", "codegraph-server.*--workspace %s" % ws_re],
        )
        for q in queries:
            try:
                out = subprocess.run(q, capture_output=True, text=True, timeout=5)
                if out.returncode in (0, 1):
                    any_query_ok = True
                else:
                    logger.warning(json.dumps({"event": "reap_orphan_query_failed",
                                               "rc": out.returncode, "stderr": out.stderr[:200]}))
                    continue
                for line in out.stdout.split():
                    try:
                        pid = int(line)
                    except ValueError:
                        continue
                    if pid != os.getpid():  # never target the bridge itself
                        pids.add(pid)
            except Exception as exc:  # noqa: BLE001 - best-effort; must never break restart
                logger.warning(json.dumps({"event": "reap_orphan_query_failed", "error": str(exc)}))
        return pids, any_query_ok

    @staticmethod
    def _kill_pids(pids: set[int]) -> bool:
        """SIGKILL each pid. Returns True iff every kill succeeded or the process was
        already gone (ProcessLookupError). A kill that fails for any OTHER reason
        (EPERM, …) returns False — we found an orphan we could NOT remove, so we cannot
        claim the workspace is writer-free."""
        kills_ok = True
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
                logger.error(json.dumps({"event": "reaped_orphan_codegraph", "pid": pid}))
            except ProcessLookupError:
                pass  # already gone — the normal case
            except Exception as exc:  # noqa: BLE001
                kills_ok = False
                logger.warning(json.dumps({"event": "reap_orphan_kill_failed", "pid": pid, "error": str(exc)}))
        return kills_ok

    def _reap_orphan_servers(self) -> bool:
        """SIGKILL any stray codegraph-server bound to OUR workspace, then PROVE none
        survives. Called only from _restart, under the restart lock, AFTER the old worker
        thread is confirmed dead — so at this instant there is NO live worker, hence ANY
        codegraph-server writing OUR workspace is an orphan that would become a second
        writer → graph.db corruption.

        SETTLE + RE-VERIFY loop (cross-review P1): a single point-in-time scan can MISS a
        codegraph-server the dying worker's stdio_client had just fork()ed but whose execve
        hadn't yet made it visible to pgrep — that orphan would then survive and become a
        second writer when start() fires. So we don't scan-once-kill-once: we loop
        scan→kill→settle→rescan and only return verified once a FRESH scan comes back EMPTY
        (proving no late-appearing fork remains). A scan that still finds pids means we kill
        them and loop again; a non-empty set on the LAST attempt → unverified (refuse).

        Returns True iff a scan ran cleanly AND a subsequent scan confirmed zero orphans.
        Returns False if NO query could ever run (we never looked), or orphans persist /
        can't be killed after all attempts — i.e. we cannot prove there's no surviving
        second writer, so the caller (_restart) must refuse to spawn."""
        # A few short settle rounds: enough for an in-flight execve to surface in pgrep
        # (sub-100ms in practice) without materially delaying a real restart.
        attempts = 4
        settle_s = 0.1
        any_query_ever = False
        for i in range(attempts):
            pids, queried_ok = self._scan_orphan_servers()
            any_query_ever = any_query_ever or queried_ok
            if queried_ok and not pids:
                # A clean scan that found NOTHING. On the FIRST iteration this could still
                # race a not-yet-visible fork, so require it to hold across a settle: sleep
                # and re-scan once more; only an empty confirmation scan returns verified.
                if i > 0:
                    # Safe to return without another settle: the ONLY process that could
                    # fork a new codegraph-server is the worker's stdio_client, and the
                    # worker thread is confirmed DEAD before the reaper runs. After round 0's
                    # kill + trailing sleep there is no live forker left, so the population
                    # only decays — an empty clean scan here is genuinely writer-free. (Round
                    # 0 is the only one that can race an in-flight execve, which is exactly
                    # where the extra settle+re-scan below sits.) Don't remove that asymmetry.
                    return True  # already settled at least once → confirmed empty
                time.sleep(settle_s)
                pids2, ok2 = self._scan_orphan_servers()
                if ok2 and not pids2:
                    return True
                # A fork surfaced during the settle → fall through to kill it below.
                pids, queried_ok = pids2, ok2
                any_query_ever = any_query_ever or queried_ok
            if pids:
                self._kill_pids(pids)
            time.sleep(settle_s)  # let SIGKILL take effect + any sibling fork surface
        # Final confirmation scan after the last kill+settle.
        pids_final, ok_final = self._scan_orphan_servers()
        any_query_ever = any_query_ever or ok_final
        verified = ok_final and not pids_final
        if not verified and pids_final:
            logger.error(json.dumps({"event": "reap_orphan_unverified",
                                     "detail": "orphans persist after %d attempts" % attempts,
                                     "remaining": sorted(pids_final)}))
        # If no query EVER ran we never looked → cannot claim writer-free.
        return verified and any_query_ever
