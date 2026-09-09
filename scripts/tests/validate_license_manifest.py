#!/usr/bin/env python3
"""Assert THIRD-PARTY-LICENSES still matches the lock files it was generated from.

Why this exists: the manifest was verified correct by hand once, at real cost — every version
traced to a lock file and every licence read from real package metadata. Nothing in the repo
referenced it afterwards, so the next `npm install` or `pip freeze` would have silently made it
wrong, which is exactly how a licence manifest ends up stating a version that never shipped.

This checks set membership and versions without installed dependencies. CI also runs
generate-python-licenses.py --check against the exact installed agent lock to verify
Python license metadata and generated content.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "THIRD-PARTY-LICENSES"
PY_LOCK = ROOT / "agent-container" / "requirements.lock"
GLOSSARY_LOCK = ROOT / "index-service" / "glossary-requirements.lock"
NPM_LOCK = ROOT / "bot-gateway" / "package-lock.json"

# Rows look like `| name | version | licence | ... |` inside the generated sections.
ROW = re.compile(r"^\|\s*`?([A-Za-z0-9._@/+-]+)`?\s*\|\s*`?([0-9][^|`\s]*)`?\s*\|")


def manifest_rows(section_marker: str, stop_marker: str) -> set[tuple[str, str]]:
    text = MANIFEST.read_text(encoding="utf-8")
    start = text.find(section_marker)
    if start < 0:
        sys.exit(f"validate_license_manifest: section {section_marker!r} not found in {MANIFEST}")
    end = text.find(stop_marker, start + len(section_marker))
    body = text[start : end if end > 0 else len(text)]
    out: set[tuple[str, str]] = set()
    for line in body.splitlines():
        m = ROW.match(line.strip())
        if m:
            out.add((m.group(1), m.group(2)))
    return out


def python_lock(path: pathlib.Path = PY_LOCK) -> set[tuple[str, str]]:
    out: set[tuple[str, str]] = set()
    names: set[str] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"([\w.-]+)==([A-Za-z0-9.!+_-]+)", line)
        if not match:
            raise ValueError(f"{path}:{number}: expected an exact name==version pin")
        name = re.sub(r"[-_.]+", "-", match[1]).lower()
        if name in names:
            raise ValueError(f"{path}:{number}: duplicate package {name}")
        names.add(name)
        out.add((name, match[2]))
    if not out:
        raise ValueError(f"{path}: empty lock")
    return out


def verify_glossary_subset() -> int:
    pins = python_lock(GLOSSARY_LOCK)
    extra = pins - python_lock()
    if extra:
        print(f"license-manifest: glossary packages missing from Python listing: {sorted(extra)}", file=sys.stderr)
    return int(bool(extra))


def npm_production() -> set[tuple[str, str]]:
    """Every non-dev entry of the lockfile, keyed on (name, version).

    Five packages ship at two versions each, so path entries outnumber distinct pairs — the
    manifest correctly records pairs, which is what a licence manifest needs.
    """
    data = json.loads(NPM_LOCK.read_text(encoding="utf-8"))
    out: set[tuple[str, str]] = set()
    for path, meta in (data.get("packages") or {}).items():
        if not path or meta.get("dev") or meta.get("devOptional"):
            continue
        version = meta.get("version")
        if not version:
            continue
        name = meta.get("name") or path.split("node_modules/")[-1]
        out.add((name, version))
    return out


def compare(label: str, manifest: set[tuple[str, str]], lock: set[tuple[str, str]]) -> int:
    missing = lock - manifest
    extra = manifest - lock
    if not missing and not extra:
        print(f"license-manifest: {label} OK ({len(lock)} entries)")
        return 0
    if missing:
        print(f"license-manifest: {label} MISSING {len(missing)} entry/entries the lock ships:", file=sys.stderr)
        for n, v in sorted(missing)[:20]:
            print(f"      {n}=={v}", file=sys.stderr)
    if extra:
        print(f"license-manifest: {label} has {len(extra)} entry/entries in NO lock file:", file=sys.stderr)
        for n, v in sorted(extra)[:20]:
            print(f"      {n}=={v}", file=sys.stderr)
    print("      regenerate THIRD-PARTY-LICENSES from the lock files (see its own regeneration commands).", file=sys.stderr)
    return 1


def main() -> int:
    for f in (MANIFEST, PY_LOCK, GLOSSARY_LOCK, NPM_LOCK):
        if not f.exists():
            print(f"license-manifest: missing {f}", file=sys.stderr)
            return 1
    rc = 0
    rc |= verify_glossary_subset()
    rc |= compare("agent-container", manifest_rows("### 4.1 agent-container", "### 4.2 bot-gateway"), python_lock())
    rc |= compare("bot-gateway", manifest_rows("### 4.2 bot-gateway", "### 4.3 index-service"), npm_production())
    return rc


if __name__ == "__main__":
    sys.exit(main())
