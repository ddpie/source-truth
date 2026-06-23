"""Unit tests for glossary_read.py — the two read functions backing the
glossary_index / glossary_lookup MCP tools.

ISOLATION CONTRACT (design §9.2): the glossary lives at /data/glossary/<project>/,
OUTSIDE the code sandbox root /data/repo/<subdir>. So it needs its OWN confinement —
the code file-read tools would realpath-reject it. The sandbox root is fixed at
/data/glossary/<project>/ (never the /data/glossary/ top level — that would let one
project read another's via ../B), project name passes ^[a-z0-9-]+$, and every
resolved path is realpath-confined under the project root (symlink-escape proof).

  glossary_index(project)          -> lightweight layer the agent calls first: the
                                      alias-cluster -> concept_id -> head-symbols rows.
  glossary_lookup(project, query)  -> full record by concept_id OR Chinese term (all
                                      symbols, aliases, source anchors, confidence).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import glossary  # noqa: E402
import glossary_read  # noqa: E402


@pytest.fixture()
def glossary_root(tmp_path):
    """A /data/glossary-like root with one project 'mangos' holding two concepts."""
    root = tmp_path / "glossary"
    proj = root / "mangos"
    proj.mkdir(parents=True)
    entries = [
        glossary.Entry("combat_power", "symbol", "combatPower", "src/Player.cpp", 42, "high"),
        glossary.Entry("combat_power", "symbol", "CombatPower.calc", "src/Combat.cpp", 10, "high"),
        glossary.Entry("combat_power", "alias", "战力", "src/Player.cpp", 40, "high"),
        glossary.Entry("combat_power", "alias", "战斗力", "src/Combat.cpp", 8, "high"),
        glossary.Entry("drop_rate", "symbol", "loot_chance", "sql/world.sql", 100, "low"),
        glossary.Entry("drop_rate", "alias", "爆率", "sql/world.sql", 99, "low"),
    ]
    glossary.write_entries(str(proj / "entries.jsonl"), entries)
    return root


# --- glossary_index: the lightweight always-in-context layer ------------------
def test_index_returns_high_confidence_clusters(glossary_root):
    out = glossary_read.glossary_index("mangos", glossary_root=str(glossary_root))
    cids = {c["concept_id"] for c in out["concepts"]}
    assert "combat_power" in cids          # high-confidence -> in lightweight layer
    assert "drop_rate" not in cids          # low-confidence -> only via lookup
    cp = next(c for c in out["concepts"] if c["concept_id"] == "combat_power")
    assert set(cp["aliases"]) == {"战力", "战斗力"}
    assert "combatPower" in cp["symbols"]


def test_index_missing_project_returns_empty_not_error(glossary_root):
    # A project with no glossary yet must degrade gracefully (feature is optional).
    out = glossary_read.glossary_index("temporal", glossary_root=str(glossary_root))
    assert out["concepts"] == []


# --- glossary_lookup: full record for one concept (incl. low-confidence) ------
def test_lookup_returns_full_record_with_anchors(glossary_root):
    out = glossary_read.glossary_lookup("mangos", "combat_power", glossary_root=str(glossary_root))
    assert set(out["symbols"]) == {"combatPower", "CombatPower.calc"}
    assert set(out["aliases"]) == {"战力", "战斗力"}
    # source anchors for citation / "code as the only truth" verification
    srcs = {a["source"] for a in out["anchors"]}
    assert {"src/Player.cpp", "src/Combat.cpp"} <= srcs


def test_lookup_reaches_low_confidence_concept(glossary_root):
    # lookup is the on-demand layer — it must surface concepts the lightweight index hides.
    out = glossary_read.glossary_lookup("mangos", "drop_rate", glossary_root=str(glossary_root))
    assert out["symbols"] == ["loot_chance"]
    assert out["confidence"] == "low"


def test_lookup_unknown_concept_returns_error_field(glossary_root):
    out = glossary_read.glossary_lookup("mangos", "no_such", glossary_root=str(glossary_root))
    assert out.get("error")


# --- #2: med concepts reach the index; alias-only excluded; lookup by term ----
def test_index_includes_med_confidence_concept(tmp_path):
    # cc tends to mark Chinese aliases "med"; the whole bridge dies if med is excluded.
    # A med concept WITH a symbol must appear in the lightweight index.
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "x.jsonl"), [
        glossary.Entry("encumbrance", "symbol", "maxEncumbrance", "I.cs", 1, "med"),
        glossary.Entry("encumbrance", "alias", "负重上限", "I.cs", 1, "med"),
    ])
    out = glossary_read.glossary_index("p", glossary_root=str(root))
    cids = {c["concept_id"] for c in out["concepts"]}
    assert "encumbrance" in cids
    row = next(c for c in out["concepts"] if c["concept_id"] == "encumbrance")
    assert "负重上限" in row["aliases"] and "maxEncumbrance" in row["symbols"]


def test_index_excludes_alias_only_concept(tmp_path):
    # A concept with aliases but NO symbol gives the agent no search seed → useless in the
    # lightweight layer (still reachable via lookup).
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "x.jsonl"), [
        glossary.Entry("vibes", "alias", "感觉", "I.cs", 1, "high"),
    ])
    out = glossary_read.glossary_index("p", glossary_root=str(root))
    assert all(c["concept_id"] != "vibes" for c in out["concepts"])


def test_lookup_by_chinese_term_resolves_without_concept_id(glossary_root):
    # The key fix: the agent has the user's word ("战力"), not a concept_id. Lookup by term.
    out = glossary_read.glossary_lookup("mangos", "战力", glossary_root=str(glossary_root))
    # single match → flat record
    assert out.get("concept_id") == "combat_power"
    assert "combatPower" in out["symbols"]


def test_lookup_by_term_substring_on_symbol(glossary_root):
    out = glossary_read.glossary_lookup("mangos", "loot", glossary_root=str(glossary_root))
    # 'loot' substring of loot_chance → drop_rate concept (low confidence, index-hidden)
    assert out.get("concept_id") == "drop_rate" or any(
        m["concept_id"] == "drop_rate" for m in out.get("matches", []))


def test_lookup_ambiguous_term_returns_all_matches(tmp_path):
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "x.jsonl"), [
        glossary.Entry("attack_power", "alias", "攻击力", "a.cs", 1, "high"),
        glossary.Entry("attack_power", "symbol", "attackPower", "a.cs", 1, "high"),
        glossary.Entry("attack_speed", "alias", "攻击速度", "b.cs", 1, "high"),
        glossary.Entry("attack_speed", "symbol", "attackSpeed", "b.cs", 1, "high"),
    ])
    out = glossary_read.glossary_lookup("p", "攻击", glossary_root=str(root))
    ids = {m["concept_id"] for m in out["matches"]}
    assert ids == {"attack_power", "attack_speed"}


# --- #3: multi-repo concept_id namespacing (temporal-style 3-repo project) ----
def _multirepo(tmp_path):
    root = tmp_path / "g"
    proj = root / "temporal"
    proj.mkdir(parents=True)
    # Two repos BOTH define concept_id "level" meaning unrelated things.
    glossary.write_entries(str(proj / "server.jsonl"), [
        glossary.Entry("level", "symbol", "logLevel", "log.go", 1, "high"),
        glossary.Entry("level", "alias", "日志级别", "log.go", 1, "high"),
    ])
    glossary.write_entries(str(proj / "sdk.jsonl"), [
        glossary.Entry("level", "symbol", "retryLevel", "retry.go", 1, "high"),
        glossary.Entry("level", "alias", "重试层级", "retry.go", 1, "high"),
    ])
    return root


def test_multirepo_same_concept_id_not_merged_in_index(tmp_path):
    root = _multirepo(tmp_path)
    out = glossary_read.glossary_index("temporal", glossary_root=str(root))
    cids = sorted(c["concept_id"] for c in out["concepts"])
    # namespaced per repo — the two unrelated "level"s stay distinct
    assert cids == ["sdk/level", "server/level"]
    server = next(c for c in out["concepts"] if c["concept_id"] == "server/level")
    assert server["repo"] == "server"
    assert server["symbols"] == ["logLevel"]            # NOT fused with retryLevel
    assert "重试层级" not in server["aliases"]          # no cross-repo alias bleed


def test_multirepo_lookup_by_term_tags_repo(tmp_path):
    root = _multirepo(tmp_path)
    # The term "级别" only appears in the server repo's alias.
    out = glossary_read.glossary_lookup("temporal", "级别", glossary_root=str(root))
    assert out["repo"] == "server" and out["concept_id"] == "server/level"
    assert out["symbols"] == ["logLevel"]


def test_multirepo_lookup_namespaced_id_pins_repo(tmp_path):
    root = _multirepo(tmp_path)
    out = glossary_read.glossary_lookup("temporal", "sdk/level", glossary_root=str(root))
    assert out["repo"] == "sdk" and out["symbols"] == ["retryLevel"]


def test_singlerepo_keeps_bare_concept_id(tmp_path):
    # A single-repo project must NOT gain repo prefixes (back-compat).
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "mangos.jsonl"), [
        glossary.Entry("race", "symbol", "ChrRaces", "x.cpp", 1, "high"),
        glossary.Entry("race", "alias", "种族", "x.cpp", 1, "high"),
    ])
    out = glossary_read.glossary_index("p", glossary_root=str(root))
    assert out["concepts"][0]["concept_id"] == "race"
    assert "repo" not in out["concepts"][0]


# --- isolation: project-name whitelist + path confinement ---------------------
def test_project_name_charset_rejected(glossary_root):
    for bad in ("../mangos", "mangos/..", "..", "a/b", "Mangos!", ""):
        with pytest.raises(ValueError):
            glossary_read.glossary_index(bad, glossary_root=str(glossary_root))


def test_cannot_escape_to_sibling_project(tmp_path):
    # Two projects; a crafted name must not let A read B (the ../B traversal §9.2 warns of).
    root = tmp_path / "glossary"
    (root / "a").mkdir(parents=True)
    (root / "b").mkdir(parents=True)
    glossary.write_entries(str(root / "b" / "entries.jsonl"),
                           [glossary.Entry("secret", "symbol", "x", "f", 1, "high")])
    with pytest.raises(ValueError):
        glossary_read.glossary_index("../b", glossary_root=str(root))


def test_symlink_escape_rejected(tmp_path):
    # A project dir that symlinks its entries.jsonl outside the glossary root is refused.
    root = tmp_path / "glossary"
    (root / "evil").mkdir(parents=True)
    outside = tmp_path / "outside.jsonl"
    glossary.write_entries(str(outside),
                           [glossary.Entry("leak", "symbol", "x", "f", 1, "high")])
    import os
    os.symlink(str(outside), str(root / "evil" / "entries.jsonl"))
    with pytest.raises(ValueError):
        glossary_read.glossary_index("evil", glossary_root=str(root))


def test_to_json_helpers_valid(glossary_root):
    import json
    s = glossary_read.index_to_json("mangos", glossary_root=str(glossary_root))
    assert isinstance(json.loads(s)["concepts"], list)
    s2 = glossary_read.lookup_to_json("mangos", "combat_power", glossary_root=str(glossary_root))
    assert json.loads(s2)["symbols"]


# --- R2 gaps: budget across slices, dedup, empty query ---
def test_index_budget_split_across_slices_no_starvation(tmp_path):
    # One big repo must NOT starve a small repo out of the index (the R2-H1 bug).
    root = tmp_path / "g"
    proj = root / "multi"
    proj.mkdir(parents=True)
    big = [glossary.Entry(f"a{i}", "symbol", f"symA{i}", "a.cpp", 1, "high") for i in range(20)]
    small = [glossary.Entry("z0", "symbol", "symZ", "z.cpp", 1, "high")]
    glossary.write_entries(str(proj / "aaa.jsonl"), big)
    glossary.write_entries(str(proj / "zzz.jsonl"), small)
    out = glossary_read.glossary_index("multi", glossary_root=str(root), max_concepts=10)
    repos = {c["repo"] for c in out["concepts"]}
    assert "zzz" in repos and "aaa" in repos   # small repo not starved


def test_lookup_bare_id_returns_all_repos_matches(tmp_path):
    # R2-H2: a bare id shared by two repos must surface BOTH, not just the first.
    root = _multirepo(tmp_path)
    out = glossary_read.glossary_lookup("temporal", "level", glossary_root=str(root))
    ids = {m["concept_id"] for m in out["matches"]}
    assert ids == {"server/level", "sdk/level"}


def test_lookup_dedup_same_concept_matched_via_two_aliases(tmp_path):
    # A concept whose TWO aliases both contain the query must appear ONCE (seen-dedup).
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "x.jsonl"), [
        glossary.Entry("attack", "symbol", "atk", "a.cs", 1, "high"),
        glossary.Entry("attack", "alias", "攻击力", "a.cs", 1, "high"),
        glossary.Entry("attack", "alias", "攻击速度", "a.cs", 1, "high"),
    ])
    out = glossary_read.glossary_lookup("p", "攻击", glossary_root=str(root))
    # single concept → flat record (not matches), and not duplicated
    assert out.get("concept_id") == "attack"


def test_lookup_empty_and_whitespace_query_errors(glossary_root):
    assert glossary_read.glossary_lookup("mangos", "", glossary_root=str(glossary_root)).get("error")
    assert glossary_read.glossary_lookup("mangos", "   ", glossary_root=str(glossary_root)).get("error")


def test_lookup_dedups_identical_anchors(tmp_path):
    # Two identical entries (same value, same source:line) → ONE anchor, not two.
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    glossary.write_entries(str(root / "p" / "x.jsonl"), [
        glossary.Entry("c", "symbol", "foo", "a.cs", 5, "high"),
        glossary.Entry("c", "symbol", "foo", "a.cs", 5, "high"),
    ])
    out = glossary_read.glossary_lookup("p", "c", glossary_root=str(root))
    assert len(out["anchors"]) == 1


# --- R3 gaps: per_slice floor never 0; multi-repo confidence gating ---
def test_index_per_slice_floor_never_zero(tmp_path):
    # max_concepts < num_slices must NOT starve a slice to 0 (the max(1,..) floor).
    root = tmp_path / "g"
    proj = root / "multi"
    proj.mkdir(parents=True)
    glossary.write_entries(str(proj / "a.jsonl"), [glossary.Entry("ca", "symbol", "sa", "a", 1, "high")])
    glossary.write_entries(str(proj / "b.jsonl"), [glossary.Entry("cb", "symbol", "sb", "b", 1, "high")])
    out = glossary_read.glossary_index("multi", glossary_root=str(root), max_concepts=1)
    repos = {c["repo"] for c in out["concepts"]}
    assert repos == {"a", "b"}   # both slices still contribute despite max_concepts=1


def test_index_multirepo_per_slice_confidence_gating(tmp_path):
    # Each slice's index gating is independent: an all-low repo contributes nothing to the
    # lightweight index (only reachable via lookup), while a high repo does.
    root = tmp_path / "g"
    proj = root / "multi"
    proj.mkdir(parents=True)
    glossary.write_entries(str(proj / "hi.jsonl"), [glossary.Entry("c1", "symbol", "s1", "x", 1, "high")])
    glossary.write_entries(str(proj / "lo.jsonl"), [glossary.Entry("c2", "symbol", "s2", "y", 1, "low")])
    out = glossary_read.glossary_index("multi", glossary_root=str(root))
    repos = {c["repo"] for c in out["concepts"]}
    assert repos == {"hi"}        # low-only repo excluded from index
    # but still reachable via lookup
    lk = glossary_read.glossary_lookup("multi", "lo/c2", glossary_root=str(root))
    assert lk["symbols"] == ["s2"]


# --- R6: lookup caps a broad-term match set (no unbounded payload) ---
def test_lookup_broad_term_capped_with_hint(tmp_path):
    root = tmp_path / "g"
    (root / "p").mkdir(parents=True)
    # 100 concepts all containing the substring "战" → must cap at MAX_LOOKUP_MATCHES + flag.
    entries = []
    for i in range(100):
        entries.append(glossary.Entry(f"c{i}", "alias", f"战{i}", "f.cs", i, "high"))
        entries.append(glossary.Entry(f"c{i}", "symbol", f"sym{i}", "f.cs", i, "high"))
    glossary.write_entries(str(root / "p" / "x.jsonl"), entries)
    out = glossary_read.glossary_lookup("p", "战", glossary_root=str(root))
    assert out.get("truncated") is True
    assert len(out["matches"]) == glossary_read.MAX_LOOKUP_MATCHES
    assert "narrow" in out.get("hint", "")
