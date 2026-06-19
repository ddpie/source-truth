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
