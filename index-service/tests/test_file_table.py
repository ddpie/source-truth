"""Unit tests for file_table.read_table — parsing structured/binary config files
(CSV/TSV/Excel/SQLite) to text for the read_table MCP tool. Read-only + confined.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import file_table  # noqa: E402

MOUNT = ""  # production: repo-relative


@pytest.fixture()
def repo(tmp_path):
    root = tmp_path / "repo"
    (root / "Config").mkdir(parents=True)
    (root / "Config" / "items.csv").write_text("name,atk,def\nsword,10,2\nshield,0,8\n", encoding="utf-8")
    (root / "Config" / "skills.tsv").write_text("skill\tcd\nfireball\t3\nheal\t5\n", encoding="utf-8")
    return root


# --- CSV / TSV -------------------------------------------------------------
def test_read_csv(repo):
    out = file_table.read_table("Config/items.csv", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "csv"
    assert out["path"] == "Config/items.csv"
    assert "name | atk | def" in out["content"]
    assert "sword | 10 | 2" in out["content"]
    assert out["truncated"] is False


def test_read_tsv(repo):
    out = file_table.read_table("Config/skills.tsv", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "tsv"
    assert "fireball | 3" in out["content"]


# --- Excel -----------------------------------------------------------------
def test_read_excel(repo):
    openpyxl = pytest.importorskip("openpyxl")
    p = repo / "Config" / "balance.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "weapons"
    ws.append(["weapon", "min", "max"])
    ws.append(["dagger", 1, 6])
    ws.append(["claymore", 2, 18])
    wb.save(str(p))
    out = file_table.read_table("Config/balance.xlsx", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "excel"
    assert "sheet 'weapons'" in out["content"]
    assert "weapon | min | max" in out["content"]
    assert "claymore | 2 | 18" in out["content"]


# --- SQLite ----------------------------------------------------------------
def test_read_sqlite(repo):
    p = repo / "Config" / "game.db"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE monsters(name TEXT, hp INT)")
    con.execute("INSERT INTO monsters VALUES ('rat', 4), ('orc', 30)")
    con.commit()
    con.close()
    out = file_table.read_table("Config/game.db", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "sqlite"
    assert "table 'monsters'" in out["content"]
    assert "rat | 4" in out["content"]
    assert "orc | 30" in out["content"]


def test_sqlite_is_read_only(repo):
    # The tool opens the db mode=ro&immutable=1 — confirm it can't write. (We can't
    # easily assert no-write from outside, but a read of a normal db must succeed and
    # the file mtime must be unchanged.)
    p = repo / "Config" / "ro.db"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE t(x)")
    con.commit()
    con.close()
    before = p.stat().st_mtime_ns
    file_table.read_table("Config/ro.db", local_root=str(repo), mount_root=MOUNT)
    assert p.stat().st_mtime_ns == before  # read didn't touch the file


# --- caps + confinement + errors -------------------------------------------
def test_row_cap_truncates(repo, monkeypatch):
    monkeypatch.setattr(file_table, "MAX_ROWS", 2)
    big = "\n".join([f"r{i},{i}" for i in range(50)])
    (repo / "Config" / "big.csv").write_text("a,b\n" + big + "\n", encoding="utf-8")
    out = file_table.read_table("Config/big.csv", local_root=str(repo), mount_root=MOUNT)
    assert out["truncated"] is True


def test_unsupported_extension_raises(repo):
    (repo / "Config" / "x.png").write_bytes(b"\x89PNG\r\n")
    with pytest.raises(ValueError, match="does not handle"):
        file_table.read_table("Config/x.png", local_root=str(repo), mount_root=MOUNT)


def test_missing_file_raises(repo):
    with pytest.raises(ValueError, match="not a readable file"):
        file_table.read_table("Config/nope.csv", local_root=str(repo), mount_root=MOUNT)


def test_path_escape_raises(repo):
    with pytest.raises(ValueError):
        file_table.read_table("../../etc/passwd", local_root=str(repo), mount_root=MOUNT)


def test_to_json_valid(repo):
    import json
    s = file_table.read_table_to_json("Config/items.csv", local_root=str(repo), mount_root=MOUNT)
    d = json.loads(s)
    assert d["kind"] == "csv" and "content" in d
