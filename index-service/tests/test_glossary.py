"""Unit tests for glossary.py — the concept-centric term index.

The glossary maps Chinese/colloquial terms a planner uses ("战力", "爆率") to the
ENGLISH code symbols they actually appear as ("combatPower", "loot_chance"), so the
agent can turn a Chinese question into code search terms. It is a fully-automatic
DERIVED product (no human review): built from code symbols + comment terms at index
time, rebuilt incrementally per git-diff on refresh.

Design contracts under test:
  - CONCEPT-CENTRIC: many terms/symbols map to ONE concept_id (the "multiple terms,
    same concept" problem). Aggregation groups records by concept_id.
  - PER-SOURCE accounting: each record remembers its source file, so an incremental
    update can drop just the changed file's records and re-extract, WITHOUT losing a
    concept's symbols contributed by OTHER (unchanged) files.
  - SAFETY: symbol values pass a strict charset whitelist (they reach the agent as
    search seeds); concept_id is slug-shaped; alias text is untrusted free text.
"""

from __future__ import annotations

import sys
from pathlib import Path


SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import glossary  # noqa: E402


def _rec(concept_id, kind, value, source, line=0, confidence="high"):
    return glossary.Entry(concept_id=concept_id, kind=kind, value=value,
                          source=source, line=line, confidence=confidence)


# --- aggregation: many records -> concepts grouped by concept_id ---------------
def test_aggregate_groups_aliases_and_symbols_under_one_concept():
    entries = [
        _rec("combat_power", "symbol", "combatPower", "src/Player.cpp", 42),
        _rec("combat_power", "symbol", "CombatPower.calc", "src/Combat.cpp", 10),
        _rec("combat_power", "alias", "战力", "src/Player.cpp", 40),
        _rec("combat_power", "alias", "战斗力", "src/Combat.cpp", 8),
        _rec("drop_rate", "symbol", "loot_chance", "sql/world.sql", 100),
        _rec("drop_rate", "alias", "爆率", "sql/world.sql", 99),
    ]
    concepts = glossary.aggregate(entries)
    assert set(concepts) == {"combat_power", "drop_rate"}
    cp = concepts["combat_power"]
    # multiple symbols AND multiple aliases collapse into ONE concept
    assert set(cp.symbols) == {"combatPower", "CombatPower.calc"}
    assert set(cp.aliases) == {"战力", "战斗力"}
    # sources tracked (drives incremental + provenance/citation)
    assert "src/Player.cpp" in cp.sources and "src/Combat.cpp" in cp.sources


def test_aggregate_dedups_repeated_value_keeps_first_source():
    entries = [
        _rec("stamina", "symbol", "maxStamina", "a.cpp", 1),
        _rec("stamina", "symbol", "maxStamina", "b.cpp", 2),  # same symbol, other file
    ]
    concepts = glossary.aggregate(entries)
    assert concepts["stamina"].symbols == ["maxStamina"]  # deduped
    # but BOTH source files are remembered (so removing only a.cpp keeps the symbol)
    assert set(concepts["stamina"].sources) == {"a.cpp", "b.cpp"}


# --- incremental: per-source accounting keeps cross-file concepts correct -------
def test_incremental_remove_changed_file_keeps_other_files_symbols():
    # combat_power is contributed by TWO files. Re-indexing only Combat.cpp must NOT
    # drop combatPower (which came from Player.cpp) — the core cross-file correctness bug.
    entries = [
        _rec("combat_power", "symbol", "combatPower", "src/Player.cpp", 42),
        _rec("combat_power", "symbol", "CombatPower.calc", "src/Combat.cpp", 10),
    ]
    # Simulate: Combat.cpp changed → drop its records, re-extract gives a renamed symbol.
    kept = glossary.drop_sources(entries, {"src/Combat.cpp"})
    assert [e.value for e in kept] == ["combatPower"]  # Player.cpp's contribution survives
    re_extracted = [_rec("combat_power", "symbol", "CalcCombatPower", "src/Combat.cpp", 11)]
    merged = kept + re_extracted
    concepts = glossary.aggregate(merged)
    assert set(concepts["combat_power"].symbols) == {"combatPower", "CalcCombatPower"}


def test_incremental_concept_vanishes_when_all_sources_removed():
    entries = [_rec("ephemeral", "symbol", "oldThing", "gone.cpp", 1)]
    kept = glossary.drop_sources(entries, {"gone.cpp"})
    assert glossary.aggregate(kept) == {}  # no records → no concept


def test_drop_sources_handles_deleted_file_with_multiple_entries():
    entries = [
        _rec("c", "symbol", "x", "f.cpp", 1),
        _rec("c", "alias", "甲", "f.cpp", 1),
        _rec("c", "symbol", "y", "keep.cpp", 1),
    ]
    kept = glossary.drop_sources(entries, {"f.cpp"})
    assert {(e.kind, e.value) for e in kept} == {("symbol", "y")}


# --- safety: charset whitelist on symbols, slug on concept_id ------------------
def test_symbol_charset_rejects_injection():
    # Symbols reach the agent as search seeds; only identifier-ish chars allowed.
    assert glossary.is_valid_symbol("combatPower")
    assert glossary.is_valid_symbol("CombatPower.calc")
    assert glossary.is_valid_symbol("loot_chance")
    assert not glossary.is_valid_symbol("rm -rf /")
    assert not glossary.is_valid_symbol("a; DROP TABLE")
    assert not glossary.is_valid_symbol("`backtick`")


def test_concept_id_is_slug():
    assert glossary.is_valid_concept_id("combat_power")
    assert glossary.is_valid_concept_id("drop-rate-2")
    assert not glossary.is_valid_concept_id("Combat Power")
    assert not glossary.is_valid_concept_id("../escape")


def test_aggregate_drops_records_failing_validation():
    # A symbol record with a bad value is dropped (defense-in-depth); aliases (free
    # text) are kept but never used as search seeds.
    entries = [
        _rec("c", "symbol", "goodSym", "f.cpp", 1),
        _rec("c", "symbol", "bad; rm", "f.cpp", 2),
        _rec("c", "alias", "随便的中文别名", "f.cpp", 3),
    ]
    concepts = glossary.aggregate(entries)
    assert concepts["c"].symbols == ["goodSym"]  # bad symbol dropped
    assert "随便的中文别名" in concepts["c"].aliases  # alias kept (not a seed)


# --- persistence round-trip (JSONL: one record per line) ----------------------
def test_jsonl_roundtrip(tmp_path):
    entries = [
        _rec("combat_power", "symbol", "combatPower", "src/Player.cpp", 42, "high"),
        _rec("combat_power", "alias", "战力", "src/Player.cpp", 40, "med"),
    ]
    p = tmp_path / "entries.jsonl"
    glossary.write_entries(str(p), entries)
    loaded = glossary.read_entries(str(p))
    assert loaded == entries


def test_read_entries_skips_malformed_lines(tmp_path):
    p = tmp_path / "entries.jsonl"
    p.write_text(
        '{"concept_id":"a","kind":"symbol","value":"x","source":"f","line":1,"confidence":"high"}\n'
        "not json\n"
        '{"concept_id":"a"}\n'  # missing fields
        '{"concept_id":"b","kind":"symbol","value":"y","source":"g","line":2,"confidence":"low"}\n'
    )
    loaded = glossary.read_entries(str(p))
    assert [e.value for e in loaded] == ["x", "y"]  # malformed/partial skipped, not fatal


# --- lightweight index projection (what gets injected into context) -----------
def test_to_index_is_compact_and_budget_bounded():
    entries = []
    # 3 concepts, high confidence; one low-confidence concept that must be excluded from
    # the lightweight (always-in-context) layer.
    for cid, sym, alias in [("a", "aaa", "甲"), ("b", "bbb", "乙"), ("c", "ccc", "丙")]:
        entries.append(_rec(cid, "symbol", sym, "f.cpp", 1, "high"))
        entries.append(_rec(cid, "alias", alias, "f.cpp", 1, "high"))
    entries.append(_rec("weak", "symbol", "wk", "f.cpp", 1, "low"))
    entries.append(_rec("weak", "alias", "弱", "f.cpp", 1, "low"))
    concepts = glossary.aggregate(entries)
    idx = glossary.to_index(concepts, max_concepts=2)
    # budget cap honored
    assert len(idx) == 2
    # low-confidence excluded even if budget had room (only high in lightweight layer)
    idx_all = glossary.to_index(concepts, max_concepts=99)
    assert all(c["concept_id"] != "weak" for c in idx_all)
    # each lightweight row carries alias cluster + head symbols (the search seeds)
    row = idx_all[0]
    assert "concept_id" in row and "aliases" in row and "symbols" in row


# --- R2 gaps: head caps, confidence clamp ---
def test_to_index_caps_head_aliases_and_symbols():
    entries = [_rec("c", "symbol", f"sym{i}", "f", 1, "high") for i in range(8)]
    entries += [_rec("c", "alias", f"别名{i}", "f", 1, "high") for i in range(10)]
    idx = glossary.to_index(glossary.aggregate(entries))
    row = idx[0]
    assert len(row["symbols"]) == 4   # head_symbols default
    assert len(row["aliases"]) == 6   # head_aliases default


def test_from_dict_clamps_unknown_confidence_to_low():
    e = glossary.Entry.from_dict({"concept_id": "c", "kind": "symbol", "value": "x",
                                  "source": "f", "line": 1, "confidence": "BOGUS"})
    assert e.confidence == "low"


def test_from_dict_missing_confidence_defaults_high():
    e = glossary.Entry.from_dict({"concept_id": "c", "kind": "symbol", "value": "x",
                                  "source": "f", "line": 1})
    assert e.confidence == "high"


# --- R5 resilience: non-UTF8 bytes in a slice degrade one line, don't raise ---
def test_read_entries_survives_non_utf8(tmp_path):
    p = tmp_path / "s.jsonl"
    good = '{"concept_id":"c","kind":"symbol","value":"x","source":"f","line":1,"confidence":"high"}\n'
    p.write_bytes(good.encode("utf-8") + b"\xff\xfe garbage bytes\n" + good.encode("utf-8"))
    loaded = glossary.read_entries(str(p))   # must NOT raise UnicodeDecodeError
    assert [e.value for e in loaded] == ["x", "x"]  # good lines survive, garbage skipped
