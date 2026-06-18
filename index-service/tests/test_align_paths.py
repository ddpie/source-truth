"""Unit tests for http_bridge._align_paths — tool-aware path rewriting.

Pure function (no codegraph-server / network): rewrites every file-bearing field
of the 3 codegraph envelope shapes (symbol_search / get_callers / analyze_impact)
from index space into the container mount (/mnt/repo), nulls paths that escape the
repo root, and must NEVER crash on a malformed/partial envelope (best-effort:
return unchanged). The bridge is resident, so a crash here would break a query.
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
import http_bridge  # noqa: E402

ROOT = "/mnt/efs/repo"
MOUNT = "/mnt/repo"


def _align(tool, env):
    out = http_bridge._align_paths(json.dumps(env), tool, index_root=ROOT, mount_root=MOUNT)
    return json.loads(out)


# ── alignment works for each shape ──────────────────────────────────────────
def test_symbol_search_aligns_location_file():
    d = _align("codegraph_symbol_search",
               {"results": [{"symbol": {"location": {"file": f"{ROOT}/a.cs", "line": 3}}}]})
    assert d["results"][0]["symbol"]["location"]["file"] == f"{MOUNT}/a.cs"


def test_get_callers_aligns_both_symbol_and_call_site():
    d = _align("codegraph_get_callers",
               {"callers": [{"symbol": {"location": {"file": f"{ROOT}/b.cs"}},
                             "call_site": {"file": f"{ROOT}/c.cs"}}]})
    assert d["callers"][0]["symbol"]["location"]["file"] == f"{MOUNT}/b.cs"
    assert d["callers"][0]["call_site"]["file"] == f"{MOUNT}/c.cs"


def test_analyze_impact_aligns_all_impact_lists():
    d = _align("codegraph_analyze_impact",
               {"impacted": [{"path": f"{ROOT}/d.cs"}],
                "indirect_impacted": [{"path": f"{ROOT}/e.cs"}],
                "direct_impacted": [{"path": f"{ROOT}/f.cs"}]})
    assert d["impacted"][0]["path"] == f"{MOUNT}/d.cs"
    assert d["indirect_impacted"][0]["path"] == f"{MOUNT}/e.cs"
    assert d["direct_impacted"][0]["path"] == f"{MOUNT}/f.cs"


# ── escape paths are nulled, not leaked ─────────────────────────────────────
def test_escaping_absolute_path_is_nulled():
    d = _align("codegraph_symbol_search",
               {"results": [{"symbol": {"location": {"file": "/etc/passwd"}}}]})
    assert d["results"][0]["symbol"]["location"]["file"] is None


# ── malformed/partial envelopes must NOT crash (best-effort, return unchanged) ─
def test_null_symbol_does_not_crash():
    # The bug: item.get("symbol", {}) defaults a MISSING key, not a JSON-null
    # value, so {"symbol": null} would crash None.get("location").
    d = _align("codegraph_symbol_search", {"results": [{"symbol": None}]})
    assert d["results"][0]["symbol"] is None  # unchanged, no crash


def test_null_symbol_with_valid_call_site_still_aligns_call_site():
    d = _align("codegraph_get_callers",
               {"callers": [{"symbol": None, "call_site": {"file": f"{ROOT}/g.cs"}}]})
    assert d["callers"][0]["symbol"] is None
    assert d["callers"][0]["call_site"]["file"] == f"{MOUNT}/g.cs"


def test_non_dict_items_and_missing_keys_do_not_crash():
    assert _align("codegraph_symbol_search", {"results": [None, "x", 42, {}]})["results"] == [None, "x", 42, {}]
    assert _align("codegraph_analyze_impact", {"impacted": [None, {"no_path": 1}]})["impacted"] == [None, {"no_path": 1}]


def test_wrong_shape_returned_unchanged():
    # Unknown tool / missing container → unchanged, no crash.
    assert _align("codegraph_symbol_search", {"unexpected": 1}) == {"unexpected": 1}
    assert http_bridge._align_paths("not json", "codegraph_symbol_search",
                                    index_root=ROOT, mount_root=MOUNT) == "not json"
