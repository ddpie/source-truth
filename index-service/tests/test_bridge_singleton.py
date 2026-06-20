"""Single-writer hard-guard test (cross-review H1).

The bridge must take a process-lifetime exclusive flock keyed to the workspace
BEFORE spawning the codegraph-server writer, so a second bridge for the same
workspace (a future --workers N / gunicorn fork) dies loudly instead of becoming
a concurrent graph.db writer. This tests the flock contract directly (no
codegraph-server binary needed)."""

from __future__ import annotations

import fcntl
import sys
import tempfile
from pathlib import Path

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))


def test_workspace_lock_refuses_second_holder():
    ws = tempfile.mkdtemp() + "/repo"
    lock_path = ws.rstrip("/") + ".bridge.lock"

    fd1 = open(lock_path, "w")  # noqa: SIM115
    fcntl.flock(fd1, fcntl.LOCK_EX | fcntl.LOCK_NB)  # first bridge acquires

    fd2 = open(lock_path, "w")  # noqa: SIM115 - a forked worker's fresh open
    refused = False
    try:
        fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        refused = True
    assert refused, "second bridge for the same workspace MUST be refused (single-writer)"

    # After the first releases (process exit), the lock is reusable.
    fcntl.flock(fd1, fcntl.LOCK_UN)
    fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)  # must not raise now
    fd1.close()
    fd2.close()


def test_different_workspaces_do_not_collide():
    # Two bridges serving DIFFERENT repos on the same host must both start.
    a = tempfile.mkdtemp() + "/repoA"
    b = tempfile.mkdtemp() + "/repoB"
    fda = open(a.rstrip("/") + ".bridge.lock", "w")  # noqa: SIM115
    fdb = open(b.rstrip("/") + ".bridge.lock", "w")  # noqa: SIM115
    fcntl.flock(fda, fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(fdb, fcntl.LOCK_EX | fcntl.LOCK_NB)  # different key → no conflict
    fda.close()
    fdb.close()


def test_acquire_singleton_writer_lock_is_idempotent_in_process():
    # acquire_singleton_writer_lock() is called from BOTH main() and build_bridge()
    # (so an app-factory launch is guarded too). A second call IN THE SAME PROCESS
    # must be a no-op (not raise / not re-open), since this process already owns it.
    import http_bridge

    saved = http_bridge._SINGLETON_FD
    http_bridge._SINGLETON_FD = None
    try:
        ws = tempfile.mkdtemp() + "/repo"
        http_bridge.acquire_singleton_writer_lock(ws)
        fd_after_first = http_bridge._SINGLETON_FD
        assert fd_after_first is not None, "first call must acquire the lock"
        # Second call (e.g. build_bridge after main already took it) — no-op, same fd.
        http_bridge.acquire_singleton_writer_lock(ws)
        assert http_bridge._SINGLETON_FD is fd_after_first, "re-acquire in-process must keep the same fd"
    finally:
        if http_bridge._SINGLETON_FD is not None and http_bridge._SINGLETON_FD is not saved:
            http_bridge._SINGLETON_FD.close()
        http_bridge._SINGLETON_FD = saved


def test_acquire_singleton_writer_lock_raises_on_foreign_holder():
    # When ANOTHER holder (simulated by a pre-held fd on the same path) owns the lock,
    # acquire_singleton_writer_lock must raise SingleWriterConflict — never silently
    # become a second writer.
    import http_bridge

    saved = http_bridge._SINGLETON_FD
    http_bridge._SINGLETON_FD = None
    ws = tempfile.mkdtemp() + "/repo"
    foreign = open(ws.rstrip("/") + ".bridge.lock", "w")  # noqa: SIM115 - stands in for another process
    fcntl.flock(foreign, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        raised = False
        try:
            http_bridge.acquire_singleton_writer_lock(ws)
        except http_bridge.SingleWriterConflict:
            raised = True
        assert raised, "must refuse when another holder owns the workspace lock"
        assert http_bridge._SINGLETON_FD is None, "a refused acquire must not set the module fd"
    finally:
        fcntl.flock(foreign, fcntl.LOCK_UN)
        foreign.close()
        http_bridge._SINGLETON_FD = saved
