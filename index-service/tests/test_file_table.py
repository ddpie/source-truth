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


def test_csv_wide_row_clipped_at_read(repo):
    # A pathological one-line CSV with a huge number of columns must NOT materialize
    # the full row (memory DoS) — it's clipped to MAX_COLS+1 at read time.
    p = repo / "Config" / "wide.csv"
    p.write_text(",".join(str(i) for i in range(100000)))  # 100k columns, one row
    out = file_table.read_table("Config/wide.csv", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "csv"
    # The rendered row has at most MAX_COLS cells (clip happens in _rows_to_text after
    # the read-time clip to MAX_COLS+1) — never 100k.
    first_line = [ln for ln in out["content"].splitlines() if "|" in ln][0]
    assert first_line.count("|") <= file_table.MAX_COLS


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


def test_read_sqlite_with_question_mark_in_filename(repo):
    # REGRESSION: a db file whose NAME contains '?' must not be mis-parsed as the
    # start of the URI query string (which silently opened the wrong file / failed).
    # The path is now percent-encoded in the file: URI.
    p = repo / "Config" / "weird?name.db"
    con = sqlite3.connect(str(p))
    con.execute("CREATE TABLE t(x INT)")
    con.execute("INSERT INTO t VALUES (7)")
    con.commit()
    con.close()
    out = file_table.read_table("Config/weird?name.db", local_root=str(repo), mount_root=MOUNT)
    assert out["kind"] == "sqlite"
    assert "table 't'" in out["content"]
    assert "7" in out["content"]


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


# --- DoS guards: on-disk size + zip-bomb inflate ---------------------------
def test_oversize_file_rejected_before_parse(repo, monkeypatch):
    # A file over MAX_FILE_BYTES must be refused BEFORE any parser runs (cheap DoS
    # guard). Shrink the cap rather than write GBs.
    monkeypatch.setattr(file_table, "MAX_FILE_BYTES", 64)
    (repo / "Config" / "huge.csv").write_text("a,b\n" + ("x,y\n" * 1000), encoding="utf-8")
    with pytest.raises(ValueError, match="read_table limit"):
        file_table.read_table("Config/huge.csv", local_root=str(repo), mount_root=MOUNT)


def test_zip_inflate_guard_rejects_bomb(repo, monkeypatch):
    # An .xlsx whose declared-uncompressed sizes exceed MAX_UNCOMPRESSED_BYTES must be
    # rejected from the central-directory sizes WITHOUT decompressing. Build a real
    # workbook, then lower the inflate ceiling below its uncompressed footprint.
    openpyxl = pytest.importorskip("openpyxl")
    p = repo / "Config" / "bomb.xlsx"
    wb = openpyxl.Workbook()
    ws = wb.active
    for i in range(200):
        ws.append([f"cell-{i}-{j}" for j in range(20)])
    wb.save(str(p))
    monkeypatch.setattr(file_table, "MAX_UNCOMPRESSED_BYTES", 128)  # below the real inflate size
    with pytest.raises(ValueError, match="zip-bomb"):
        file_table.read_table("Config/bomb.xlsx", local_root=str(repo), mount_root=MOUNT)


def test_corrupt_xlsx_raises_clean_error(repo):
    # A file with an .xlsx extension that is NOT a valid zip must fail with a clean,
    # actionable ValueError (not an opaque traceback).
    pytest.importorskip("openpyxl")
    (repo / "Config" / "fake.xlsx").write_bytes(b"this is not a zip at all")
    with pytest.raises(ValueError, match="not a valid .xlsx|corrupt"):
        file_table.read_table("Config/fake.xlsx", local_root=str(repo), mount_root=MOUNT)


def test_legacy_xls_explicitly_unsupported(repo):
    # The legacy binary .xls is NOT in EXCEL_EXT; the error must say so (openpyxl can't
    # read it) rather than misadvertise support.
    (repo / "Config" / "old.xls").write_bytes(b"\xd0\xcf\x11\xe0")  # OLE2 magic
    with pytest.raises(ValueError, match="does not handle"):
        file_table.read_table("Config/old.xls", local_root=str(repo), mount_root=MOUNT)
