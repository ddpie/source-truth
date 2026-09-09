#!/usr/bin/env bash
# Install an immutable environment per dependency lock; active workers keep theirs.
set -euo pipefail
APP="${1:-/opt/idx/app}"
LOCK="$APP/glossary-requirements.lock"
SIG="$(sha256sum "$LOCK" | cut -d' ' -f1)"
VENV="/opt/idx/glossary-envs/$SIG"
mkdir -p /opt/idx/glossary-envs
(
  flock 9
  if [[ ! -f "$VENV/.ready" ]]; then
    # Host Python must meet the Agents SDK requirement (3.10+).
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --disable-pip-version-check -q -r "$LOCK"
    "$VENV/bin/python" -m pip check >&2
    touch "$VENV/.ready"
  fi
) 9>/opt/idx/glossary-envs/.install.lock
printf '%s\n' "$VENV/bin/python"
