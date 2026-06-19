"""Unit tests for CodegraphSession._classify — pure, no codegraph-server/network.

_classify is the health gate: it must (a) accept each exposed tool's DISTINCT
healthy envelope (symbol_search→results, get_callers→callers, analyze_impact→
impacted), including a legitimately EMPTY container, and (b) still reject genuine
breakage (isError, error field, 0-nodes, malformed). Before the tool-aware fix,
a valid get_callers/analyze_impact response was misjudged "missing a results
list" and wedged the resident session — this guards that regression offline.
"""

from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")  # CodegraphSession imports mcp at module load

from codegraph_session import CodegraphSession  # noqa: E402


class _Content:
    def __init__(self, text: str) -> None:
        self.text = text


class _Result:
    """Minimal stand-in for an MCP CallToolResult."""

    def __init__(self, payload, *, is_error: bool = False) -> None:
        self.isError = is_error
        self.content = [_Content(json.dumps(payload))] if payload is not None else []


def _classify(payload, tool_name=None, *, is_error=False):
    return CodegraphSession._classify(_Result(payload, is_error=is_error), tool_name)


# ── healthy envelopes, tool-aware ───────────────────────────────────────────
def test_symbol_search_results_list_is_healthy():
    unhealthy, _ = _classify({"results": [{"symbol": {}}]}, "codegraph_symbol_search")
    assert unhealthy is False


def test_get_callers_callers_list_is_healthy():
    # No `results` key — must be accepted via the tool-aware `callers` container.
    unhealthy, reason = _classify(
        {"callers": [{"symbol": {}}], "symbol_name": "x"}, "codegraph_get_callers"
    )
    assert unhealthy is False, reason


def test_analyze_impact_impacted_list_is_healthy():
    unhealthy, reason = _classify(
        {"impacted": [{"path": "p"}], "risk_level": "low"}, "codegraph_analyze_impact"
    )
    assert unhealthy is False, reason


def test_empty_container_is_healthy_for_each_tool():
    # An empty list is a legit "no match"/"no callers" answer on a HEALTHY graph.
    assert _classify({"results": []}, "codegraph_symbol_search")[0] is False
    assert _classify({"callers": []}, "codegraph_get_callers")[0] is False
    assert _classify({"impacted": []}, "codegraph_analyze_impact")[0] is False


def test_unknown_or_missing_tool_defaults_to_symbol_search_contract():
    # warmup calls _classify with no tool name → must use the symbol_search key.
    assert _classify({"results": []})[0] is False
    assert _classify({"callers": []})[0] is True  # missing `results` under default


# ── breakage still rejected ─────────────────────────────────────────────────
def test_wrong_container_for_tool_is_unhealthy():
    # A get_callers response that somehow lacks `callers` is still unhealthy.
    unhealthy, reason = _classify({"results": []}, "codegraph_get_callers")
    assert unhealthy is True and "callers" in reason


def test_is_error_is_unhealthy():
    assert _classify({"callers": []}, "codegraph_get_callers", is_error=True)[0] is True


def test_error_field_is_unhealthy():
    assert _classify({"results": [], "error": "boom"}, "codegraph_symbol_search")[0] is True


def test_zero_nodes_warning_is_unhealthy():
    unhealthy, reason = _classify(
        {"results": [], "warning": "graph has 0 nodes"}, "codegraph_symbol_search"
    )
    assert unhealthy is True and "0 nodes" in reason


def test_malformed_json_is_unhealthy():
    bad = _Result(None)
    bad.content = [_Content("not json{")]
    assert CodegraphSession._classify(bad, "codegraph_symbol_search")[0] is True


def test_empty_content_is_unhealthy():
    assert CodegraphSession._classify(_Result(None), "codegraph_symbol_search")[0] is True


# ── health AND-gates on a live worker thread (subprocess-death defense) ──────
def test_healthy_is_false_when_worker_thread_is_dead():
    # A subprocess that dies while idle could leave _healthy True between liveness
    # probe ticks; /health must still report unhealthy because the worker thread
    # is gone. The `healthy` property AND-gates on a live thread to guarantee that.
    sess = CodegraphSession("/tmp/ws")
    sess._healthy = True  # flag says healthy …
    assert sess._thread is None  # … but no worker thread was ever started
    assert sess.healthy is False  # AND-gate → reported unhealthy

    class _DeadThread:
        def is_alive(self) -> bool:
            return False

    sess._thread = _DeadThread()  # type: ignore[assignment]
    assert sess.healthy is False  # dead thread → unhealthy even with _healthy True


def test_needs_restart_when_thread_dead_or_wedged():
    sess = CodegraphSession("/tmp/ws")
    # No thread yet → needs (re)start.
    assert sess._needs_restart() is True

    class _LiveThread:
        def is_alive(self) -> bool:
            return True

    sess._thread = _LiveThread()  # type: ignore[assignment]
    # Alive but warmup not finished (_ready unset) → still coming up, do NOT restart.
    sess._ready.clear()
    assert sess._needs_restart() is False
    # Alive, warmup finished, but unhealthy → wedged → needs restart.
    sess._ready.set()
    sess._healthy = False
    assert sess._needs_restart() is True


def test_liveness_tolerates_a_single_transient_blip():
    # A single bad probe must NOT exit the worker (no full cold restart over a
    # transient GC pause / a heavy query that held the lock past the probe timeout).
    n, should_exit = CodegraphSession._record_probe(0, bad=True)
    assert (n, should_exit) == (1, False)  # 1 failure < threshold(2) → stay alive
    # A good probe immediately after clears the streak.
    n, should_exit = CodegraphSession._record_probe(n, bad=False)
    assert (n, should_exit) == (0, False)


def test_liveness_exits_after_consecutive_failures():
    # Sustained failure (a real subprocess death) fails every probe → exit once the
    # streak reaches the threshold, so /health tracks reality within ~10s.
    n, should_exit = CodegraphSession._record_probe(0, bad=True)
    assert should_exit is False
    n, should_exit = CodegraphSession._record_probe(n, bad=True)
    assert (n, should_exit) == (2, True)  # 2 consecutive → worker exits → restart


def test_reap_orphan_servers_kills_own_children(monkeypatch):
    # _reap_orphan_servers must SIGKILL codegraph-server children of THIS pid found
    # by pgrep, and never raise. Mock pgrep output + os.kill.
    import codegraph_session as cs

    killed = []
    sess = cs.CodegraphSession("/data/repo/ws")
    monkeypatch.setattr(cs.subprocess, "run", lambda *a, **k: type("O", (), {"stdout": "12345\n67890\n", "returncode": 0})())
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    assert sess._reap_orphan_servers() is True  # queries ran + kills ok → verified
    assert (12345, cs.signal.SIGKILL) in killed
    assert (67890, cs.signal.SIGKILL) in killed


def test_reap_orphan_servers_catches_reparented_orphan_by_workspace(monkeypatch):
    # C1 regression: a codegraph-server reparented to init (PPID=1) is NOT a child of
    # this pid, so `pgrep -P self` misses it — but the workspace-cmdline query MUST
    # catch it, or it becomes a silent 2nd writer → graph.db corruption.
    import codegraph_session as cs

    killed = []
    sess = cs.CodegraphSession("/data/repo/ws")

    def fake_run(cmd, **k):
        # `-P self` query → no children (rc=1); workspace query → the reparented orphan 4242 (rc=0).
        if "-P" in cmd:
            return type("O", (), {"stdout": "", "returncode": 1})()
        return type("O", (), {"stdout": "4242\n", "returncode": 0})()

    monkeypatch.setattr(cs.subprocess, "run", fake_run)
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    assert sess._reap_orphan_servers() is True
    assert (4242, cs.signal.SIGKILL) in killed  # caught despite not being a child


def test_reap_orphan_workspace_regex_is_escaped(monkeypatch):
    # The workspace path is interpolated into a pgrep -f REGEX; a metachar in it must
    # be escaped so it can't broaden the match to a sibling workspace. Verify the
    # pattern passed to pgrep is the literal (escaped) path, not a live regex.
    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/code-5x+beta")  # '+' is a regex metachar
    seen_patterns = []

    def fake_run(cmd, **k):
        seen_patterns.append(cmd[-1])
        return type("O", (), {"stdout": "", "returncode": 1})()

    monkeypatch.setattr(cs.subprocess, "run", fake_run)
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: None)
    sess._reap_orphan_servers()
    ws_query = [p for p in seen_patterns if "--workspace" in p][0]
    assert r"\+beta" in ws_query  # '+' escaped (re.escape), not left as a regex quantifier
    assert "code-5x+beta" not in ws_query  # the raw unescaped path must NOT appear


def test_reap_orphan_never_targets_self(monkeypatch):
    # The workspace regex could match this very python process's cmdline; must never
    # SIGKILL os.getpid().
    import codegraph_session as cs

    killed = []
    sess = cs.CodegraphSession("/data/repo/ws")
    monkeypatch.setattr(cs.subprocess, "run",
                        lambda *a, **k: type("O", (), {"stdout": "%d\n" % cs.os.getpid(), "returncode": 0})())
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    sess._reap_orphan_servers()
    assert killed == []  # self excluded


def test_reap_orphan_servers_never_raises(monkeypatch):
    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/ws")

    # pgrep itself blowing up must be swallowed (best-effort) AND report UNVERIFIED:
    # if no query could run, we never looked, so we can't claim "no orphan survives".
    monkeypatch.setattr(cs.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(OSError("pgrep missing")))
    assert sess._reap_orphan_servers() is False  # must not raise, and is UNVERIFIED

    # An already-gone pid (ProcessLookupError) is the normal case, also swallowed —
    # and counts as VERIFIED (the orphan we found is confirmed gone).
    def _gone(pid, sig):
        raise ProcessLookupError()

    monkeypatch.setattr(cs.subprocess, "run", lambda *a, **k: type("O", (), {"stdout": "999999\n", "returncode": 0})())
    monkeypatch.setattr(cs.os, "kill", _gone)
    assert sess._reap_orphan_servers() is True  # must not raise; found-but-already-dead = verified


def test_reap_orphan_unverified_when_pgrep_errors(monkeypatch):
    # A pgrep that returns a REAL error code (≥2, e.g. bad usage) is NOT a valid
    # "no match" result — the orphan set is unverified, so the reaper must report
    # False so _restart refuses to spawn a possible second writer. (cross-review HIGH)
    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/ws")
    monkeypatch.setattr(cs.subprocess, "run",
                        lambda *a, **k: type("O", (), {"stdout": "", "returncode": 2})())
    monkeypatch.setattr(cs.os, "kill", lambda pid, sig: None)
    assert sess._reap_orphan_servers() is False  # rc≥2 on every query → unverified


def test_reap_orphan_unverified_when_kill_fails(monkeypatch):
    # We FOUND an orphan but os.kill failed for a non-ProcessLookupError reason
    # (e.g. EPERM): we can't prove the second writer is gone → unverified.
    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/ws")
    monkeypatch.setattr(cs.subprocess, "run",
                        lambda *a, **k: type("O", (), {"stdout": "31337\n", "returncode": 0})())

    def _eperm(pid, sig):
        raise PermissionError("operation not permitted")

    monkeypatch.setattr(cs.os, "kill", _eperm)
    assert sess._reap_orphan_servers() is False  # found-but-unkillable → unverified


def test_acquire_restart_lock_is_cooperative_not_executor_bound():
    # F1 regression: _acquire_restart_lock must NOT submit a blocking acquire() to the
    # default executor (that parked one pool thread per waiter → a restart storm
    # exhausted the pool → the holder's own join/reap couldn't get a thread → whole-
    # bridge deadlock). It now polls a non-blocking try-acquire with asyncio.sleep, so
    # a contended acquire must SUCCEED on a loop whose default executor has ZERO
    # threads available — proving it never depends on the executor.
    import asyncio
    from concurrent.futures import ThreadPoolExecutor

    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/ws")

    async def scenario() -> bool:
        loop = asyncio.get_running_loop()
        # Saturate the loop's executor: 1 worker, permanently occupied. If
        # _acquire_restart_lock used run_in_executor(acquire), it would hang here.
        pool = ThreadPoolExecutor(max_workers=1)
        loop.set_default_executor(pool)
        blocker = threading.Event()
        loop.run_in_executor(pool, blocker.wait)  # occupies the sole pool thread
        await asyncio.sleep(0)  # let it get scheduled
        # The restart lock starts free → must acquire promptly despite no free thread.
        await asyncio.wait_for(sess._acquire_restart_lock(), timeout=2.0)
        held = sess._restart_lock.locked()
        sess._restart_lock.release()
        blocker.set()
        pool.shutdown(wait=False)
        return held

    assert asyncio.run(scenario()) is True


def test_acquire_restart_lock_waits_for_a_held_lock():
    # The non-blocking poll must still SERIALIZE: while the lock is held, a second
    # acquire must block (cooperatively) until release — preserving the single-writer
    # restart mutual-exclusion the lock exists for.
    import asyncio

    import codegraph_session as cs

    sess = cs.CodegraphSession("/data/repo/ws")

    async def scenario() -> tuple[bool, bool]:
        sess._restart_lock.acquire()  # pre-hold it
        # A waiter must NOT acquire within a short window while it's held.
        timed_out = False
        try:
            await asyncio.wait_for(sess._acquire_restart_lock(), timeout=0.3)
        except asyncio.TimeoutError:
            timed_out = True
        # Release, then the next acquire succeeds.
        sess._restart_lock.release()
        await asyncio.wait_for(sess._acquire_restart_lock(), timeout=1.0)
        got_after_release = sess._restart_lock.locked()
        sess._restart_lock.release()
        return timed_out, got_after_release

    timed_out, got_after_release = asyncio.run(scenario())
    assert timed_out is True            # blocked while held
    assert got_after_release is True    # acquired once free
