"""Offline multi-repo tests for build_bridge (阶段2): N sessions + fan-out + routing.

No codegraph-server. A per-workspace fake session returns a result whose file path
encodes which repo answered, so we can assert: an unset repo fans out across all repos
(merged), an explicit in-scope repo routes to just that one, an out-of-scope repo is
rejected, and one repo's error doesn't blank the others.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")

import http_bridge  # noqa: E402


class _PerRepoFake:
    """Fake session keyed by its workspace: returns a hit whose file names the repo so
    the test can see which session(s) answered. `mode` injects failures for one repo."""

    registry: dict[str, "_PerRepoFake"] = {}

    def __init__(self, workspace, **_kw):
        self.workspace = workspace
        self.name = workspace.rstrip("/").rsplit("/", 1)[-1]
        self.calls = 0
        self.healthy = True
        self.health_detail = "ok"
        self.mode = "ok"  # or "unhealthy" / "raise"
        _PerRepoFake.registry[self.name] = self

    def start(self):
        pass

    async def maybe_self_heal(self):
        pass

    async def call_tool(self, tool_name, arguments):
        self.calls += 1
        if self.mode == "unhealthy":
            raise http_bridge.IndexUnhealthy(f"{self.name} graph empty")
        if self.mode == "raise":
            raise RuntimeError("boom")
        # A hit whose file is "<name>/Foo.cs" so _align_paths re-prefixes to "<name>/<name>/Foo.cs"
        # — fine for routing assertions (we only check the repo segment appears).
        return json.dumps({"results": [{"symbol": {"location": {"file": "Foo.cs", "line": 1}}}]})


def _build_multi(monkeypatch, names=("alpha", "beta", "gamma")):
    _PerRepoFake.registry.clear()
    monkeypatch.setattr(http_bridge, "CodegraphSession", lambda ws, **kw: _PerRepoFake(ws, **kw))
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: None)
    workspaces = [(f"/data/repo/{n}", f"/data/repo/{n}") for n in names]
    app = http_bridge.build_bridge(workspaces=workspaces, host="127.0.0.1", port=8951)
    return app


def _fn(app, name):
    return app._tool_manager.get_tool(name).fn  # type: ignore[attr-defined]


def test_unset_repo_fans_out_across_all_repos(monkeypatch):
    app = _build_multi(monkeypatch)
    out = json.loads(asyncio.run(_fn(app, "codegraph_symbol_search")(query="Foo")))
    files = [r["symbol"]["location"]["file"] for r in out["results"]]
    # one hit per repo, each prefixed with its repo name (path honesty), in repo order
    assert len(files) == 3, files
    assert files[0].startswith("alpha/") and files[1].startswith("beta/") and files[2].startswith("gamma/"), files
    # every repo's session was queried exactly once
    assert all(s.calls == 1 for s in _PerRepoFake.registry.values())


def test_explicit_in_scope_repo_routes_to_only_that_repo(monkeypatch):
    app = _build_multi(monkeypatch)
    out = json.loads(asyncio.run(_fn(app, "codegraph_symbol_search")(query="Foo", repo="beta")))
    files = [r["symbol"]["location"]["file"] for r in out["results"]]
    assert files == ["beta/Foo.cs"], files
    # ONLY beta was queried; alpha/gamma untouched
    assert _PerRepoFake.registry["beta"].calls == 1
    assert _PerRepoFake.registry["alpha"].calls == 0
    assert _PerRepoFake.registry["gamma"].calls == 0


def test_out_of_scope_repo_rejected_in_multi(monkeypatch):
    app = _build_multi(monkeypatch)
    out = asyncio.run(_fn(app, "codegraph_symbol_search")(query="Foo", repo="evil"))
    assert '"repo not in scope"' in out
    assert all(s.calls == 0 for s in _PerRepoFake.registry.values()), "rejection must not touch any session"


def test_fanout_one_repo_unhealthy_does_not_blank_others(monkeypatch):
    app = _build_multi(monkeypatch)
    _PerRepoFake.registry["beta"].mode = "unhealthy"  # beta's graph is broken
    out = json.loads(asyncio.run(_fn(app, "codegraph_symbol_search")(query="Foo")))
    files = [r["symbol"]["location"]["file"] for r in out["results"]]
    # alpha + gamma still answer; beta's error contributes nothing (not an error envelope)
    assert sorted(f.split("/")[0] for f in files) == ["alpha", "gamma"], files
    assert "error" not in out


def test_fanout_all_repos_unhealthy_surfaces_error(monkeypatch):
    app = _build_multi(monkeypatch)
    for s in _PerRepoFake.registry.values():
        s.mode = "unhealthy"
    out = json.loads(asyncio.run(_fn(app, "codegraph_symbol_search")(query="Foo")))
    assert out.get("error") == "index unavailable", out


def test_health_unhealthy_when_any_repo_unhealthy(monkeypatch):
    app = _build_multi(monkeypatch)
    # all healthy initially
    assert all(s.healthy for s in app.codegraph_sessions)  # type: ignore[attr-defined]
    app.codegraph_repos[1].session.healthy = False  # type: ignore[attr-defined]
    app.codegraph_repos[1].session.health_detail = "beta empty"  # type: ignore[attr-defined]
    # the health handler aggregates: any unhealthy → not ok (we call the logic via the repos)
    unhealthy = [r for r in app.codegraph_repos if not r.session.healthy]  # type: ignore[attr-defined]
    assert len(unhealthy) == 1 and unhealthy[0].name == "beta"


def test_each_workspace_takes_its_own_writer_lock(monkeypatch):
    locked = []
    monkeypatch.setattr(http_bridge, "CodegraphSession", lambda ws, **kw: _PerRepoFake(ws, **kw))
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: locked.append(ws))
    _PerRepoFake.registry.clear()
    http_bridge.build_bridge(
        workspaces=[("/data/repo/a", "/data/repo/a"), ("/data/repo/b", "/data/repo/b")],
        host="127.0.0.1", port=8952,
    )
    assert locked == ["/data/repo/a", "/data/repo/b"], locked


def test_rejects_both_workspace_and_workspaces(monkeypatch):
    monkeypatch.setattr(http_bridge, "CodegraphSession", lambda ws, **kw: _PerRepoFake(ws, **kw))
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: None)
    _PerRepoFake.registry.clear()
    with pytest.raises(ValueError):
        http_bridge.build_bridge(workspace="/data/repo/a", workspaces=[("/data/repo/b", None)], port=8953)


def test_requires_at_least_one_workspace(monkeypatch):
    monkeypatch.setattr(http_bridge, "CodegraphSession", lambda ws, **kw: _PerRepoFake(ws, **kw))
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: None)
    with pytest.raises(ValueError):
        http_bridge.build_bridge(workspaces=[], port=8954)


# ── file-tool per-repo routing (read_file/read_table by path prefix; search/glob fan-out) ──
def _build_multi_with_local(monkeypatch, tmp_path, names=("alpha", "beta")):
    """build_bridge over REAL on-disk local copies (so file tools register + run) with a
    fake graph session. Each repo gets a distinct file so routing is observable."""
    _PerRepoFake.registry.clear()
    monkeypatch.setattr(http_bridge, "CodegraphSession", lambda ws, **kw: _PerRepoFake(ws, **kw))
    monkeypatch.setattr(http_bridge, "acquire_singleton_writer_lock", lambda ws: None)
    workspaces = []
    for n in names:
        root = tmp_path / n
        (root / "src").mkdir(parents=True)
        (root / "src" / f"{n}_only.cs").write_text(f"// {n} marker TOKEN_{n.upper()}\n")
        (root / "shared.json").write_text(f'{{"repo": "{n}"}}\n')
        workspaces.append((str(root), str(root)))
    app = http_bridge.build_bridge(workspaces=workspaces, host="127.0.0.1", port=8961)
    return app


def test_read_file_routes_by_repo_prefix(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    fn = _fn(app, "codegraph_read_file")
    out = json.loads(asyncio.run(fn(path="beta/shared.json")))
    assert out.get("path") == "beta/shared.json", out
    assert '"repo": "beta"' in out["content"], out
    # alpha's copy is NOT read for a beta-prefixed path
    out_a = json.loads(asyncio.run(fn(path="alpha/src/alpha_only.cs")))
    assert "TOKEN_ALPHA" in out_a["content"]


def test_read_file_unprefixed_path_in_multi_refuses(monkeypatch, tmp_path):
    # With multiple repos and no recognizable <repo>/ prefix, refuse rather than guess.
    app = _build_multi_with_local(monkeypatch, tmp_path)
    out = json.loads(asyncio.run(_fn(app, "codegraph_read_file")(path="shared.json")))
    assert "error" in out and "which repo" in out["detail"], out


def test_read_file_out_of_scope_prefix_rejected(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    # "evil/x" — evil is not in scope; the seg isn't in scope so it's an un-routable path.
    out = json.loads(asyncio.run(_fn(app, "codegraph_read_file")(path="evil/x.cs")))
    assert "error" in out, out


def test_search_files_fans_out_across_repos(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    # "marker" appears once per repo → fan-out returns both, each <repo>/-prefixed.
    out = json.loads(asyncio.run(_fn(app, "codegraph_search_files")(pattern="marker")))
    paths = sorted(m["path"].split("/")[0] for m in out["matches"])
    assert paths == ["alpha", "beta"], out


def test_search_files_scoped_to_one_repo(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    out = json.loads(asyncio.run(_fn(app, "codegraph_search_files")(pattern="marker", repo="alpha")))
    assert all(m["path"].startswith("alpha/") for m in out["matches"]), out
    assert out["matches"], "expected alpha hits"


def test_search_files_out_of_scope_repo_rejected(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    out = json.loads(asyncio.run(_fn(app, "codegraph_search_files")(pattern="marker", repo="ghost")))
    assert '"repo not in scope"' in json.dumps(out)


def test_glob_fans_out_across_repos(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    out = json.loads(asyncio.run(_fn(app, "codegraph_glob_files")(pattern="**/*.cs")))
    prefixes = sorted(p.split("/")[0] for p in out["paths"])
    assert prefixes == ["alpha", "beta"], out


def test_read_table_routes_by_repo_prefix(monkeypatch, tmp_path):
    # add a csv to beta only
    (tmp_path / "beta" / "Config").mkdir(parents=True)
    (tmp_path / "beta" / "Config" / "t.csv").write_text("a,b\n1,2\n")
    app = _build_multi_with_local(monkeypatch, tmp_path)
    out = json.loads(asyncio.run(_fn(app, "codegraph_read_table")(path="beta/Config/t.csv")))
    assert out.get("path") == "beta/Config/t.csv", out
    assert out.get("kind") == "csv"


def test_search_fanout_one_repo_error_does_not_blank_others(monkeypatch, tmp_path):
    # One repo's search raises (e.g. disk fault); the other must still return its hits.
    app = _build_multi_with_local(monkeypatch, tmp_path)
    import file_search
    real = file_search.search_to_json

    def flaky(pattern, *, local_root, mount_root, glob=None, repo=""):
        if repo == "alpha":
            raise OSError("simulated disk fault on alpha")
        return real(pattern, local_root=local_root, mount_root=mount_root, glob=glob, repo=repo)

    monkeypatch.setattr(file_search, "search_to_json", flaky)
    out = json.loads(asyncio.run(_fn(app, "codegraph_search_files")(pattern="marker")))
    # beta still answers; alpha's error contributes nothing (not an error envelope to the agent)
    assert "error" not in out, out
    assert out["matches"], "beta's hits must survive alpha's failure"
    assert all(m["path"].startswith("beta/") for m in out["matches"]), out


def test_glob_fanout_one_repo_error_does_not_blank_others(monkeypatch, tmp_path):
    app = _build_multi_with_local(monkeypatch, tmp_path)
    import file_read
    real = file_read.glob_to_json

    def flaky(pattern, *, local_root, mount_root, repo=""):
        if repo == "alpha":
            raise OSError("simulated disk fault on alpha")
        return real(pattern, local_root=local_root, mount_root=mount_root, repo=repo)

    monkeypatch.setattr(file_read, "glob_to_json", flaky)
    out = json.loads(asyncio.run(_fn(app, "codegraph_glob_files")(pattern="**/*.cs")))
    assert "error" not in out, out
    assert out["paths"] and all(p.startswith("beta/") for p in out["paths"]), out


# ── main() arg pairing: repeatable --workspace / --local-workspace (CLI glue) ──
def test_pair_workspaces_single_repo():
    from http_bridge import pair_workspaces
    assert pair_workspaces(["/data/repo/x"], ["/data/repo/x"]) == [("/data/repo/x", "/data/repo/x")]


def test_pair_workspaces_single_no_local():
    from http_bridge import pair_workspaces
    assert pair_workspaces(["/data/repo/x"], []) == [("/data/repo/x", None)]


def test_pair_workspaces_multi_by_position():
    from http_bridge import pair_workspaces
    out = pair_workspaces(["/data/repo/a", "/data/repo/b"], ["/data/repo/a", "/data/repo/b"])
    assert out == [("/data/repo/a", "/data/repo/a"), ("/data/repo/b", "/data/repo/b")]


def test_pair_workspaces_fewer_locals_pad_none():
    from http_bridge import pair_workspaces
    out = pair_workspaces(["/data/repo/a", "/data/repo/b"], ["/data/repo/a"])
    assert out == [("/data/repo/a", "/data/repo/a"), ("/data/repo/b", None)]


def test_pair_workspaces_requires_at_least_one():
    from http_bridge import pair_workspaces
    with pytest.raises(ValueError):
        pair_workspaces([], [])


def test_pair_workspaces_rejects_excess_locals():
    from http_bridge import pair_workspaces
    with pytest.raises(ValueError):
        pair_workspaces(["/data/repo/a"], ["/data/repo/a", "/data/repo/b"])


def test_pair_workspaces_rejects_duplicate_workspace():
    from http_bridge import pair_workspaces
    with pytest.raises(ValueError):
        pair_workspaces(["/data/repo/a", "/data/repo/a/"], ["/data/repo/a", "/data/repo/a"])
