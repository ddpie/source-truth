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

# Every shell file that embeds an IAM document. apply-dau-lambda.sh was MISSING from this list
# while carrying a real put-role-policy with the same hand-escaped construction — the validator
# had the exact blind spot it exists to catch. discover_policy_files() below fails the run if a
# file with a policy document is not listed here, so the next one cannot be missed either.
FILES = [
    "scripts/lib/create-iam.sh",
    "scripts/lib/provision_iam.sh",
    "scripts/lib/apply-dau-lambda.sh",
]

# Inline policies AND trust policies. Trust policies were invisible before: a malformed one fails
# create-role on a fresh account just as late and as expensively, and a valid-but-wrong Principal
# is a cross-account trust bug worth surfacing.
DOC_RE = re.compile(
    r"--(?:policy-name (\S+) --policy-document|(assume-role-policy-document)) ('.*?'|\".*?\")\s*>",
    re.S,
)

# Variables deliberately left symbolic inside a JSON string. Anything else surviving expansion
# means the validator checked a document that is not what deploys.
ALLOWED_UNEXPANDED: set[str] = set()


def expand(raw: str) -> str:
    """Approximate the shell expansion these documents undergo."""
    raw = raw[1:-1]  # strip the outer quote
    raw = raw.replace("'\"${ACCOUNT}\"'", ACCOUNT)
    for name, value in (
        ("ACCOUNT", ACCOUNT),
        ("REGION", REGION),
        ("ROLE", ROLE),
        ("INDEX_ROLE", ROLE),
        ("RUNTIME_ROLE", "SourceTruthAgentRuntimeRole"),
        ("BUCKET", "source-truth-repo-111122223333-useast1"),
        ("LG_ARN", f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/source-truth/bot-gateway:*"),
    ):
        raw = raw.replace("${" + name + "}", value).replace("$" + name, value)
    raw = raw.replace('\\"', '"')
    return raw


def discover_policy_files() -> list[str]:
    """Every file under scripts/ that embeds an IAM document, so FILES cannot fall behind."""
    found = []
    for path in sorted(REPO.glob("scripts/**/*.sh")):
        text = path.read_text(errors="ignore")
        if "--policy-document" in text or "--assume-role-policy-document" in text:
            found.append(str(path.relative_to(REPO)))
    return found


def check_trust_policy(where: str, parsed: dict) -> int:
    """A trust policy must name a service principal and must not trust the world."""
    failures = 0
    for i, st in enumerate(parsed.get("Statement", [])):
        principal = st.get("Principal")
        if not isinstance(principal, dict) or not principal.get("Service"):
            print(f"  FAIL {where}[{i}]: trust policy without a Principal.Service")
            failures += 1
        if isinstance(principal, dict) and principal.get("AWS") == "*":
            print(f"  FAIL {where}[{i}]: trust policy allows Principal AWS '*'")
            failures += 1
        actions = st.get("Action")
        actions = actions if isinstance(actions, list) else [actions]
        if "sts:AssumeRole" not in actions and "sts:AssumeRoleWithWebIdentity" not in actions:
            print(f"  FAIL {where}[{i}]: trust policy Action is not an AssumeRole verb: {actions}")
            failures += 1
    return failures


def main() -> int:
    failures = 0
    checked = 0

    # A file carrying an IAM document but absent from FILES would be validated by nothing.
    missing = [f for f in discover_policy_files() if f not in FILES]
    if missing:
        for f in missing:
            print(f"  FAIL {f}: embeds an IAM document but is not listed in FILES")
        failures += len(missing)

    for rel in FILES:
        src = (REPO / rel).read_text()
        for name, is_trust, doc in DOC_RE.findall(src):
            label = name or "assume-role-policy"
            checked += 1
            expanded = expand(doc)

            # An unexpanded variable means we parsed something other than what deploys.
            leftover = set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", expanded)) - ALLOWED_UNEXPANDED
            if leftover:
                print(f"  FAIL {rel} :: {label}: unexpanded variable(s) {sorted(leftover)} — extend expand()")
                failures += 1

            try:
                parsed = json.loads(expanded)
            except json.JSONDecodeError as exc:
                print(f"  FAIL {rel} :: {label}: invalid JSON — {exc}")
                failures += 1
                continue

            statements = parsed.get("Statement")
            if not isinstance(statements, list) or not statements:
                print(f"  FAIL {rel} :: {label}: Statement must be a non-empty list")
                failures += 1
                continue

            if is_trust:
                failures += check_trust_policy(f"{rel} :: {label}", parsed)
                continue

            for i, st in enumerate(statements):
                illegal = sorted(set(st) - LEGAL_KEYS)
                if illegal:
                    print(f"  FAIL {rel} :: {label}[{i}]: illegal statement keys {illegal}")
                    failures += 1
                if "Effect" not in st or "Action" not in st:
                    print(f"  FAIL {rel} :: {label}[{i}]: missing Effect or Action")
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
                        print(f"  FAIL {rel} :: {label}[{i}]: iam:PassRole on Resource '*'")
                        failures += 1
                    if not st.get("Condition"):
                        print(f"  FAIL {rel} :: {label}[{i}]: iam:PassRole without a Condition")
                        failures += 1

                if any(a == "iam:AttachRolePolicy" for a in actions):
                    cond = json.dumps(st.get("Condition") or {})
                    if "iam:PolicyARN" not in cond:
                        print(f"  FAIL {rel} :: {label}[{i}]: iam:AttachRolePolicy without an iam:PolicyARN condition")
                        failures += 1

                if any(a == "iam:CreateServiceLinkedRole" for a in actions):
                    cond = json.dumps(st.get("Condition") or {})
                    if "iam:AWSServiceName" not in cond:
                        print(f"  FAIL {rel} :: {label}[{i}]: iam:CreateServiceLinkedRole without an iam:AWSServiceName condition")
                        failures += 1

    if failures:
        print(f"iam-policies: {failures} problem(s) across {checked} document(s)")
        return 1
    print(f"iam-policies: OK ({checked} documents)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
