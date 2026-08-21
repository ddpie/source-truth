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

import http_bridge  # noqa: E402  (requires the sys.path insert above)


def test_workspace_lock_refuses_second_holder():
    """A second process taking the SAME workspace must be refused by the PRODUCT function.

    This previously called fcntl.flock directly and therefore asserted that the Linux kernel
    implements advisory locks — deleting acquire_singleton_writer_lock left it passing. The
    single-writer guard is what the entire no-corruption invariant rests on, so it has to be the
    thing under test.
    """
    import subprocess

    ws = tempfile.mkdtemp() + "/repo"
    Path(ws).mkdir(parents=True, exist_ok=True)

    # Hold the lock in THIS process via the product API.
    http_bridge.acquire_singleton_writer_lock(ws)

    # A genuinely separate process must be refused. Same interpreter, same function.
    code = (
        "import sys; sys.path.insert(0, %r)\n"
        "import http_bridge\n"
        "try:\n"
        "    http_bridge.acquire_singleton_writer_lock(%r)\n"
        "except BaseException as e:\n"
        "    print(type(e).__name__); sys.exit(0)\n"
        "print('ACQUIRED'); sys.exit(1)\n"
    ) % (str(SVC_DIR), ws)
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, (
        "a second process acquired the SAME workspace lock — single-writer is not enforced: "
        f"stdout={r.stdout!r} stderr={r.stderr[-400:]!r}"
    )
    assert "ACQUIRED" not in r.stdout



def test_different_workspaces_do_not_collide():
    """Two bridges serving DIFFERENT repos on one host must both start.

    Also previously a bare fcntl.flock exercise. Driving the product function is what makes this
    assert the lock is keyed PER WORKSPACE rather than process-wide — the property that lets one
    host serve several projects at all.
    """
    a = tempfile.mkdtemp() + "/repoA"
    b = tempfile.mkdtemp() + "/repoB"
    Path(a).mkdir(parents=True, exist_ok=True)
    Path(b).mkdir(parents=True, exist_ok=True)
    http_bridge.acquire_singleton_writer_lock(a)
    http_bridge.acquire_singleton_writer_lock(b)  # different key → must not raise


def _reset_locks(http_bridge):
    """Snapshot + clear the module lock state for an isolated test, returning a restorer."""
    saved_fds = dict(http_bridge._WRITER_LOCK_FDS)
    http_bridge._WRITER_LOCK_FDS.clear()

    def restore():
        # Close only fds WE acquired in the test (not the pre-existing ones).
        for k, fd in list(http_bridge._WRITER_LOCK_FDS.items()):
            if k not in saved_fds:
                try:
                    fd.close()
                except Exception:  # noqa: BLE001
                    pass
        http_bridge._WRITER_LOCK_FDS.clear()
        http_bridge._WRITER_LOCK_FDS.update(saved_fds)

    return restore


def test_acquire_singleton_writer_lock_is_idempotent_in_process():
    # acquire_singleton_writer_lock() is called from BOTH main() and build_bridge()
    # (so an app-factory launch is guarded too). A second call IN THE SAME PROCESS
    # for the SAME workspace must be a no-op (not raise / not re-open).
    import http_bridge

    restore = _reset_locks(http_bridge)
    try:
        ws = tempfile.mkdtemp() + "/repo"
        http_bridge.acquire_singleton_writer_lock(ws)
        fd_after_first = http_bridge._WRITER_LOCK_FDS[ws.rstrip("/")]
        assert fd_after_first is not None, "first call must acquire the lock"
        # Second call (e.g. build_bridge after main already took it) — no-op, same fd.
        http_bridge.acquire_singleton_writer_lock(ws)
        assert http_bridge._WRITER_LOCK_FDS[ws.rstrip("/")] is fd_after_first, "re-acquire in-process must keep the same fd"
    finally:
        restore()


def test_acquire_takes_distinct_locks_per_workspace_in_one_process():
    # MULTI-REPO REGRESSION: a single process serving N workspaces must take N DISTINCT
    # flocks. The old single-fd early-return locked workspace A then SILENTLY skipped B —
    # leaving repo B's graph.db unguarded against a concurrent writer. Assert both keys
    # are held and the fds differ.
    import http_bridge

    restore = _reset_locks(http_bridge)
    try:
        a = tempfile.mkdtemp() + "/repoA"
        b = tempfile.mkdtemp() + "/repoB"
        http_bridge.acquire_singleton_writer_lock(a)
        http_bridge.acquire_singleton_writer_lock(b)
        ka, kb = a.rstrip("/"), b.rstrip("/")
        assert ka in http_bridge._WRITER_LOCK_FDS, "workspace A lock missing"
        assert kb in http_bridge._WRITER_LOCK_FDS, "workspace B lock missing (the silent-skip bug)"
        assert http_bridge._WRITER_LOCK_FDS[ka] is not http_bridge._WRITER_LOCK_FDS[kb], "each workspace needs its OWN fd"
        # Each lock file must actually be flocked: a foreign re-open must be refused.
        for k in (ka, kb):
            foreign = open(k + ".bridge.lock", "w")  # noqa: SIM115
            refused = False
            try:
                fcntl.flock(foreign, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, BlockingIOError):
                refused = True
            foreign.close()
            assert refused, f"workspace {k} lock not actually held"
    finally:
        restore()


def test_acquire_singleton_writer_lock_raises_on_foreign_holder():
    # When ANOTHER holder (simulated by a pre-held fd on the same path) owns the lock,
    # acquire_singleton_writer_lock must raise SingleWriterConflict — never silently
    # become a second writer.
    import http_bridge

    restore = _reset_locks(http_bridge)
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
        assert ws.rstrip("/") not in http_bridge._WRITER_LOCK_FDS, "a refused acquire must not register the fd"
    finally:
        fcntl.flock(foreign, fcntl.LOCK_UN)
        foreign.close()
        restore()
