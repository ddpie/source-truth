"""Read STRUCTURED tabular/binary config files as text, for the read_table MCP tool.

The agent's read_file decodes everything as UTF-8 text, so a binary config file
(Excel .xlsx, SQLite .db) comes back as garbage and the agent (correctly)
can't use it. But game-dev config tables — the planners' actual numbers — very
often live in EXACTLY those formats. This module parses them SERVER-SIDE (where
the read-only local repo copy lives) into compact text the agent can reason over:
  - .csv / .tsv          → normalized text rows (stdlib csv, handles quoting/delims)
  - .xlsx / .xlsm / .xltx / .xltm → each sheet rendered as a header + rows block (openpyxl;
                          the legacy binary .xls is NOT supported — re-save as .xlsx)
  - .db / .sqlite/.sqlite3 → schema + a bounded SELECT * per table (stdlib sqlite3)

Strictly READ-ONLY: SQLite is opened in immutable/read-only mode; nothing is ever
written. Confinement reuses path_align.to_local_path (lexical + realpath escape
guard) — same untrusted-input discipline as read_file. Output is capped so a huge
sheet/table can't blow the agent's context (mirrors file_read's caps).
"""

from __future__ import annotations

import csv
import io
import json
import logging
import os
import sqlite3
import urllib.parse
from time import perf_counter
from typing import Any

import path_align
from perf import perf_entry
from text_decode import decode_bytes

logger = logging.getLogger("file-table")

# Caps so a giant sheet/table can't return megabytes into the agent context.
MAX_ROWS = 500            # rows per sheet/table
MAX_COLS = 64             # columns kept (wide sheets are usually padding beyond this)
MAX_CELL = 200            # chars per cell
MAX_TABLES = 40           # SQLite tables enumerated
MAX_OUTPUT_CHARS = 120_000  # hard ceiling on the whole returned text
# ON-DISK size ceiling, checked BEFORE parsing. The render-time caps above bound the
# RETURNED string, not the PARSE footprint: openpyxl (read_only) still eagerly loads
# the whole sharedStrings.xml, and an .xlsx is a ZIP — a few-KB zip-bomb whose
# sharedStrings decompresses to GBs would OOM the resident index process (a
# cross-session DoS) before any render cap applies. A real config table is well under
# this; reject larger files loudly rather than risk the OOM. Also bounds the zip-bomb
# decompression via the declared-uncompressed-size sum (see _check_zip_inflate).
MAX_FILE_BYTES = 64 * 1024 * 1024     # 64 MiB on-disk ceiling for a config table
MAX_UNCOMPRESSED_BYTES = 512 * 1024 * 1024  # 512 MiB total inflate ceiling (zip-bomb guard)

# Extensions we know how to parse. read_file already handles plain text; this tool
# is for the structured/binary ones it can't.
CSV_EXT = (".csv",)
TSV_EXT = (".tsv",)
EXCEL_EXT = (".xlsx", ".xlsm", ".xltx", ".xltm")  # openpyxl reads the OOXML family
SQLITE_EXT = (".db", ".sqlite", ".sqlite3")


def _clip(s: Any) -> str:
    t = "" if s is None else str(s)
    # Flatten newlines/CR inside a cell: a quoted CSV cell (or an Excel cell) can hold
    # an embedded newline (game configs do this in description/dialogue columns). Left
    # raw, it would split one record across multiple physical output lines in the
    # pipe-delimited block → the reader sees phantom rows + misaligned columns
    # (cross-review). Replace with a visible \n marker so the cell stays one line.
    t = t.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n")
    return t[:MAX_CELL]


def _rows_to_text(rows: list[list[Any]], *, label: str, has_header: bool = True) -> tuple[str, bool]:
    """Render rows as a compact pipe-delimited block. Returns (text, truncated).

    MAX_ROWS bounds the DATA rows, not the header: callers pass [header, ...data], so
    counting the header against MAX_ROWS dropped the MAX_ROWS-th data row AND falsely
    flagged TRUNCATED on a table with exactly MAX_ROWS data rows (cross-review). With
    has_header, the cap is header + MAX_ROWS data."""
    truncated = False
    limit = MAX_ROWS + 1 if has_header else MAX_ROWS  # +1 reserves the header line
    if len(rows) > limit:
        rows = rows[:limit]
        truncated = True
    out_lines = []
    for r in rows:
        cells = list(r)[:MAX_COLS]
        if len(r) > MAX_COLS:
            truncated = True
        out_lines.append(" | ".join(_clip(c) for c in cells))
    body = "\n".join(out_lines)
    # Report DATA-row count (exclude the header) so "(N row(s))" matches what a planner
    # would count, and TRUNCATED means "more DATA rows exist".
    n_data = len(rows) - 1 if (has_header and rows) else len(rows)
    header = f"### {label} ({n_data} row(s){' — TRUNCATED' if truncated else ''})"
    return f"{header}\n{body}", truncated


def _read_csv(local_path: str, *, delimiter: str) -> tuple[str, bool]:
    # Decode via decode_bytes (BOM / UTF-8 / GB18030) — a Chinese config CSV is very often
    # GBK/GB2312, which the old hardcoded utf-8+replace returned as mojibake (every name
    # column garbled → the planner's actual data is unusable; cross-review HIGH). Read the
    # bytes (already byte-capped upstream at MAX_FILE_BYTES) then parse from a StringIO.
    with open(local_path, "rb") as fh:
        raw = fh.read()
    text, _enc = decode_bytes(raw)
    # Raise the csv field-size limit to the file's byte ceiling so a single legitimately
    # large quoted cell (a long localized description/dialogue blob — exactly what game
    # config columns hold) doesn't make the WHOLE table unreadable. It's bounded by
    # MAX_FILE_BYTES (64 MiB) upstream, and _clip trims each cell to 200 chars anyway, so
    # this can't blow memory (cross-review LOW). Save/restore so we don't perturb global state.
    prev_limit = csv.field_size_limit()
    try:
        csv.field_size_limit(MAX_FILE_BYTES)
        reader = csv.reader(io.StringIO(text, newline=""), delimiter=delimiter)
        rows = []
        try:
            for i, row in enumerate(reader):
                # Clip columns AT READ TIME: a pathological CSV that's one physical
                # line with millions of tiny fields would otherwise materialize a
                # huge list per row before _rows_to_text clips it → memory DoS in the
                # resident index process. Keep only MAX_COLS+1 (the +1 flags "wide").
                rows.append(row[:MAX_COLS + 1])
                # Read header + (MAX_ROWS+1) data rows: the extra data row lets
                # _rows_to_text detect "more than MAX_ROWS data" and flag TRUNCATED
                # without dropping a legitimate MAX_ROWS-th row (cross-review).
                if i >= MAX_ROWS + 1:
                    break
        except csv.Error as e:
            # A malformed CSV (e.g. NUL bytes) can still trip csv — surface a clean error,
            # not a raw csv.Error traceback.
            raise ValueError(f"CSV parse error: {e}") from e
    finally:
        csv.field_size_limit(prev_limit)
    return _rows_to_text(rows, label="sheet")


def _check_zip_inflate(local_path: str) -> None:
    """Reject an .xlsx (OOXML = a ZIP) whose entries inflate past the ceiling.

    The on-disk MAX_FILE_BYTES check bounds the COMPRESSED size; a zip-bomb is a
    few-KB file whose sharedStrings.xml decompresses to GBs. openpyxl(read_only)
    eagerly loads sharedStrings, so check the declared uncompressed sizes from the
    central directory BEFORE handing the path to openpyxl. We read sizes from the
    directory (no decompression) so this itself can't be bombed."""
    import zipfile  # noqa: PLC0415

    try:
        with zipfile.ZipFile(local_path) as zf:
            total = sum(zi.file_size for zi in zf.infolist())
    except zipfile.BadZipFile as exc:
        raise ValueError("not a valid .xlsx workbook (corrupt or not OOXML)") from exc
    if total > MAX_UNCOMPRESSED_BYTES:
        raise ValueError(
            f"workbook contents exceed the {MAX_UNCOMPRESSED_BYTES // (1024 * 1024)} MiB "
            f"decompression limit (possible zip-bomb); refusing to parse"
        )


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
    _check_zip_inflate(local_path)  # zip-bomb guard: reject if entries inflate past the ceiling
    wb = openpyxl.load_workbook(local_path, read_only=True, data_only=True)
    cap = MAX_ROWS + 2  # header + (MAX_ROWS+1) data rows (see _rows_to_text truncation)
    try:
        blocks, truncated = [], False
        saw_blank_in_data = False
        for ws in wb.worksheets:
            rows = []
            for i, row in enumerate(ws.iter_rows(values_only=True)):
                cells = list(row)
                rows.append(cells)
                # A None cell amid non-empty neighbours is the FORMULA-WITHOUT-CACHED-
                # VALUE case: data_only returns None for a formula cell that Excel never
                # computed+cached (e.g. a script-generated .xlsx). Flag it so we can do a
                # one-shot formula-recovery pass below — else the cell silently vanishes
                # and a planner sees "(empty)" where a formula lives (cross-review P0).
                if i > 0 and any(c is None for c in cells) and any(c is not None for c in cells):
                    saw_blank_in_data = True
                if i >= cap - 1:
                    break
            block, t = _rows_to_text(rows, label=f"sheet '{ws.title}'")
            blocks.append((ws.title, rows, block))
            truncated = truncated or t
        if not blocks:
            return "(workbook has no sheets)", False
        # Formula-recovery pass: only when a blank-amid-data cell was seen (cheap path
        # for the common all-cached workbook). Re-render any sheet whose cells we can
        # backfill from the formula view.
        if saw_blank_in_data:
            blocks = _recover_excel_formulas(openpyxl, local_path, blocks, cap)
        return "\n\n".join(b for _, _, b in blocks), truncated
    finally:
        wb.close()


def _recover_excel_formulas(openpyxl: Any, local_path: str, blocks: list, cap: int) -> list:
    """For sheets with None (uncached-formula) cells, overlay the formula string from a
    data_only=False read so a formula cell renders as e.g. `=A2*2` instead of vanishing.
    Best-effort: any failure leaves the value-pass block unchanged."""
    try:
        fwb = openpyxl.load_workbook(local_path, read_only=True, data_only=False)
    except Exception:  # noqa: BLE001 - recovery is best-effort; keep the value-pass output
        return blocks
    try:
        by_title = {ws.title: ws for ws in fwb.worksheets}
        out = []
        for title, rows, block in blocks:
            ws = by_title.get(title)
            if ws is None:
                out.append((title, rows, block))
                continue
            frows = []
            for i, row in enumerate(ws.iter_rows(values_only=True)):
                frows.append(list(row))
                if i >= cap - 1:
                    break
            # Overlay: where the value pass is None but the formula pass has content, use
            # the formula string (a str starting with '='); else keep the value.
            merged = []
            for r in range(len(rows)):
                vrow = rows[r]
                frow = frows[r] if r < len(frows) else []
                merged.append([
                    (f"{frow[c]} (未计算)" if (c < len(frow) and vrow[c] is None
                                              and isinstance(frow[c], str) and frow[c].startswith("="))
                     else vrow[c])
                    for c in range(len(vrow))
                ])
            new_block, _ = _rows_to_text(merged, label=f"sheet '{title}'")
            out.append((title, merged, new_block))
        return out
    finally:
        fwb.close()


def _read_sqlite(local_path: str) -> tuple[str, bool]:
    # READ-ONLY open: immutable=1 + mode=ro via URI so the tool can NEVER write/lock
    # the db (matches the read-only boundary). file: URI requires uri=True.
    # PERCENT-ENCODE the path: a repo file whose name contains '?' or '#' would
    # otherwise be mis-parsed as the start of the URI query/fragment, silently
    # opening the wrong file or failing with a confusing "no such table" (cross-review;
    # NOT an escape — '..' is already rejected upstream — but a correctness bug).
    # quote() keeps '/' so the absolute path stays intact; only special chars escape.
    uri = f"file:{urllib.parse.quote(local_path)}?mode=ro&immutable=1"
    try:
        con = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as exc:
        raise ValueError(f"not a valid SQLite database (corrupt or encrypted): {exc}") from exc
    try:
        cur = con.cursor()
        try:
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        except sqlite3.DatabaseError as exc:
            # A non-sqlite/corrupt/encrypted file opens fine but fails on first read
            # ("file is not a database"). Surface a clean, actionable ValueError (the
            # bridge passes ValueError detail through) instead of a generic "internal
            # error" the agent can't explain to the user (cross-review).
            raise ValueError(f"not a valid SQLite database (corrupt or encrypted): {exc}") from exc
        tables = [r[0] for r in cur.fetchall()]
        truncated = False
        if len(tables) > MAX_TABLES:
            tables = tables[:MAX_TABLES]
            truncated = True
        blocks = []
        for tbl in tables:
            # Identifier can't be parameterized; quote it to neutralize odd names.
            # LIMIT MAX_ROWS+2 data rows: _rows_to_text caps at header + MAX_ROWS data,
            # so fetching one extra lets it flag TRUNCATED without dropping a legitimate
            # MAX_ROWS-th data row (cross-review).
            q = f'SELECT * FROM "{tbl.replace(chr(34), chr(34) * 2)}" LIMIT {MAX_ROWS + 2}'
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


def read_table(requested: str, *, local_root: str, mount_root: str, repo: str = "") -> dict[str, Any]:
    """Parse a structured table/binary config file (Excel/CSV/TSV/SQLite) to text.

    ``requested`` is an agent-space path; it's confined to ``local_root`` first.
    Returns {"path", "kind", "content", "truncated"} with ``path`` in the agent's
    namespace. Raises ValueError on a bad/escaping path, a missing file, or an
    unsupported extension (so the bridge reports a clean, actionable error)."""
    t0 = perf_counter()
    local_path = path_align.to_local_path(requested, local_root=local_root, mount_root=mount_root, repo=repo)
    if not os.path.isfile(local_path):
        raise ValueError(f"not a readable file: {requested!r}")
    # Size ceiling BEFORE parsing: bounds the parse footprint (openpyxl/sqlite load
    # far more than the rendered output) and is a cheap first-line DoS guard.
    size = os.path.getsize(local_path)
    if size > MAX_FILE_BYTES:
        raise ValueError(
            f"file is {size // (1024 * 1024)} MiB, over the "
            f"{MAX_FILE_BYTES // (1024 * 1024)} MiB read_table limit; "
            f"a config table should be far smaller"
        )
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
            f"read_table does not handle '{ext}' files (supported: .xlsx/.xlsm/.xltx/.xltm, "
            f".csv, .tsv, .db/.sqlite/.sqlite3). The legacy binary .xls is NOT supported "
            f"(re-save as .xlsx). For plain-text files use read_file."
        )

    if len(content) > MAX_OUTPUT_CHARS:
        content = content[:MAX_OUTPUT_CHARS]
        truncated = True
    mount_path = path_align.to_container_path(local_path, index_root=os.path.realpath(local_root), mount_root=mount_root, repo=repo)
    logger.info(perf_entry("read_table", (perf_counter() - t0) * 1000, path=mount_path[:120],
                           kind=kind, truncated=truncated))
    return {"path": mount_path, "kind": kind, "content": content, "truncated": truncated}


def read_table_to_json(requested: str, *, local_root: str, mount_root: str, repo: str = "") -> str:
    """read_table → JSON string (the MCP tool return shape)."""
    return json.dumps(read_table(requested, local_root=local_root, mount_root=mount_root, repo=repo), ensure_ascii=False)
