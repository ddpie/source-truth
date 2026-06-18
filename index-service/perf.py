"""Structured perf-log helper for the index-service.

One schema for every timing sample so the three-stage breakdown (model-gen vs
CodeGraph vs EFS read) can be reconstructed later with `grep '"perf":true' | jq`.
Emits the same stdout JSON shape the rest of the service logs in — no new
sink, no new dependency. Pair with ``time.perf_counter()`` at the call site::

    t0 = perf_counter()
    raw = await session.call_tool(tool_name, arguments)
    logger.info(perf_entry("codegraph_call", (perf_counter() - t0) * 1000,
                           tool=tool_name, ok=True))
"""

from __future__ import annotations

import json
from typing import Any


def perf_entry(event: str, latency_ms: float, **context: Any) -> str:
    """Build a perf-sample log line: event + latency_ms (0.1ms precision) + ctx.

    `perf: True` tags it so perf samples can be split from business events.
    """
    return json.dumps(
        {"event": event, "perf": True, "latency_ms": round(latency_ms, 1), **context}
    )
