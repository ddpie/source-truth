"""Unit tests for _parse_symbol_location — the null-safe symbol→(uri,line) parse.

get_callers/analyze_impact resolve their query through symbol_search, and this
parse is the ONLY symbol-resolution path. A real partial codegraph hit can be
`{"symbol": null}` (or a non-dict); the parse must treat any unusable shape as a
clean ValueError ("symbol not found") rather than letting an AttributeError fall
to the generic handler and mislabel it as an internal "{tool} failed". Pure — no
codegraph-server/network needed.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

pytest.importorskip("mcp")  # http_bridge imports mcp at module load

from http_bridge import _parse_symbol_location  # noqa: E402


def test_resolves_a_well_formed_top_hit():
    raw = json.dumps({"results": [{"symbol": {"location": {"file": "/idx/a.py", "line": 12}}}]})
    uri, line = _parse_symbol_location(raw, "foo")
    assert uri == "file:///idx/a.py"
    assert line == 12


def test_null_symbol_is_a_clean_no_match_not_a_crash():
    # The exact shape the hardening guards: `{"symbol": null}`. Must raise
    # ValueError (→ "symbol not found"), NOT AttributeError (→ "{tool} failed").
    raw = json.dumps({"results": [{"symbol": None}]})
    with pytest.raises(ValueError):
        _parse_symbol_location(raw, "foo")


def test_non_dict_top_hit_is_a_clean_no_match():
    raw = json.dumps({"results": ["not-a-dict"]})
    with pytest.raises(ValueError):
        _parse_symbol_location(raw, "foo")


def test_missing_location_or_line_is_a_clean_no_match():
    for payload in (
        {"results": [{"symbol": {}}]},                                  # no location
        {"results": [{"symbol": {"location": {"file": "/idx/a.py"}}}]}, # no line
        {"results": [{"symbol": {"location": {"line": 3}}}]},           # no file
        {"results": [{"symbol": {"location": {"file": "/idx/a.py", "line": "x"}}}]},  # line not int
    ):
        with pytest.raises(ValueError):
            _parse_symbol_location(json.dumps(payload), "foo")


def test_empty_or_missing_results_is_a_clean_no_match():
    for payload in ({"results": []}, {}, {"results": None}):
        with pytest.raises(ValueError):
            _parse_symbol_location(json.dumps(payload), "foo")
