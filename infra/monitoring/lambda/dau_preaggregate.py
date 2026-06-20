"""B-class DAU pre-aggregation Lambda (monitoring plan §2.A / 阶段1).

WHY this exists (plan 原则2): DAU = count_distinct(hashUserId) over a day is a B-class
metric — a real-time Logs-Insights dashboard widget doing it would re-scan raw logs on
every open (billed by bytes, 30-min query cap, regional concurrency cap) and still can't
express true cohort retention. Instead this runs ONCE/day on a schedule: StartQuery the
day's distinct-user count → poll GetQueryResults to Complete → PutMetricData a single
scalar into a custom metric (SourceTruth/Gateway DAU). The dashboard reads that cheap,
15-month-retained, pre-aggregated metric.

Contract (the parts that MUST be right, per the plan's 最小可执行规格):
  - StartQuery is ASYNC: poll GetQueryResults until status=Complete (bounded + backoff),
    never read results synchronously (would get empty data).
  - Time window + timezone: query a FULL local day [00:00, 24:00) for the TARGET date in
    the configured zone (default Asia/Tokyo, matching ops reality), not UTC, so day
    boundaries don't smear DAU. Default target = "yesterday" in that zone.
  - Empty result → PutMetricData 0 EXPLICITLY: a zero-activity day must show as 0, not a
    gap (a gap breaks the dashboard line + same-day-over-day math). B-class self-controls
    this (the A-class defaultValue:0 equivalent).
  - hashUserId is the user key (NOT traceId — the key-split, metrics.ts §4). saltWeak rows
    are still counted; the metric is tagged saltWeak when ANY counted row was weak-salted.

Packaging: pure stdlib + boto3 (present in the Lambda runtime) — no third-party deps, so
scripts/apply-dau-lambda.sh can zip this single file with no build step.

The query construction + result parsing + window math are factored into pure helpers so
they're unit-testable WITHOUT AWS (tests in index-service/tests or a dedicated suite call
build_query / parse_dau / compute_window with no boto3).
"""
from __future__ import annotations

import os
import time
from datetime import datetime, timedelta, timezone, date
from typing import Any

# The activity signal. event = "question_received" is emitted ONLY as a metric line
# (metrics.ts), so filtering on it needs no boolean `metric = 1` match — which in
# Logs-Insights is itself fragile (the field is a JSON boolean true, and `= 1` / `= true`
# matching is the same trap the metric-filters hit). event-name alone is the robust signal.
_QUERY_TEMPLATE = (
    'fields hashUserId, saltWeak\n'
    '| filter event = "question_received"\n'
    '| stats count_distinct(hashUserId) as dau, sum(saltWeak) as weak_rows'
)

NAMESPACE = "SourceTruth/Gateway"
METRIC_NAME = "DAU"


def build_query() -> str:
    """The Logs-Insights query string. Pure."""
    return _QUERY_TEMPLATE


def _zone_offset_seconds(tz_name: str, when_utc: datetime) -> int:
    """Resolve a fixed UTC offset (seconds) for a timezone name. Uses zoneinfo when
    available (handles DST for the given instant); falls back to a small built-in table
    for the common ops zones so the Lambda works even on a runtime without tzdata. Asia/
    Tokyo has no DST (always +9), so the fallback is exact for the default."""
    try:
        from zoneinfo import ZoneInfo  # py3.9+
        off = when_utc.replace(tzinfo=timezone.utc).astimezone(ZoneInfo(tz_name)).utcoffset()
        if off is not None:
            return int(off.total_seconds())
    except Exception:  # noqa: BLE001 - fall back to the static table
        pass
    static = {"Asia/Tokyo": 9 * 3600, "UTC": 0, "Asia/Shanghai": 8 * 3600,
              "America/Los_Angeles": -8 * 3600, "America/New_York": -5 * 3600}
    return static.get(tz_name, 0)


def compute_window(target: date, tz_name: str, now_utc: datetime) -> tuple[int, int]:
    """[start, end) unix-second bounds of the FULL local day `target` in `tz_name`.
    Pure (now_utc only used to resolve the zone's offset for that instant). end is the
    next local midnight, so the window is exactly 24h of local time."""
    offset = _zone_offset_seconds(tz_name, now_utc)
    # local midnight of `target` expressed as a UTC instant = target 00:00 minus the offset
    local_midnight = datetime(target.year, target.month, target.day, tzinfo=timezone.utc)
    start = int(local_midnight.timestamp()) - offset
    end = start + 24 * 3600
    return start, end


def parse_dau(results: list[list[dict[str, str]]]) -> tuple[int, int]:
    """Parse GetQueryResults' `results` into (dau, weak_rows). Insights returns a list of
    rows, each a list of {field,value}. The stats query yields at most one row. Empty
    results → (0, 0) (the explicit-zero contract). Pure."""
    if not results:
        return 0, 0
    row = {cell["field"]: cell["value"] for cell in results[0]}
    def _int(v: str | None) -> int:
        try:
            return int(float(v)) if v not in (None, "") else 0
        except (TypeError, ValueError):
            return 0
    return _int(row.get("dau")), _int(row.get("weak_rows"))


def handler(event: dict[str, Any] | None, context: Any = None) -> dict[str, Any]:
    """EventBridge-triggered entry. Env:
       LOG_GROUP (default /source-truth/bot-gateway), TZ_NAME (default Asia/Tokyo),
       TARGET_DATE (optional YYYY-MM-DD; default = yesterday in TZ_NAME),
       POLL_TIMEOUT_S (default 120), AWS region from the Lambda env.
    """
    import boto3  # imported here so the pure helpers above unit-test without boto3

    log_group = os.environ.get("LOG_GROUP", "/source-truth/bot-gateway")
    tz_name = os.environ.get("TZ_NAME", "Asia/Tokyo")
    poll_timeout = int(os.environ.get("POLL_TIMEOUT_S", "120"))
    now_utc = datetime.now(timezone.utc)

    # Target date: explicit override, else "yesterday" in the ops zone (local, not UTC).
    if os.environ.get("TARGET_DATE"):
        target = datetime.strptime(os.environ["TARGET_DATE"], "%Y-%m-%d").date()
    else:
        offset = _zone_offset_seconds(tz_name, now_utc)
        local_now = now_utc + timedelta(seconds=offset)
        target = (local_now.date() - timedelta(days=1))

    start, end = compute_window(target, tz_name, now_utc)
    logs = boto3.client("logs")
    cw = boto3.client("cloudwatch")

    qid = logs.start_query(logGroupName=log_group, startTime=start, endTime=end,
                           queryString=build_query())["queryId"]

    # Poll to Complete (bounded + linear backoff). StartQuery is async — reading early
    # yields empty/partial data.
    deadline = time.time() + poll_timeout
    status, results = "Running", []
    delay = 1.0
    while time.time() < deadline:
        resp = logs.get_query_results(queryId=qid)
        status = resp["status"]
        if status == "Complete":
            results = resp.get("results", [])
            break
        if status in ("Failed", "Cancelled", "Timeout"):
            raise RuntimeError(f"DAU Insights query {status} (queryId={qid})")
        time.sleep(min(delay, 5.0))
        delay += 1.0
    else:
        # Bounded-timeout: stop the query and fail loud (a silent partial put would be worse).
        try:
            logs.stop_query(queryId=qid)
        except Exception:  # noqa: BLE001
            pass
        raise TimeoutError(f"DAU Insights query did not complete within {poll_timeout}s (queryId={qid})")

    dau, weak_rows = parse_dau(results)

    # PutMetricData ALWAYS (even dau=0) — the explicit-zero contract. Timestamp at local
    # noon of the target day so the point lands unambiguously on that calendar day in the
    # dashboard regardless of viewer zone. saltWeak dimension flags a window whose de-
    # identification was weak (so downstream can treat that DAU as lower-trust).
    ts = datetime.fromtimestamp(start + 12 * 3600, tz=timezone.utc)
    cw.put_metric_data(Namespace=NAMESPACE, MetricData=[{
        "MetricName": METRIC_NAME,
        "Timestamp": ts,
        "Value": float(dau),
        "Unit": "Count",
        "Dimensions": [{"Name": "saltWeak", "Value": "true" if weak_rows > 0 else "false"}],
    }])
    return {"date": target.isoformat(), "dau": dau, "weakRows": weak_rows,
            "window": [start, end], "queryId": qid}
