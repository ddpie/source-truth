#!/usr/bin/env python3
"""render_metric_filters.py — turn the A-class metric-filter definitions into a
concrete put-metric-filter plan.

Pure + side-effect free: reads the JSON definition file, validates each entry
against the CloudWatch metric-filter contract, and emits ONE JSON object per
filter on stdout (NDJSON) describing the exact `aws logs put-metric-filter`
arguments. The bash wrapper (apply-metric-filters.sh) consumes this and either
prints it (--dry-run) or calls the AWS CLI. Keeping the rendering here makes it
unit-testable offline (no AWS, no bash quoting games).

Usage:
    render_metric_filters.py <defs.json> <log_group> [--namespace NS]

Exit non-zero with a clear message on ANY contract violation — a bad definition
must fail the deploy loudly, not create a silently-wrong metric.
"""
import json
import sys


# The CloudWatch metricTransformation contract we enforce (mirrors the JSON _doc):
#   - name, event, filterPattern, metricValue are required.
#   - defaultValue and dimensions are MUTUALLY EXCLUSIVE (CloudWatch rejects both;
#     a dimensioned metric is inherently sparse).
#   - a counter (metricValue == "1") with no dimensions SHOULD set defaultValue:0
#     so it is dense and alarmable — we warn (to stderr) if it doesn't, but don't fail.
def render(defs: dict, log_group: str, namespace_override: str | None = None):
    namespace = namespace_override or defs.get("metricNamespace")
    if not namespace:
        raise ValueError("metricNamespace missing (not in defs and no --namespace given)")
    if not log_group:
        raise ValueError("log_group is required")

    metrics = defs.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        raise ValueError("defs.metrics must be a non-empty array")

    seen_names = set()
    plans = []
    warnings = []
    for i, m in enumerate(metrics):
        where = f"metrics[{i}]" + (f" ({m.get('name')})" if isinstance(m, dict) else "")
        if not isinstance(m, dict):
            raise ValueError(f"{where}: not an object")
        for req in ("name", "event", "filterPattern", "metricValue"):
            if not m.get(req):
                raise ValueError(f"{where}: missing required field '{req}'")

        name = m["name"]
        if name in seen_names:
            raise ValueError(f"{where}: duplicate metric name '{name}'")
        seen_names.add(name)

        has_default = "defaultValue" in m
        dims = m.get("dimensions")
        if dims is not None and not isinstance(dims, dict):
            raise ValueError(f"{where}: 'dimensions' must be an object")

        # HARD constraint: CloudWatch forbids defaultValue + dimensions together.
        if has_default and dims:
            raise ValueError(
                f"{where}: sets BOTH defaultValue and dimensions — CloudWatch rejects this "
                f"(a dimensioned metric is inherently sparse). Drop defaultValue, or add a "
                f"dedicated dense per-dimension-value filter for alarming (plan 阶段3)."
            )

        # Soft guidance: a plain counter with no defaultValue is sparse → alarms flap.
        is_counter = str(m["metricValue"]) == "1"
        if is_counter and not dims and not has_default:
            warnings.append(
                f"{name}: counter without defaultValue:0 → metric will be SPARSE (alarms may "
                f"sit in INSUFFICIENT_DATA). Add defaultValue:0 unless this is intentional."
            )

        transform = {
            "metricName": name,
            "metricNamespace": namespace,
            "metricValue": str(m["metricValue"]),
        }
        if m.get("unit"):
            transform["unit"] = m["unit"]
        if has_default:
            # Keep it numeric (CloudWatch wants a number, not a string).
            transform["defaultValue"] = m["defaultValue"]
        if dims:
            transform["dimensions"] = dims

        plans.append({
            # filter name == metric name (one filter per metric here); stable so re-runs upsert.
            "filterName": name,
            "logGroupName": log_group,
            "filterPattern": m["filterPattern"],
            "metricTransformations": [transform],
        })

    return plans, warnings


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    namespace_override = None
    for a in argv[1:]:
        if a.startswith("--namespace="):
            namespace_override = a.split("=", 1)[1]
    if len(args) < 2:
        sys.stderr.write("usage: render_metric_filters.py <defs.json> <log_group> [--namespace=NS]\n")
        return 2
    defs_path, log_group = args[0], args[1]
    try:
        with open(defs_path, encoding="utf-8") as f:
            defs = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"render_metric_filters: cannot read/parse {defs_path}: {e}\n")
        return 1
    try:
        plans, warnings = render(defs, log_group, namespace_override)
    except ValueError as e:
        sys.stderr.write(f"render_metric_filters: INVALID definition: {e}\n")
        return 1
    for w in warnings:
        sys.stderr.write(f"render_metric_filters: WARN {w}\n")
    for p in plans:
        sys.stdout.write(json.dumps(p, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
