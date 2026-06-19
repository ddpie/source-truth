"""The single-writer tripwire: codegraph_client must REFUSE to spawn (a graph.db
writer) unless explicitly opted in, so it can never be revived onto the resident
serving path → 2nd writer → corruption. No codegraph-server binary needed."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))
pytest.importorskip("mcp")
import codegraph_client  # noqa: E402


def test_spawn_refused_without_optin(monkeypatch):
    monkeypatch.delenv("CODEGRAPH_ALLOW_PERCALL_SPAWN", raising=False)
    with pytest.raises(RuntimeError, match="2nd writer|graph.db corruption|resident serving"):
        codegraph_client._server_params("/data/repo/x", graph_only=True)


def test_spawn_allowed_with_optin(monkeypatch):
    monkeypatch.setenv("CODEGRAPH_ALLOW_PERCALL_SPAWN", "1")
    p = codegraph_client._server_params("/data/repo/x", graph_only=True)
    assert p.command == "codegraph-server"
    assert "--workspace" in p.args
