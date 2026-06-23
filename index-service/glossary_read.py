"""Read functions backing the glossary_index / glossary_lookup MCP tools.

The glossary is the agent's Chinese-term -> code-symbol bridge (see glossary.py).
It lives under /data/glossary/<project>/ as one ``<subdir>.jsonl`` slice per repo (a
single-repo project has one slice) — OUTSIDE the code sandbox root /data/repo/<subdir>,
so it gets its OWN confinement here (the code file-read tools would realpath-reject a
path under /data/glossary).

Two layers, matching how the agent consumes it. NOTE: neither is auto-injected into the
agent's context — both are TOOLS the agent calls (system.md tells it to call glossary_index
early when the question uses domain wording). "Lightweight" = small enough that calling it
once is cheap, not "always in context".
  glossary_index(project)        the LIGHTWEIGHT layer the agent calls first: compact
                                 {concept_id, aliases, head symbols} rows to map the user's
                                 wording to code symbols.
  glossary_lookup(project, term) the ON-DEMAND full record for ONE concept — by concept_id
                                 OR by a Chinese/colloquial term: every symbol/alias,
                                 confidence, and source anchors (citation + verification).

ISOLATION (design §9.2): project name must match ^[a-z0-9-]+$; the sandbox root is
the per-PROJECT dir (never the /data/glossary top level — that would allow ../B into a
sibling project); every resolved path is realpath-confined under that project root, so
a symlinked slice pointing outside is refused. A missing glossary degrades to
empty (the feature is optional per project), but a path/charset violation RAISES.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

import glossary

# Default on-host location; overridable in tests / by the bridge.
# Resolved at CALL time (not bound as a default arg) so an env override / a test
# monkeypatch of this module attribute takes effect without re-importing.
DEFAULT_GLOSSARY_ROOT = os.environ.get("GLOSSARY_ROOT", "/data/glossary")
_PROJECT_RE = re.compile(r"^[a-z0-9-]+$")


def _root(glossary_root: str | None) -> str:
    """None → the current module default (re-read each call, so an override sticks)."""
    return glossary_read_root() if glossary_root is None else glossary_root


def glossary_read_root() -> str:
    return DEFAULT_GLOSSARY_ROOT


def _project_dir(project: str, glossary_root: str) -> str:
    """Resolve + confine the per-project glossary dir. Raises ValueError on a bad
    project name or any path that escapes the glossary root (lexical + realpath)."""
    if not _PROJECT_RE.match(project or ""):
        raise ValueError(f"invalid project name: {project!r}")
    root_real = os.path.realpath(glossary_root)
    proj = os.path.realpath(os.path.join(root_real, project))
    # Confinement: the resolved project dir must sit strictly UNDER the glossary root
    # (not equal to it, not a sibling). realpath collapses symlinks + .. so this also
    # blocks a symlinked subdir escaping outward.
    if proj != root_real and not proj.startswith(root_real.rstrip("/") + os.sep):
        raise ValueError(f"project path escapes glossary root: {project!r}")
    if proj == root_real:
        raise ValueError(f"project name resolves to glossary root: {project!r}")
    return proj


def _load_slices(project: str, glossary_root: str | None) -> list[tuple[str, list[glossary.Entry]]]:
    """Load a project's glossary slices, confined to the project dir, as (repo, entries) pairs.

    The generator writes ONE slice per repo (``<subdir>.jsonl``); the slice stem IS the repo
    name. We keep slices SEPARATE (not concatenated) so concept_ids can be namespaced per repo
    — two repos in one project (e.g. temporal's server/sdk-go/api) may both emit `level` meaning
    unrelated things, and blindly grouping by bare concept_id would fuse them. A legacy single
    ``entries.jsonl`` becomes one slice named ``entries``. Each slice path is realpath-confined
    (symlink-escape guard); a missing/empty dir yields []."""
    proj = _project_dir(project, _root(glossary_root))
    if not os.path.isdir(proj):
        return []
    out: list[tuple[str, list[glossary.Entry]]] = []
    for name in sorted(os.listdir(proj)):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.realpath(os.path.join(proj, name))
        if path != os.path.join(proj, name) and not path.startswith(proj.rstrip("/") + os.sep):
            raise ValueError(f"slice path escapes project dir: {name!r}")
        if os.path.isfile(path):
            try:
                entries = glossary.read_entries(path)
            except OSError:
                # An unreadable slice (I/O error) must not blank its SIBLING slices — skip it,
                # treat as empty. (Charset issues are already handled by read_entries' errors=replace;
                # a path/confinement violation above still raises, as it should.)
                entries = []
            out.append((name[: -len(".jsonl")], entries))
    return out


def glossary_index(project: str, *, glossary_root: str | None = None,
                   max_concepts: int = 200) -> dict[str, Any]:
    """Lightweight term→symbol layer the agent calls first. Returns
    {"concepts": [{concept_id, aliases, symbols, repo?}, ...]} (med+ confidence, each with at
    least one search-seed symbol) — empty if the project has no glossary yet.

    Multi-repo: each repo's slice is aggregated SEPARATELY; when the project has >1 repo the
    concept_id is namespaced ``<repo>/<id>`` and a ``repo`` field is attached, so a shared bare
    id from different repos never merges. Single-repo projects keep bare ids (unchanged)."""
    slices = _load_slices(project, glossary_root)
    multi = len(slices) > 1
    # Budget the cap ACROSS slices so one big repo (alphabetically first) can't starve the others
    # out of the index entirely — split max_concepts evenly per slice (>=1 each). Single-repo gets
    # the whole budget (unchanged). This is a fair-share cap, not a global early-return.
    per_slice = max(1, max_concepts // len(slices)) if slices else max_concepts
    concepts_out: list[dict[str, Any]] = []
    for repo, entries in slices:
        for row in glossary.to_index(glossary.aggregate(entries), max_concepts=per_slice):
            if multi:
                row = {**row, "concept_id": f"{repo}/{row['concept_id']}", "repo": repo}
            concepts_out.append(row)
    return {"concepts": concepts_out}


# A broad short term ("战", "力") can match very many concepts; cap the returned set (with a
# truncation flag) so lookup can't return a thousand-record payload (latency + downstream tokens).
MAX_LOOKUP_MATCHES = 25


def _records_for_repo(entries: list[glossary.Entry]) -> dict[str, dict[str, Any]]:
    """Aggregate a repo's entries ONCE and build the full record per concept_id, keyed by id.

    Replaces the old per-concept `_concept_record` that re-ran aggregate() over the full entry
    list for EVERY matched concept (O(matches × entries)); here aggregate runs once and anchors
    are bucketed in a single pass (O(entries)). anchors include only entries whose value survived
    aggregation's validation, deduped by (source, line)."""
    concepts = glossary.aggregate(entries)
    # bucket anchors per concept in one pass over entries
    anchors_by_cid: dict[str, list[dict[str, Any]]] = {}
    seen_by_cid: dict[str, set[tuple[str, int]]] = {}
    valid_by_cid = {cid: set(c.symbols) | set(c.aliases) for cid, c in concepts.items()}
    for e in entries:
        valid = valid_by_cid.get(e.concept_id)
        if valid is None or e.value not in valid:
            continue
        key = (e.source, e.line)
        seen = seen_by_cid.setdefault(e.concept_id, set())
        if key in seen:
            continue
        seen.add(key)
        anchors_by_cid.setdefault(e.concept_id, []).append({"source": e.source, "line": e.line})
    return {
        cid: {
            "concept_id": cid, "symbols": c.symbols, "aliases": c.aliases,
            "confidence": c.confidence, "anchors": anchors_by_cid.get(cid, []),
        }
        for cid, c in concepts.items()
    }


def glossary_lookup(project: str, query: str, *,
                    glossary_root: str | None = None) -> dict[str, Any]:
    """Full record(s) for a concept — by concept_id OR by a Chinese/colloquial term, across
    all of a project's repos.

    The agent often has the user's WORD ("战力") but not a concept_id (which it would only
    learn from glossary_index). So resolve flexibly, per repo slice:
      1. exact concept_id — accepts a namespaced ``<repo>/<id>`` (as glossary_index emits for
         multi-repo) or a bare ``<id>`` (single-repo, or any repo that has it);
      2. else case-insensitive SUBSTRING over aliases AND symbols → ALL matching concepts.
    A record carries ``repo`` when the project has >1 repo (disambiguates same-id concepts and
    same-relative-path anchors across repos). Returns a single record for one match, else
    {"matches": [...]}, else {"error": ...}. Includes low/med concepts the index omits — this
    is the on-demand layer."""
    if not query or not query.strip():
        return {"error": "empty query"}
    slices = _load_slices(project, glossary_root)
    if not slices:
        return {"error": f"no glossary for project {project!r}"}
    multi = len(slices) > 1

    def tag(rec: dict[str, Any], repo: str) -> dict[str, Any]:
        if not multi:
            return rec
        return {**rec, "concept_id": f"{repo}/{rec['concept_id']}", "repo": repo}

    # A namespaced query "<repo>/<id>" pins the repo; split it off if it matches a slice.
    pinned_repo, bare = None, query
    if "/" in query:
        head, rest = query.split("/", 1)
        if any(r == head for r, _ in slices):
            pinned_repo, bare = head, rest

    # Aggregate each relevant repo ONCE into {concept_id: record} (not per-match — kills the
    # old O(matches × entries) blowup on a broad term).
    relevant = [(r, e, _records_for_repo(e)) for r, e in slices if pinned_repo is None or r == pinned_repo]

    # 1) exact concept_id — collect from ALL relevant repos (don't early-return the first, or a
    # shared bare id in another repo would be silently hidden). An exact id is authoritative, so if
    # ANY repo has it we resolve via exact-id and skip the substring pass entirely.
    if glossary.is_valid_concept_id(bare):
        exact = [tag(recs[bare], repo) for repo, _e, recs in relevant if bare in recs]
        if exact:
            return exact[0] if len(exact) == 1 else {"matches": exact}

    # 2) term substring over aliases + symbols (case-insensitive), accumulated across repos.
    # Single pass per repo flags which concepts contain the term; bounded to MAX_LOOKUP_MATCHES.
    q = query.casefold()
    matches: list[dict[str, Any]] = []
    truncated = False
    for repo, entries, recs in relevant:
        hit_ids: list[str] = []
        seen_ids: set[str] = set()
        for e in entries:
            if e.concept_id in seen_ids or e.concept_id not in recs:
                continue
            if q in e.value.casefold():
                seen_ids.add(e.concept_id)
                hit_ids.append(e.concept_id)
        for cid in hit_ids:
            matches.append(tag(recs[cid], repo))
            if len(matches) >= MAX_LOOKUP_MATCHES:
                truncated = True
                break
        if truncated:
            break
    if not matches:
        return {"error": f"no concept matches {query!r}"}
    if len(matches) == 1:
        return matches[0]
    out: dict[str, Any] = {"matches": matches}
    if truncated:
        # Tell the agent the list was capped so it narrows the term rather than assuming these are all.
        out["truncated"] = True
        out["hint"] = f"more than {MAX_LOOKUP_MATCHES} concepts match {query!r}; narrow the term"
    return out


def index_to_json(project: str, *, glossary_root: str | None = None) -> str:
    return json.dumps(glossary_index(project, glossary_root=glossary_root), ensure_ascii=False)


def lookup_to_json(project: str, query: str, *,
                   glossary_root: str | None = None) -> str:
    return json.dumps(glossary_lookup(project, query, glossary_root=glossary_root),
                      ensure_ascii=False)
