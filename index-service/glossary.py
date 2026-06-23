"""Concept-centric term index — map Chinese/colloquial terms to English code symbols.

WHY: planners ask in Chinese ("战力", "爆率", "体力"); the code is English
(`combatPower`, `loot_chance`, `maxStamina`). Without this bridge the agent can't
turn a Chinese question into code search terms. The glossary supplies that bridge:
each concept groups the synonyms (Chinese aliases + code symbols) that mean one thing.

This module is the DATA layer: the on-disk format, aggregation, incremental update
primitives, validation, and the lightweight projection injected into the agent's
context. Generation (Agent-driven full build / diff-driven incremental) and the MCP
read tools live elsewhere; they all speak the Entry/Concept types defined here.

KEY DESIGN — concept-centric with per-source accounting:
  * An Entry is ONE (concept_id, kind, value, source-file) record. "Multiple terms,
    same concept" is just multiple Entries sharing a concept_id — no special case.
  * Every Entry remembers its SOURCE FILE. Incremental refresh re-extracts only the
    files a git-diff changed: drop_sources() removes those files' Entries, the
    generator re-extracts them, and aggregate() regroups. A concept contributed by
    several files keeps the symbols from the files that DIDN'T change — the cross-file
    correctness property that makes diff-driven updates safe.

SAFETY: `value` of a `symbol` Entry reaches the agent as a code SEARCH SEED, so it
passes a strict identifier charset whitelist. `alias` values are untrusted free text
(Chinese terms, possibly machine-extracted from comments) — kept for matching the
user's wording, but NEVER emitted as a search seed and isolated as data in context.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

# A symbol is an identifier the agent will feed to symbol_search/search_files. Allow
# letters/digits/_, plus '.' and '::' joiners for member refs (CombatPower.calc,
# Foo::bar). Anything else (spaces, shell/SQL metachars, backticks) is rejected.
_SYMBOL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|::)[A-Za-z_][A-Za-z0-9_]*)*$")
# concept_id is a slug: lowercase/digits/_/-, no separators that enable path tricks.
_CONCEPT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")

VALID_KINDS = ("symbol", "alias")
VALID_CONFIDENCE = ("high", "med", "low")

# Source files that ARE code/config — the authoritative truth. Anything else a text scan picks
# up (docs, READMEs, design notes, wiki, plain text) is a SECONDARY source: useful for harvesting
# Chinese terms, but it describes intent/plans that may diverge from code. "代码为唯一依据" is
# enforced by DEMOTING a doc-sourced entry's confidence one notch (demote_confidence below), so a
# code-sourced term always outranks a doc-sourced one for the same concept (aggregate takes the
# max), pushing doc-only terms into the on-demand lookup layer rather than the prominent index.
CODE_EXTS = (
    ".cs", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".go", ".java", ".py", ".ts", ".tsx",
    ".js", ".jsx", ".lua", ".sql", ".json", ".csv", ".tsv", ".xml", ".yaml", ".yml",
    ".toml", ".ini", ".cfg", ".conf", ".proto", ".rs", ".kt", ".rb", ".php", ".c", ".m",
)


def is_code_source(path: str) -> bool:
    """True if the source path is code/config (authoritative), False for docs/other text."""
    return (path or "").lower().endswith(CODE_EXTS)


def demote_confidence(conf: str) -> str:
    """One notch down: high→med→low→low. Applied to doc-sourced entries so code wins on conflict."""
    return {"high": "med", "med": "low"}.get(conf, "low")


def is_valid_symbol(value: str) -> bool:
    return bool(_SYMBOL_RE.match(value or ""))


def is_valid_concept_id(value: str) -> bool:
    return bool(_CONCEPT_ID_RE.match(value or ""))


@dataclass(frozen=True)
class Entry:
    """One atomic contribution to a concept, tagged with the file it came from.

    kind="symbol": `value` is a code symbol (search seed; charset-validated).
    kind="alias" : `value` is a term/phrase a user might say (free text, untrusted).
    """
    concept_id: str
    kind: str
    value: str
    source: str
    line: int = 0
    confidence: str = "high"

    def to_dict(self) -> dict[str, Any]:
        return {
            "concept_id": self.concept_id, "kind": self.kind, "value": self.value,
            "source": self.source, "line": self.line, "confidence": self.confidence,
        }

    @staticmethod
    def from_dict(d: dict[str, Any]) -> "Entry":
        # Required fields; raises KeyError/TypeError on a partial record (caller skips).
        # Clamp an unknown confidence to "low" so cc emitting a garbage value (e.g. "BOGUS")
        # can't leak into lookup output or rank oddly — an unrecognized grade is least-trusted.
        conf = str(d.get("confidence", "high"))
        if conf not in VALID_CONFIDENCE:
            conf = "low"
        return Entry(
            concept_id=str(d["concept_id"]), kind=str(d["kind"]), value=str(d["value"]),
            source=str(d["source"]), line=int(d.get("line", 0)),
            confidence=conf,
        )


@dataclass
class Concept:
    """Aggregated view of one concept: all its symbols + aliases + provenance.

    Lists preserve first-seen order and are de-duplicated. `confidence` is the
    STRONGEST confidence among the concept's contributing entries (a concept is as
    trustworthy as its best evidence; weak-only concepts stay out of the lightweight
    layer). `sources` is the set of files that contributed — provenance + the unit
    incremental update adds/removes.
    """
    concept_id: str
    symbols: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    confidence: str = "low"


def _rank(conf: str) -> int:
    return {"high": 3, "med": 2, "low": 1}.get(conf, 0)


def aggregate(entries: list[Entry]) -> dict[str, Concept]:
    """Group entries by concept_id into Concepts.

    Drops a `symbol` entry whose value fails the charset whitelist (defense-in-depth:
    a bad seed must never reach the agent), and any entry with a non-slug concept_id.
    `alias` entries are kept verbatim (free text; never used as a seed). A concept with
    no surviving entries does not appear.
    """
    out: dict[str, Concept] = {}
    for e in entries:
        if not is_valid_concept_id(e.concept_id):
            continue
        if e.kind == "symbol" and not is_valid_symbol(e.value):
            continue
        if e.kind not in VALID_KINDS:
            continue
        c = out.get(e.concept_id)
        if c is None:
            c = Concept(concept_id=e.concept_id)
            out[e.concept_id] = c
        if e.kind == "symbol" and e.value not in c.symbols:
            c.symbols.append(e.value)
        elif e.kind == "alias" and e.value not in c.aliases:
            c.aliases.append(e.value)
        if e.source not in c.sources:
            c.sources.append(e.source)
        if _rank(e.confidence) > _rank(c.confidence):
            c.confidence = e.confidence
    # A concept that contributed ONLY an invalid symbol (no surviving symbol/alias) is
    # noise — drop it so it can't appear as an empty concept.
    return {cid: c for cid, c in out.items() if c.symbols or c.aliases}


def drop_sources(entries: list[Entry], changed: set[str]) -> list[Entry]:
    """Return entries NOT sourced from any file in `changed`.

    The incremental-update primitive: before re-extracting the files a git-diff
    touched, strip their old contributions. Entries from unchanged files survive, so a
    concept spanning several files keeps the parts that didn't change.
    """
    return [e for e in entries if e.source not in changed]


def write_entries(path: str, entries: list[Entry]) -> None:
    """Persist as JSONL (one record per line) — line-oriented so an incremental
    rewrite can stream/filter without parsing a whole-file array, and diffs are clean."""
    with open(path, "w", encoding="utf-8") as fh:
        for e in entries:
            fh.write(json.dumps(e.to_dict(), ensure_ascii=False) + "\n")


def read_entries(path: str) -> list[Entry]:
    """Load JSONL entries; skip (do not raise on) a malformed/partial line — a single
    bad row from a generator hiccup must not blank the whole index. errors="replace" so a
    stray non-UTF8 byte (manual corruption / filesystem damage) degrades ONE line instead of
    raising UnicodeDecodeError mid-iteration and blanking the whole slice (we write valid UTF-8,
    so this only matters for externally-damaged files)."""
    out: list[Entry] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(Entry.from_dict(json.loads(line)))
            except (ValueError, KeyError, TypeError):
                continue
    return out


def to_index(concepts: dict[str, Concept], *, max_concepts: int = 200,
             head_symbols: int = 4, head_aliases: int = 6,
             min_confidence: str = "med") -> list[dict[str, Any]]:
    """Project concepts into the LIGHTWEIGHT layer the agent pulls (via glossary_index).

    Each row is {concept_id, aliases (head only), symbols (head only)} — enough to map a
    user's wording to code search seeds, not the full record (that's glossary_lookup).

    Inclusion rules (tuned by the review):
      * confidence >= ``min_confidence`` — default "med", NOT "high". cc tends to mark the
        Chinese aliases (the whole point of the bridge) as "med"; gating on "high" dropped
        exactly those into a dead zone (not in the index, and lookup needs an id only the
        index provides). The index is a search HINT, not an answer, so a med hint belongs
        here; the agent re-verifies in code regardless.
      * MUST have at least one symbol — an alias-only concept gives the agent no search
        seed, so it's useless in the lightweight layer (still reachable via lookup-by-term).
    Both lists are head-capped (``head_symbols``/``head_aliases``) so one concept with many
    machine-extracted aliases can't bloat the payload; ``max_concepts`` bounds the total.
    Ordering is insertion-order (deterministic cap).
    """
    floor = _rank(min_confidence)
    rows: list[dict[str, Any]] = []
    for cid, c in concepts.items():
        if _rank(c.confidence) < floor:
            continue
        if not c.symbols:  # no search seed → not useful in the lightweight bridge
            continue
        rows.append({
            "concept_id": cid,
            "aliases": c.aliases[:head_aliases],
            "symbols": c.symbols[:head_symbols],
        })
        if len(rows) >= max_concepts:
            break
    return rows
