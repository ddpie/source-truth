"""Unit tests for file_search — the fast local-disk content search that replaces
the agent's slow EFS Grep. Uses a tiny temp repo (real ripgrep/grep on local
disk, no EFS, no network). Asserts: matches found, paths rewritten into the
agent's namespace (legacy /mnt/repo here for back-compat coverage; the shipped
mount_root="" repo-relative branch is covered too), no-match returns empty (not
an error), glob filtering, and the command builder shape.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import file_search  # noqa: E402


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "hero.cs").write_text(
        "public int MaxEncumbrance() { return Strength * 1.5; }\n", encoding="utf-8"
    )
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "items.json").write_text('{"MaxEncumbrance": 150}\n', encoding="utf-8")
    (tmp_path / "readme.md").write_text("no relevant token here\n", encoding="utf-8")
    return tmp_path


def test_finds_matches_and_rewrites_paths(repo: Path):
    out = file_search.run_search("MaxEncumbrance", local_root=str(repo), mount_root="/mnt/repo")
    assert out["count"] >= 2, out
    # Every returned path is rewritten into /mnt/repo space (never the local root).
    for m in out["matches"]:
        assert m["path"].startswith("/mnt/repo/"), m
        assert str(repo) not in m["path"]
        assert isinstance(m["line"], int) and m["line"] >= 1
    # The .cs and .json files both matched.
    paths = " ".join(m["path"] for m in out["matches"])
    assert "hero.cs" in paths and "items.json" in paths


def test_repo_relative_mount_root_returns_relative_paths(repo: Path):
    # Production ships with mount_root="" (bootstrap.sh --mount-root "") → paths
    # come back repo-relative, never absolute. This is the actually-deployed branch.
    out = file_search.run_search("MaxEncumbrance", local_root=str(repo), mount_root="")
    assert out["count"] >= 2, out
    for m in out["matches"]:
        assert not m["path"].startswith("/"), m   # repo-relative, no leading slash
        assert str(repo) not in m["path"]
    paths = " ".join(m["path"] for m in out["matches"])
    assert "src/hero.cs" in paths and "config/items.json" in paths


def test_glob_narrows_by_filetype(repo: Path):
    out = file_search.run_search("MaxEncumbrance", local_root=str(repo), mount_root="/mnt/repo", glob="*.json")
    assert out["count"] >= 1
    assert all(m["path"].endswith(".json") for m in out["matches"]), out


def test_no_match_returns_empty_not_error(repo: Path):
    out = file_search.run_search("zzz_no_such_token_zzz", local_root=str(repo), mount_root="/mnt/repo")
    assert out["count"] == 0
    assert out["matches"] == []
    assert out["truncated"] is False


def test_empty_pattern_raises(repo: Path):
    with pytest.raises(ValueError):
        file_search.run_search("   ", local_root=str(repo), mount_root="/mnt/repo")


def test_search_to_json_is_valid_json(repo: Path):
    import json
    s = file_search.search_to_json("MaxEncumbrance", local_root=str(repo), mount_root="/mnt/repo")
    d = json.loads(s)
    assert "matches" in d and "count" in d and "deduped" in d


def test_finds_gitignored_and_hidden_files(tmp_path: Path):
    # "代码为唯一依据": a file physically on disk must be searchable even if it is
    # .gitignore'd or a dotfile — rg defaults would silently hide both. Build a
    # real git tree so rg's .gitignore logic activates, then assert we still find
    # the gitignored file and the dotfile.
    import subprocess
    (tmp_path / ".gitignore").write_text("generated.cs\n", encoding="utf-8")
    (tmp_path / "generated.cs").write_text("int SECRETTOKENVALUE = 1;\n", encoding="utf-8")
    (tmp_path / ".hidden.json").write_text('{"SECRETTOKENVALUE": 2}\n', encoding="utf-8")
    (tmp_path / "normal.cs").write_text("int SECRETTOKENVALUE = 3;\n", encoding="utf-8")
    # make it a git work-tree so rg would (wrongly) honor .gitignore without --no-ignore
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=False)
    out = file_search.run_search("SECRETTOKENVALUE", local_root=str(tmp_path), mount_root="/mnt/repo")
    paths = " ".join(m["path"] for m in out["matches"])
    assert "generated.cs" in paths, f"gitignored file must be found: {paths}"
    assert ".hidden.json" in paths, f"dotfile must be found: {paths}"
    assert "normal.cs" in paths


def test_dedups_duplicated_copies(tmp_path: Path):
    # A repo with N identical copies of a tree (vendored/duplicated code, like the
    # test repo's 10x dfu_scripts_N) must NOT return the same hit N times — that
    # 10x'd the agent's context and made answers minutes-slow. The copies differ
    # ONLY in their top-level dir (copy_a/Game/Enemy.cs vs copy_b/Game/Enemy.cs),
    # so the (path-without-top-dir, line, text) key folds them to one match.
    for copy in ("copy_a", "copy_b", "copy_c"):
        d = tmp_path / copy / "Game"
        d.mkdir(parents=True)
        (d / "Enemy.cs").write_text("int Damage = UNIQUE_MARKER_X;\n", encoding="utf-8")
    out = file_search.run_search("UNIQUE_MARKER_X", local_root=str(tmp_path), mount_root="/mnt/repo")
    # 3 identical copies → exactly ONE match, not three…
    assert out["count"] == 1, out
    assert "Enemy.cs" in out["matches"][0]["path"]
    # …and the fold is REPORTED (not silent): the agent sees 2 hits were collapsed
    # and can re-search a specific copy dir if it actually needs the duplicates.
    assert out["deduped"] == 2, out


def test_does_not_over_dedup_distinct_subpaths(tmp_path: Path):
    # The key keeps the path BELOW the top-level dir as a discriminator, so two
    # genuinely-different files at different sub-paths are NOT collapsed even with
    # identical line text — only whole-tree copies (same sub-path) fold. This is
    # strictly less aggressive than a bare-basename key.
    (tmp_path / "pkg" / "combat").mkdir(parents=True)
    (tmp_path / "pkg" / "ui").mkdir(parents=True)
    (tmp_path / "pkg" / "combat" / "Util.cs").write_text("int v = SHARED_TOKEN;\n", encoding="utf-8")
    (tmp_path / "pkg" / "ui" / "Util.cs").write_text("int v = SHARED_TOKEN;\n", encoding="utf-8")
    out = file_search.run_search("SHARED_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
    assert out["count"] == 2, out  # combat/Util.cs ≠ ui/Util.cs → both kept
    assert out["deduped"] == 0, out


def test_does_not_over_dedup_distinct_files(tmp_path: Path):
    # Different files (different basenames) with the same line content are kept.
    (tmp_path / "A.cs").write_text("int v = SHARED_TOKEN;\n", encoding="utf-8")
    (tmp_path / "B.cs").write_text("int v = SHARED_TOKEN;\n", encoding="utf-8")
    out = file_search.run_search("SHARED_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
    assert out["count"] == 2, out  # distinct basenames → both kept


def test_root_file_not_folded_with_nested_same_name(tmp_path: Path):
    # A repo-ROOT file and a nested file sharing a basename + line + text must NOT
    # fold: the root file has no top-level dir to drop, so it must stay distinct
    # from a nested file whose suffix degenerates to the same basename. (Regression
    # for the bare-basename degeneration the docstring promises it avoids.)
    (tmp_path / "Config.cs").write_text("int v = ROOT_TOKEN;\n", encoding="utf-8")
    (tmp_path / "legacy").mkdir()
    (tmp_path / "legacy" / "Config.cs").write_text("int v = ROOT_TOKEN;\n", encoding="utf-8")
    out = file_search.run_search("ROOT_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
    assert out["count"] == 2, out  # /Config.cs ≠ /legacy/Config.cs → both kept
    assert out["deduped"] == 0, out


def test_dup_cap_bounds_heavy_duplication(tmp_path: Path):
    # Under pathological duplication almost every hit is a fold (never appends), so
    # the max_matches break can't fire — the scan must still be bounded by
    # SCAN_DUP_CAP so the loop can't iterate unbounded output. Force a tiny cap and
    # assert truncation kicks in well before processing everything.
    import file_search as fs
    orig = fs.SCAN_DUP_CAP
    fs.SCAN_DUP_CAP = 5
    try:
        # Many identical copies (all fold to one match) — dup rows >> 5.
        for i in range(20):
            d = tmp_path / f"copy_{i}" / "Game"
            d.mkdir(parents=True)
            (d / "Enemy.cs").write_text("int Damage = CAP_TOKEN;\n", encoding="utf-8")
        out = fs.run_search("CAP_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
        # Folds to 1 kept match, but the scan stopped at the dup cap.
        assert out["count"] == 1, out
        assert out["truncated"] is True, out
        assert out["deduped"] <= fs.SCAN_DUP_CAP, out
    finally:
        fs.SCAN_DUP_CAP = orig


def test_dup_flood_does_not_starve_distinct_matches(tmp_path: Path):
    # Regression for the round-3 finding: a flood of folded duplicates emitted
    # BEFORE distinct files must NOT consume the distinct-match budget. With the
    # cap gating on duplicates alone, distinct hits keep being appended even after
    # a large dup flood. Force a small dup cap; ensure a distinct file that sorts
    # AFTER the dup flood is still surfaced.
    import file_search as fs
    orig = fs.SCAN_DUP_CAP
    fs.SCAN_DUP_CAP = 100  # generous enough to pass the flood, small enough to bound
    try:
        # "0_dups": many identical copies of one file → fold to 1 match, many dups.
        for i in range(8):
            d = tmp_path / "0_dups" / f"copy_{i}"
            d.mkdir(parents=True)
            (d / "Same.cs").write_text("int x = FLOOD_TOKEN;\n", encoding="utf-8")
        # "9_distinct": a genuinely distinct file that sorts AFTER the dup flood.
        d2 = tmp_path / "9_distinct"
        d2.mkdir()
        (d2 / "Unique.cs").write_text("int y = FLOOD_TOKEN;\n", encoding="utf-8")
        out = fs.run_search("FLOOD_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
        paths = " ".join(m["path"] for m in out["matches"])
        # The distinct file after the flood is NOT starved out.
        assert "9_distinct/Unique.cs" in paths, out
    finally:
        fs.SCAN_DUP_CAP = orig


def test_same_basename_collapse_is_never_silent(tmp_path: Path):
    # Worst case for any content-fold: two genuinely-distinct files that DO share
    # the same sub-path tail + line + text (moduleA/Utils.cs vs moduleB/Utils.cs,
    # differing only in top-level dir). The reviewer flagged that folding these is
    # ambiguous (could be vendored copies, could be two real modules). We accept the
    # fold for speed BUT it must be VISIBLE: deduped>0 tells the agent a hit was
    # collapsed so it can recover by re-searching a subdir — no invisible recall loss.
    (tmp_path / "moduleA").mkdir()
    (tmp_path / "moduleB").mkdir()
    (tmp_path / "moduleA" / "Utils.cs").write_text("int Clamp = AMBIG_TOKEN;\n", encoding="utf-8")
    (tmp_path / "moduleB" / "Utils.cs").write_text("int Clamp = AMBIG_TOKEN;\n", encoding="utf-8")
    out = file_search.run_search("AMBIG_TOKEN", local_root=str(tmp_path), mount_root="/mnt/repo")
    assert out["deduped"] > 0, f"a same-tail collapse must be reported, not silent: {out}"


def test_build_command_does_not_skip_gitignored_or_hidden():
    cmd = file_search.build_command("foo", "/data/repo/x", glob=None, max_matches=50)
    if cmd[0] == "rg":
        assert "--no-ignore" in cmd, "rg must not skip .gitignore'd files (they exist on disk)"
        assert "--hidden" in cmd, "rg must include dotfiles"


def test_build_command_scopes_to_root_and_glob():
    cmd = file_search.build_command("foo", "/data/repo/x", glob="*.cs", max_matches=50)
    assert cmd[0] in ("rg", "grep")
    # the search root is always the LAST positional (local copy, never EFS)
    assert cmd[-1] == "/data/repo/x"
    # the pattern is present
    assert "foo" in cmd
    # glob is threaded through (rg --glob or grep --include)
    assert any("*.cs" in part for part in cmd)
