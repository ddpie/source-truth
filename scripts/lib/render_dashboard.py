#!/usr/bin/env python3
"""render_dashboard.py — render a CloudWatch dashboard TEMPLATE into a concrete
put-dashboard body.

Pure + side-effect free: reads a dashboard template JSON (with ${REGION} /
${NAMESPACE} / ${ACCOUNT_ID} placeholders and a leading `_doc` array), substitutes
the placeholders, strips documentation keys, and ENFORCES the plan's hard
constraints before emitting the body on stdout:

  - every widget MUST be a metric/text widget — NO type:"log" (Logs-Insights)
    widgets, which re-scan raw logs on every dashboard open (billed by bytes +
    regional concurrency cap; plan 原则2 / 阶段2 hard constraint);
  - no unresolved ${...} placeholder may remain in the output.

A violation raises ValueError → the wrapper aborts before any put-dashboard call.

Usage:
    render_dashboard.py <template.json> --region <r> --namespace <ns> [--account-id <id>]
"""
import json
import re
import sys

# Substitution targets these exact placeholder names; the LEFTOVER detector is
# deliberately BROADER (`${...anything...}`) so a typo'd placeholder like ${Region}
# or ${ACCOUNT-ID} is caught as unresolved rather than silently surviving into the
# rendered body (CloudWatch would then show a literal "${Region}").
SUBSTITUTABLE = ("REGION", "NAMESPACE", "ACCOUNT_ID")
PLACEHOLDER_RE = re.compile(r"\$\{[^}]+\}")
# Widget types we allow. "log" (Logs-Insights query widget) is deliberately BANNED.
ALLOWED_WIDGET_TYPES = {"metric", "text", "alarm"}


def render(template: dict, subs: dict):
    if not isinstance(template, dict):
        raise ValueError("template must be a JSON object")
    widgets = template.get("widgets")
    if not isinstance(widgets, list) or not widgets:
        raise ValueError("template.widgets must be a non-empty array")

    # Enforce widget-type constraint BEFORE substitution (structure is the same).
    for i, w in enumerate(widgets):
        if not isinstance(w, dict):
            raise ValueError(f"widgets[{i}]: not an object")
        wtype = w.get("type")
        if wtype not in ALLOWED_WIDGET_TYPES:
            raise ValueError(
                f"widgets[{i}]: type '{wtype}' not allowed — only {sorted(ALLOWED_WIDGET_TYPES)}. "
                f"type:'log' (Logs-Insights query widget) is BANNED: it re-scans raw logs on every "
                f"open (cost + concurrency cap; plan 原则2 / 阶段2)."
            )

    # Build the put-dashboard body: drop doc-only keys (anything starting with "_").
    body = {k: v for k, v in template.items() if not k.startswith("_")}

    # Substitute placeholders by serializing → string-replace → reparse. Substituting
    # on the JSON TEXT (not walking the tree) covers placeholders nested anywhere
    # (titles, expressions, SEARCH() strings) uniformly. CRITICAL: JSON-escape each
    # value before injecting it into the serialized text — a value containing a quote
    # or backslash would otherwise corrupt the JSON (we substitute INTO a string
    # context, so the value must be escaped exactly as JSON would escape it). We strip
    # the surrounding quotes json.dumps adds, since the placeholder already sits inside
    # the surrounding "...".
    text = json.dumps(body, ensure_ascii=False)
    for key in SUBSTITUTABLE:
        val = subs.get(key)
        if val is None:
            continue
        escaped = json.dumps(str(val), ensure_ascii=False)[1:-1]
        text = text.replace("${" + key + "}", escaped)

    # No unresolved placeholder may survive (e.g. ${ACCOUNT_ID} used but not provided).
    leftover = PLACEHOLDER_RE.findall(text)
    if leftover:
        raise ValueError(
            f"unresolved placeholder(s) in rendered dashboard: {sorted(set(leftover))} "
            f"— pass the matching --region / --namespace / --account-id"
        )

    # Reparse to guarantee the result is still valid JSON after substitution.
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"rendered dashboard is not valid JSON after substitution: {e}")


def main(argv):
    positional = []
    opts = {"region": None, "namespace": None, "account-id": None}
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
            else:
                if name in opts and i + 1 < len(argv):
                    opts[name] = argv[i + 1]
                    i += 2
                else:
                    i += 1
        else:
            positional.append(a)
            i += 1

    if not positional:
        sys.stderr.write("usage: render_dashboard.py <template.json> --region <r> --namespace <ns> [--account-id <id>]\n")
        return 2
    if not opts["region"] or not opts["namespace"]:
        sys.stderr.write("render_dashboard: --region and --namespace are required\n")
        return 2

    try:
        with open(positional[0], encoding="utf-8") as f:
            template = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"render_dashboard: cannot read/parse {positional[0]}: {e}\n")
        return 1

    subs = {"REGION": opts["region"], "NAMESPACE": opts["namespace"], "ACCOUNT_ID": opts["account-id"]}
    try:
        body = render(template, subs)
    except ValueError as e:
        sys.stderr.write(f"render_dashboard: INVALID template: {e}\n")
        return 1

    sys.stdout.write(json.dumps(body, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
