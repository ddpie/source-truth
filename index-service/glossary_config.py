"""Build provenance prevents mixing artifacts from different SDK/model configurations."""

from __future__ import annotations

import hashlib
import json
import os
from contextlib import contextmanager
from pathlib import Path

import glossary_build


@contextmanager
def publish_guard(config_path: str | None, expected: bytes | None):
    """Serialize the final swap with deployment's configuration publication."""
    if not config_path:
        yield
        return
    import fcntl

    with open(config_path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        if Path(config_path).read_bytes() != expected:
            raise RuntimeError("glossary configuration changed during build")
        yield


def fingerprint(sdk: str, model: str, region: str, *, max_files: int | None = None) -> str:
    cap = int(os.environ.get("GLOSSARY_MAX_FILES", "0") or "0") if max_files is None else max_files
    material = json.dumps({
        "sdk": sdk, "model": model, "region": region, "endpoint": "runtime",
        "prompt": glossary_build.build_prompt(["<file>"], project="<project>"),
        "format": 3, "max_files": max(0, cap),
    }, sort_keys=True)
    # Format 3 rebuilds slices with binary-content filtering before cap accounting.
    # Protocol changes also invalidate OpenAI artifacts.
    if sdk == "openai":
        material += ":converse-v1"
    return hashlib.sha256(material.encode()).hexdigest()


def metadata(out: str) -> dict:
    """Return provenance only when it describes the data file currently being served."""
    try:
        value = json.loads(Path(out + ".meta").read_text())
        if isinstance(value, dict) and value.get("sha256") == hashlib.sha256(Path(out).read_bytes()).hexdigest():
            return value
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {}


def matches(out: str, expected: str) -> bool:
    return metadata(out).get("fingerprint") == expected


def stamp(out: str, expected: str, *, content_path: str | None = None,
          source_revision: str | None = None, pending_revision: str | None = None,
          pending_files: list[str] | None = None) -> None:
    path = Path(out + ".meta")
    temp = Path(out + ".meta.new")
    temp.write_text(json.dumps({
        "fingerprint": expected,
        "sha256": hashlib.sha256(Path(content_path or out).read_bytes()).hexdigest(),
        "source_revision": source_revision,
        "pending_revision": pending_revision,
        "pending_files": pending_files or [],
    }) + "\n")
    temp.replace(path)
