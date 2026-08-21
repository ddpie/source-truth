#!/usr/bin/env python3
"""Validate that every IAM policy document embedded in the deploy scripts is legal.

Catches two mistakes that only surface as a MalformedPolicyDocument at deploy time, long
after the phases that cost real minutes:
  - invalid JSON after shell expansion
  - keys IAM does not accept inside a Statement (a "_comment" key is rejected outright)

Run: python3 scripts/tests/validate_iam_policies.py
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ACCOUNT = "111122223333"
REGION = "us-east-1"
ROLE = "source-truth-index-role"

LEGAL_KEYS = {
    "Sid", "Effect", "Action", "NotAction", "Resource", "NotResource",
    "Condition", "Principal", "NotPrincipal",
}

REPO = pathlib.Path(__file__).resolve().parents[2]
FILES = ["scripts/lib/create-iam.sh", "scripts/lib/provision_iam.sh"]

DOC_RE = re.compile(r"--policy-name (\S+) --policy-document ('.*?'|\".*?\")\s*>", re.S)


def expand(raw: str) -> str:
    """Approximate the shell expansion these documents undergo."""
    raw = raw[1:-1]  # strip the outer quote
    raw = raw.replace("'\"${ACCOUNT}\"'", ACCOUNT)
    raw = raw.replace("${ACCOUNT}", ACCOUNT)
    raw = raw.replace("${REGION}", REGION)
    raw = raw.replace("${ROLE}", ROLE)
    raw = raw.replace('\\"', '"')
    return raw


def main() -> int:
    failures = 0
    checked = 0
    for rel in FILES:
        src = (REPO / rel).read_text()
        for name, doc in DOC_RE.findall(src):
            checked += 1
            try:
                parsed = json.loads(expand(doc))
            except json.JSONDecodeError as exc:
                print(f"  FAIL {rel} :: {name}: invalid JSON — {exc}")
                failures += 1
                continue

            statements = parsed.get("Statement")
            if not isinstance(statements, list) or not statements:
                print(f"  FAIL {rel} :: {name}: Statement must be a non-empty list")
                failures += 1
                continue

            for i, st in enumerate(statements):
                illegal = sorted(set(st) - LEGAL_KEYS)
                if illegal:
                    print(f"  FAIL {rel} :: {name}[{i}]: illegal statement keys {illegal}")
                    failures += 1
                if "Effect" not in st or "Action" not in st:
                    print(f"  FAIL {rel} :: {name}[{i}]: missing Effect or Action")
                    failures += 1

            # Privilege-escalation guards. iam:PassRole on "*" next to lambda:CreateFunction is a
            # full account escalation chain; an unconditioned iam:AttachRolePolicy scoped to a
            # pattern that includes the role itself is self-escalation to admin.
            for i, st in enumerate(statements):
                actions = st.get("Action")
                actions = actions if isinstance(actions, list) else [actions]
                actions = [a for a in actions if isinstance(a, str)]
                resources = st.get("Resource")
                resources = resources if isinstance(resources, list) else [resources]

                if any(a == "iam:PassRole" for a in actions):
                    if "*" in resources:
                        print(f"  FAIL {rel} :: {name}[{i}]: iam:PassRole on Resource '*'")
                        failures += 1
                    if not st.get("Condition"):
                        print(f"  FAIL {rel} :: {name}[{i}]: iam:PassRole without a Condition")
                        failures += 1

                if any(a == "iam:AttachRolePolicy" for a in actions):
                    cond = json.dumps(st.get("Condition") or {})
                    if "iam:PolicyARN" not in cond:
                        print(f"  FAIL {rel} :: {name}[{i}]: iam:AttachRolePolicy without an iam:PolicyARN condition")
                        failures += 1

                if any(a == "iam:CreateServiceLinkedRole" for a in actions):
                    cond = json.dumps(st.get("Condition") or {})
                    if "iam:AWSServiceName" not in cond:
                        print(f"  FAIL {rel} :: {name}[{i}]: iam:CreateServiceLinkedRole without an iam:AWSServiceName condition")
                        failures += 1

    if failures:
        print(f"iam-policies: {failures} problem(s) across {checked} document(s)")
        return 1
    print(f"iam-policies: OK ({checked} documents)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
