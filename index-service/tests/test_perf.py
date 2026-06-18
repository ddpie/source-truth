"""Unit tests for the perf-log helper (perf.py).

Timing the actual codegraph call is I/O and covered by integration; the part
worth unit-testing is the structured-log entry: stable shape, latency rounded
to a sane precision, and arbitrary context fields passed through. Keeping the
gateway/bridge perf events on one schema (event + latency_ms + context) is what
lets `grep | jq` add up the three-stage breakdown later.
"""

import json
import sys
from pathlib import Path

# perf.py lives in index-service/ (parent of tests/); make it importable
# regardless of pytest's cwd/rootdir (mirrors the sibling test modules).
SVC_DIR = Path(__file__).resolve().parent.parent
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

from perf import perf_entry  # noqa: E402


def test_perf_entry_has_event_and_rounded_latency():
    out = json.loads(perf_entry("codegraph_call", 12.3456))
    assert out["event"] == "codegraph_call"
    # Rounded to 0.1ms — sub-100µs jitter is noise for this analysis.
    assert out["latency_ms"] == 12.3
    # Marked as a perf sample so it can be split from business-event logs.
    assert out["perf"] is True


def test_perf_entry_passes_context_fields_through():
    out = json.loads(perf_entry("codegraph_call", 5.0, tool="codegraph_symbol_search", ok=False))
    assert out["tool"] == "codegraph_symbol_search"
    assert out["ok"] is False


def test_perf_entry_latency_is_a_number_not_string():
    out = json.loads(perf_entry("tool_call", 0.04))
    assert isinstance(out["latency_ms"], (int, float))
    # A sub-0.1ms call still records a non-negative number, not a dropped field.
    assert out["latency_ms"] >= 0
