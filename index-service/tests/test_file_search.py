"""Unit tests for file_search — the fast local-disk content search that replaces
the agent's slow EFS Grep. Uses a tiny temp repo (real ripgrep/grep on local
disk, no EFS, no network). Asserts: matches found, paths rewritten into /mnt/repo
space, no-match returns empty (not an error), glob filtering, and the command
builder shape.
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
    assert "matches" in d and "count" in d


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
