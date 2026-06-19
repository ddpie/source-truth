"""Read STRUCTURED tabular/binary config files as text, for the read_table MCP tool.

The agent's read_file decodes everything as UTF-8 text, so a binary config file
(Excel .xlsx/.xls, SQLite .db) comes back as garbage and the agent (correctly)
can't use it. But game-dev config tables — the planners' actual numbers — very
often live in EXACTLY those formats. This module parses them SERVER-SIDE (where
the read-only local repo copy lives) into compact text the agent can reason over:
  - .csv / .tsv          → normalized text rows (stdlib csv, handles quoting/delims)
  - .xlsx / .xlsm / .xls → each sheet rendered as a header + rows block (openpyxl)
  - .db / .sqlite/.sqlite3 → schema + a bounded SELECT * per table (stdlib sqlite3)

Strictly READ-ONLY: SQLite is opened in immutable/read-only mode; nothing is ever
written. Confinement reuses path_align.to_local_path (lexical + realpath escape
guard) — same untrusted-input discipline as read_file. Output is capped so a huge
sheet/table can't blow the agent's context (mirrors file_read's caps).
"""

from __future__ import annotations

import csv
import json
import logging
import os
import sqlite3
from time import perf_counter
from typing import Any

import path_align
from perf import perf_entry

logger = logging.getLogger("file-table")

# Caps so a giant sheet/table can't return megabytes into the agent context.
MAX_ROWS = 500            # rows per sheet/table
MAX_COLS = 64             # columns kept (wide sheets are usually padding beyond this)
MAX_CELL = 200            # chars per cell
MAX_TABLES = 40           # SQLite tables enumerated
MAX_OUTPUT_CHARS = 120_000  # hard ceiling on the whole returned text

# Extensions we know how to parse. read_file already handles plain text; this tool
# is for the structured/binary ones it can't.
CSV_EXT = (".csv",)
TSV_EXT = (".tsv",)
EXCEL_EXT = (".xlsx", ".xlsm", ".xltx", ".xltm")  # openpyxl reads the OOXML family
SQLITE_EXT = (".db", ".sqlite", ".sqlite3")


def _clip(s: Any) -> str:
    t = "" if s is None else str(s)
    return t[:MAX_CELL]


def _rows_to_text(rows: list[list[Any]], *, label: str) -> tuple[str, bool]:
    """Render rows as a compact pipe-delimited block. Returns (text, truncated)."""
    truncated = False
    if len(rows) > MAX_ROWS:
        rows = rows[:MAX_ROWS]
        truncated = True
    out_lines = []
    for r in rows:
        cells = list(r)[:MAX_COLS]
        if len(r) > MAX_COLS:
            truncated = True
        out_lines.append(" | ".join(_clip(c) for c in cells))
    body = "\n".join(out_lines)
    header = f"### {label} ({len(rows)} row(s){' — TRUNCATED' if truncated else ''})"
    return f"{header}\n{body}", truncated


def _read_csv(local_path: str, *, delimiter: str) -> tuple[str, bool]:
    with open(local_path, encoding="utf-8", errors="replace", newline="") as fh:
        reader = csv.reader(fh, delimiter=delimiter)
        rows = []
        for i, row in enumerate(reader):
            rows.append(row)
            if i >= MAX_ROWS:  # +1 read so we can flag truncation
                break
    return _rows_to_text(rows, label="sheet")


def _read_excel(local_path: str) -> tuple[str, bool]:
    # Lazy import so the module loads even where openpyxl is absent (it's installed
    # on the index host via requirements.txt; this keeps unit tests / local dev
    # importable). If it's genuinely missing, raise a CLEAN ValueError (→ the bridge
    # returns an actionable "cannot read table" rather than an opaque "failed").
    try:
        import openpyxl  # noqa: PLC0415
    except ImportError as exc:
        raise ValueError("Excel parsing unavailable on this index-service (openpyxl not installed)") from exc

    # read_only + data_only: stream rows without loading the whole workbook, and
    # return computed values rather than formula strings (planners want the numbers).
    wb = openpyxl.load_workbook(local_path, read_only=True, data_only=True)
    try:
        blocks, truncated = [], False
        for ws in wb.worksheets:
            rows = []
            for i, row in enumerate(ws.iter_rows(values_only=True)):
                rows.append(list(row))
                if i >= MAX_ROWS:
                    break
            block, t = _rows_to_text(rows, label=f"sheet '{ws.title}'")
            blocks.append(block)
            truncated = truncated or t
        return ("\n\n".join(blocks) if blocks else "(workbook has no sheets)"), truncated
    finally:
        wb.close()


def _read_sqlite(local_path: str) -> tuple[str, bool]:
    # READ-ONLY open: immutable=1 + mode=ro via URI so the tool can NEVER write/lock
    # the db (matches the read-only boundary). file: URI requires uri=True.
    uri = f"file:{local_path}?mode=ro&immutable=1"
    con = sqlite3.connect(uri, uri=True)
    try:
        cur = con.cursor()
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        tables = [r[0] for r in cur.fetchall()]
        truncated = False
        if len(tables) > MAX_TABLES:
            tables = tables[:MAX_TABLES]
            truncated = True
        blocks = []
        for tbl in tables:
            # Identifier can't be parameterized; quote it to neutralize odd names.
            q = f'SELECT * FROM "{tbl.replace(chr(34), chr(34) * 2)}" LIMIT {MAX_ROWS + 1}'
            cur.execute(q)
            cols = [d[0] for d in cur.description] if cur.description else []
            data = cur.fetchall()
            rows = [cols] + [list(r) for r in data]
            block, t = _rows_to_text(rows, label=f"table '{tbl}'")
            blocks.append(block)
            truncated = truncated or t
        return ("\n\n".join(blocks) if blocks else "(database has no user tables)"), truncated
    finally:
        con.close()


def read_table(requested: str, *, local_root: str, mount_root: str) -> dict[str, Any]:
    """Parse a structured table/binary config file (Excel/CSV/TSV/SQLite) to text.

    ``requested`` is an agent-space path; it's confined to ``local_root`` first.
    Returns {"path", "kind", "content", "truncated"} with ``path`` in the agent's
    namespace. Raises ValueError on a bad/escaping path, a missing file, or an
    unsupported extension (so the bridge reports a clean, actionable error)."""
    t0 = perf_counter()
    local_path = path_align.to_local_path(requested, local_root=local_root, mount_root=mount_root)
    if not os.path.isfile(local_path):
        raise ValueError(f"not a readable file: {requested!r}")
    ext = os.path.splitext(local_path)[1].lower()

    if ext in EXCEL_EXT:
        kind = "excel"
        content, truncated = _read_excel(local_path)
    elif ext in SQLITE_EXT:
        kind = "sqlite"
        content, truncated = _read_sqlite(local_path)
    elif ext in TSV_EXT:
        kind = "tsv"
        content, truncated = _read_csv(local_path, delimiter="\t")
    elif ext in CSV_EXT:
        kind = "csv"
        content, truncated = _read_csv(local_path, delimiter=",")
    else:
        raise ValueError(
            f"read_table does not handle '{ext}' files (supported: .xlsx/.xls family, "
            f".csv, .tsv, .db/.sqlite). For plain-text files use read_file."
        )

    if len(content) > MAX_OUTPUT_CHARS:
        content = content[:MAX_OUTPUT_CHARS]
        truncated = True
    mount_path = path_align.to_container_path(local_path, index_root=os.path.realpath(local_root), mount_root=mount_root)
    logger.info(perf_entry("read_table", (perf_counter() - t0) * 1000, path=mount_path[:120],
                           kind=kind, truncated=truncated))
    return {"path": mount_path, "kind": kind, "content": content, "truncated": truncated}


def read_table_to_json(requested: str, *, local_root: str, mount_root: str) -> str:
    """read_table → JSON string (the MCP tool return shape)."""
    return json.dumps(read_table(requested, local_root=local_root, mount_root=mount_root), ensure_ascii=False)
