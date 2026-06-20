"""Unit tests for repo_router.RepoRouter — server-side repo scope enforcement.

The security invariant under test (multi-repo 不变量1 / 阶段3): an out-of-scope `repo` is
ALWAYS rejected and NEVER falls back to another repo. Pure function, no I/O.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import repo_router  # noqa: E402
from repo_router import RepoRouter, RepoOutOfScope  # noqa: E402


# ── construction / scope validation (fail-loud) ──────────────────────────────
def test_rejects_empty_scope():
    with pytest.raises(ValueError):
        RepoRouter([])


def test_rejects_malformed_repo_name_in_scope():
    for bad in ["../etc", "Code5x", "a b", "repo;rm", "a_b", "a/b", "a.bak", "-rf", "x\n"]:
        with pytest.raises(ValueError):
            RepoRouter([bad])


def test_rejects_duplicate_in_scope():
    with pytest.raises(ValueError):
        RepoRouter(["client", "client"])


def test_accepts_valid_scope():
    r = RepoRouter(["client", "backend-svc", "tools2"])
    assert r.repos == ("client", "backend-svc", "tools2")


# ── resolve: single-repo default (today's behavior) ──────────────────────────
def test_single_repo_unset_routes_to_sole_repo():
    r = RepoRouter(["code-5x"])
    assert r.resolve(None) == "code-5x"
    assert r.resolve("") == "code-5x"
    assert r.resolve("   ") == "code-5x"


def test_single_repo_explicit_in_scope():
    r = RepoRouter(["code-5x"])
    assert r.resolve("code-5x") == "code-5x"


def test_single_repo_explicit_out_of_scope_rejected():
    # even with one repo, asking for a DIFFERENT repo must reject, not fall back.
    r = RepoRouter(["code-5x"])
    with pytest.raises(RepoOutOfScope):
        r.resolve("other-repo")


# ── resolve: multi-repo ──────────────────────────────────────────────────────
def test_multi_repo_unset_returns_none_for_fanout():
    # no repo given + multiple in scope → None = "fan out across all" (a valid request, NOT an error)
    r = RepoRouter(["client", "backend-svc"])
    assert r.resolve(None) is None
    assert r.resolve("") is None


def test_multi_repo_explicit_in_scope():
    r = RepoRouter(["client", "backend-svc"])
    assert r.resolve("client") == "client"
    assert r.resolve("backend-svc") == "backend-svc"


def test_multi_repo_out_of_scope_rejected_never_falls_back():
    # THE core security case: a repo not in scope is rejected, never silently routed elsewhere.
    r = RepoRouter(["client", "backend-svc"])
    with pytest.raises(RepoOutOfScope):
        r.resolve("secret-repo")
    # a prefix of an in-scope name must NOT match (no substring/prefix leak)
    with pytest.raises(RepoOutOfScope):
        r.resolve("client-svc")   # not == "client" and not in scope
    with pytest.raises(RepoOutOfScope):
        r.resolve("clien")


def test_out_of_scope_is_a_valueerror_subclass():
    # the bridge's existing per-query `except ValueError` turns this into a clean no-match result.
    r = RepoRouter(["client"])
    try:
        r.resolve("evil")
        assert False, "should have raised"
    except ValueError:
        pass  # RepoOutOfScope is a ValueError → caught by the bridge's handler


def test_non_string_repo_rejected():
    r = RepoRouter(["client", "backend-svc"])
    for bad in (123, ["client"], {"repo": "client"}, True):
        with pytest.raises(RepoOutOfScope):
            r.resolve(bad)


def test_is_in_scope():
    r = RepoRouter(["client", "backend-svc"])
    assert r.is_in_scope("client")
    assert not r.is_in_scope("nope")
    assert not r.is_in_scope(None)
    assert not r.is_in_scope(123)


def test_repo_name_regex_end_anchored():
    # the scope-name regex must reject a trailing newline (Python ^...$ footgun) — defense in
    # depth even though construction also validates.
    assert repo_router.REPO_NAME_RE.match("code-5x")
    assert not repo_router.REPO_NAME_RE.match("code-5x\n")
    assert not repo_router.REPO_NAME_RE.match("-rf")
