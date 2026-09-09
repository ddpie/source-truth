#!/usr/bin/env python3
"""Regenerate the Python license table from exact installed distribution metadata.

Run in an environment synced to agent-container/requirements.lock. --check
verifies the generated table without writing the manifest.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def lock_pins(path: Path) -> dict[str, str]:
    """Reject partial/ambiguous inventories instead of silently omitting rows."""
    pins = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"([\w.-]+)==([A-Za-z0-9.!+_-]+)", line)
        if not match:
            raise ValueError(f"{path}:{number}: expected an exact name==version pin")
        name = re.sub(r"[-_.]+", "-", match[1]).lower()
        if name in pins:
            raise ValueError(f"{path}:{number}: duplicate package {name}")
        pins[name] = match[2]
    if not pins:
        raise ValueError(f"{path}: empty lock")
    return pins


def render_manifest(text: str) -> str:
    pins = lock_pins(ROOT / "agent-container/requirements.lock")
    glossary = lock_pins(ROOT / "index-service/glossary-requirements.lock")
    if any(pins.get(name) != version for name, version in glossary.items()):
        raise ValueError("glossary lock is not a subset of the agent license inventory")
    rows = []
    for name, version in pins.items():
        dist = importlib.metadata.distribution(name)
        if dist.version != version:
            raise ValueError(f"{name}: installed {dist.version}, expected {version}")
        metadata = dist.metadata
        license_text = metadata.get("License-Expression") or metadata.get("License")
        if not license_text or "\n" in license_text:
            classifiers = [value.split(" :: ")[-1] for value in metadata.get_all("Classifier", [])
                           if value.startswith("License :: ") and value != "License :: OSI Approved"]
            license_text = "; ".join(classifiers)
        if not license_text:
            raise ValueError(f"{name}: no license metadata")
        rows.append(f"| `{name}` | {version} | {license_text.replace('|', '&#124;')} |")
    table = f"""### 4.1 agent-container — {len(rows)} packages

Generated from `agent-container/requirements.lock` and the exact installed
distribution metadata with `scripts/generate-python-licenses.py`.
License-Expression takes precedence over License; classifier labels are used
when License is absent or contains the full license body. No unverified packages.
The isolated glossary worker ships a subset of these same versions
(`index-service/glossary-requirements.lock`).

| Package | Version | License (verbatim from metadata) |
| --- | --- | --- |
""" + "\n".join(rows) + "\n\n"
    start, end = text.index("### 4.1 agent-container"), text.index("### 4.2 bot-gateway")
    text = text[:start] + table + text[end:]
    text = re.sub(r"\d+ \(fully listed in §4.1\)", f"{len(rows)} (fully listed in §4.1)", text)
    text = re.sub(r"Of the \d+ rows in §4.1, \d+ came from\nsource \(a\) and \d+ from source \(b\)\.",
                  f"The current {len(rows)} rows in §4.1 were regenerated from source (a).", text)
    text = re.sub(r"The current \d+ rows in §4.1 were regenerated from source \(a\)\.",
                  f"The current {len(rows)} rows in §4.1 were regenerated from source (a).", text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail on drift without modifying files")
    args = parser.parse_args()
    path = ROOT / "THIRD-PARTY-LICENSES"
    original = path.read_text(encoding="utf-8")
    generated = render_manifest(original)
    if args.check:
        if original != generated:
            parser.exit(1, "Python license table is stale; run scripts/generate-python-licenses.py\n")
        print("Python license metadata matches the locked distributions")
    else:
        path.write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
