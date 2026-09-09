"""Glossary source reads use the same withheld-path policy as the serving tools."""

from __future__ import annotations

import os
import stat
from contextlib import contextmanager
from pathlib import Path

import served_paths


class BinarySourceError(ValueError):
    """The candidate contains binary data rather than source text."""


def source_path(root: Path, path: str) -> Path:
    """Validate both the requested name and the target of an in-repo symlink."""
    base = root.resolve()
    relative = Path(path)
    if relative.is_absolute() or ".." in relative.parts or served_paths.is_withheld(path):
        raise ValueError("glossary source path is not served")
    target = (base / relative).resolve()
    if not target.is_relative_to(base) or target == base:
        raise ValueError("read outside repository")
    if served_paths.is_withheld(str(target.relative_to(base))):
        raise ValueError("glossary source target is not served")
    return target


@contextmanager
def open_source(root: Path, path: str):
    """Open the checked target without following any symlink introduced after validation."""
    base = root.resolve()
    relative = source_path(base, path).relative_to(base)
    directory = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        # NONBLOCK keeps an attacker-supplied FIFO from hanging before fstat rejects it.
        fd = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError("glossary source must be a regular file")
            source = os.fdopen(fd, encoding="utf-8", errors="replace")
        except BaseException:
            os.close(fd)
            raise
        with source:
            # Debug symbols and binaries with unfamiliar suffixes can otherwise
            # reach the model as replacement characters and produce empty output.
            # Bound the sniff and rewind so all consumers see the original text.
            if "\x00" in source.read(8192):
                raise BinarySourceError("glossary source must be text")
            source.seek(0)
            yield source
    finally:
        os.close(directory)
