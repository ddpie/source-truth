#!/usr/bin/env python3
"""render_alarms.py — turn config/alarm-thresholds.json into a put-metric-alarm plan.

Pure + side-effect free: reads the thresholds file, validates each alarm against the
CloudWatch put-metric-alarm contract, and emits ONE JSON object per alarm (NDJSON) on
stdout describing the exact arguments. The bash wrapper (apply-alarms.sh) consumes this
and either prints it (--dry-run) or calls the AWS CLI with the SNS topic ARN wired in.

Skips alarms with "enabled": false (a documented-but-not-yet-applicable alarm — e.g.
one awaiting a dense backing metric — without silently dropping it).

Usage:
    render_alarms.py <thresholds.json> --namespace <ns> [--prefix <p>] [--topic-arn <arn>]
"""
import json
import sys

VALID_COMPARISON = {
    "GreaterThanOrEqualToThreshold", "GreaterThanThreshold",
    "LessThanThreshold", "LessThanOrEqualToThreshold",
    "LessThanLowerOrGreaterThanUpperThreshold",
    "LessThanLowerThreshold", "GreaterThanUpperThreshold",
}
VALID_MISSING = {"notBreaching", "breaching", "ignore", "missing"}
VALID_STATISTIC = {"Sum", "Average", "Minimum", "Maximum", "SampleCount"}


def render(cfg: dict, namespace: str, prefix: str, topic_arn):
    if not namespace:
        raise ValueError("namespace is required")
    alarms = cfg.get("alarms")
    if not isinstance(alarms, list) or not alarms:
        raise ValueError("cfg.alarms must be a non-empty array")

    seen = set()
    plans = []
    skipped = []
    for i, a in enumerate(alarms):
        where = f"alarms[{i}]" + (f" ({a.get('name')})" if isinstance(a, dict) else "")
        if not isinstance(a, dict):
            raise ValueError(f"{where}: not an object")

        if a.get("enabled") is False:
            skipped.append(a.get("name", f"alarms[{i}]"))
            continue

        for req in ("name", "metricName", "statistic", "comparisonOperator", "threshold"):
            if req not in a or a[req] in (None, ""):
                raise ValueError(f"{where}: missing required field '{req}'")

        name = a["name"]
        if name in seen:
            raise ValueError(f"{where}: duplicate alarm name '{name}'")
        seen.add(name)

        if a["statistic"] not in VALID_STATISTIC:
            raise ValueError(f"{where}: statistic '{a['statistic']}' not in {sorted(VALID_STATISTIC)}")
        if a["comparisonOperator"] not in VALID_COMPARISON:
            raise ValueError(f"{where}: comparisonOperator '{a['comparisonOperator']}' invalid")
        missing = a.get("treatMissingData", "missing")
        if missing not in VALID_MISSING:
            raise ValueError(f"{where}: treatMissingData '{missing}' not in {sorted(VALID_MISSING)}")

        if not isinstance(a["threshold"], (int, float)):
            raise ValueError(f"{where}: threshold must be a number")
        period = a.get("periodSeconds", 300)
        eval_periods = a.get("evaluationPeriods", 1)
        dp_to_alarm = a.get("datapointsToAlarm", eval_periods)
        for fld, val in (("periodSeconds", period), ("evaluationPeriods", eval_periods), ("datapointsToAlarm", dp_to_alarm)):
            if not isinstance(val, int) or val <= 0:
                raise ValueError(f"{where}: {fld} must be a positive integer")
        if dp_to_alarm > eval_periods:
            raise ValueError(f"{where}: datapointsToAlarm ({dp_to_alarm}) > evaluationPeriods ({eval_periods})")

        plan = {
            "alarmName": f"{prefix}-{name}" if prefix else name,
            "metricName": a["metricName"],
            "namespace": namespace,
            "statistic": a["statistic"],
            "period": period,
            "evaluationPeriods": eval_periods,
            "datapointsToAlarm": dp_to_alarm,
            "threshold": a["threshold"],
            "comparisonOperator": a["comparisonOperator"],
            "treatMissingData": missing,
            "alarmDescription": a.get("alarmDescription", ""),
            "severity": a.get("severity", "warning"),
        }
        # Wire the SNS topic into both alarm + ok actions when provided. Without a topic
        # the alarm is still created (visible on the dashboard) but pages no one — the
        # wrapper warns about that.
        if topic_arn:
            plan["alarmActions"] = [topic_arn]
            plan["okActions"] = [topic_arn]
        plans.append(plan)

    return plans, skipped


def main(argv):
    positional = []
    opts = {"namespace": None, "prefix": "source-truth", "topic-arn": None}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            name = a[2:]
            if "=" in name:
                k, v = name.split("=", 1)
                if k in opts:
                    opts[k] = v
                i += 1
            elif name in opts and i + 1 < len(argv):
                opts[name] = argv[i + 1]
                i += 2
            else:
                i += 1
        else:
            positional.append(a)
            i += 1

    if not positional:
        sys.stderr.write("usage: render_alarms.py <thresholds.json> --namespace <ns> [--prefix <p>] [--topic-arn <arn>]\n")
        return 2
    if not opts["namespace"]:
        sys.stderr.write("render_alarms: --namespace is required\n")
        return 2

    try:
        with open(positional[0], encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"render_alarms: cannot read/parse {positional[0]}: {e}\n")
        return 1

    try:
        plans, skipped = render(cfg, opts["namespace"], opts["prefix"], opts["topic-arn"])
    except ValueError as e:
        sys.stderr.write(f"render_alarms: INVALID alarm config: {e}\n")
        return 1

    for s in skipped:
        sys.stderr.write(f"render_alarms: SKIP disabled alarm '{s}'\n")
    for p in plans:
        sys.stdout.write(json.dumps(p, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
