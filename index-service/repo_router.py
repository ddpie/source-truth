"""Server-side repo routing + scope enforcement (multi-repo-isolation 不变量1 / 阶段3 core).

The hard security invariant: a project's bridge serves ONLY that project's repos, and the
agent's `repo` argument can NEVER reach a repo outside the bridge's scope — not by a prompt
injection, not by a cold-start tool leak, not by a typo. Enforcement is SERVER-SIDE and
WHITELIST DEFAULT-DENY: the bridge is started with an explicit set of in-scope repos, and any
`repo` not in that set is rejected (the bridge returns an error; the call never routes).

This module is the PURE decision core (no I/O, no codegraph) so it's testable in isolation and
the security-critical logic doesn't live tangled in the resident serving path. The bridge wires
it in: it builds a RepoRouter from its `--workspace` set, and every tool call passes the agent's
`repo` arg through `resolve()` before touching any session.

Backward-compatible single-repo: a router with ONE repo and a request with `repo` unset routes
to that sole repo (today's behavior). `repo` set but out-of-scope is ALWAYS rejected, even
single-repo.
"""
from __future__ import annotations

import re

# Same charset as the manifest subdir whitelist (render_manifest.py): the repo name is a path
# segment / unit-name token, so it must be a tight alnum-with-interior-dash. Anchored \A…\Z (NOT
# ^…$, whose $ matches before a trailing newline — the manifest cross-review CRITICAL).
REPO_NAME_RE = re.compile(r"\A[a-z0-9][a-z0-9-]*\Z")


class RepoOutOfScope(ValueError):
    """The requested repo is not in this bridge's in-scope set (server-side reject).
    Subclasses ValueError so the bridge's existing per-query ValueError handler turns it into a
    clean 'no such repo' result rather than a generic failure."""


class RepoRouter:
    """Resolve an agent-supplied `repo` to an in-scope repo name, or fail closed.

    `repos` is the bridge's authoritative in-scope set (from its --workspace list). It is
    validated at construction (fail-loud) — a malformed scope is an operator/deploy error, not a
    request-time surprise.
    """

    def __init__(self, repos):
        cleaned = []
        seen = set()
        for r in repos:
            if not isinstance(r, str) or not REPO_NAME_RE.match(r):
                raise ValueError(f"RepoRouter: invalid repo name in scope: {r!r} (must match {REPO_NAME_RE.pattern})")
            if r in seen:
                raise ValueError(f"RepoRouter: duplicate repo in scope: {r!r}")
            seen.add(r)
            cleaned.append(r)
        if not cleaned:
            raise ValueError("RepoRouter: scope must contain at least one repo")
        self._repos = tuple(cleaned)
        self._set = frozenset(cleaned)

    @property
    def repos(self):
        return self._repos

    def is_in_scope(self, repo: str) -> bool:
        return isinstance(repo, str) and repo in self._set

    def resolve(self, repo):
        """Map an agent-supplied `repo` to an in-scope repo name.

        - repo None/empty AND exactly one repo in scope → that sole repo (single-repo / no-arg
          default — today's behavior).
        - repo None/empty AND multiple repos in scope → None (caller fans out across all repos;
          NOT an error — "search everywhere" is a valid request).
        - repo given AND in scope → that repo.
        - repo given AND out of scope (or malformed) → RAISE RepoOutOfScope (server-side reject;
          NEVER fall back to another repo — that's the cross-project leak this exists to stop).
        """
        if repo is None or (isinstance(repo, str) and not repo.strip()):
            return self._repos[0] if len(self._repos) == 1 else None
        if not isinstance(repo, str):
            raise RepoOutOfScope(f"repo must be a string, got {type(repo).__name__}")
        if repo not in self._set:
            # Do NOT echo the requested name verbatim into a user-facing path, but it's safe in
            # an error detail (it's the agent's own arg). List the valid scope to aid the agent.
            raise RepoOutOfScope(f"repo {repo!r} is not in this project's scope {list(self._repos)}")
        return repo
