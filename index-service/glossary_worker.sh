#!/usr/bin/env bash
# Called AFTER the per-slice flock: queued jobs must load the current SDK interpreter.
set -euo pipefail
if [[ -n "${GLOSSARY_CONFIG_FILE:-}" ]]; then
  # Deployment publishes this trusted file atomically. Export cap and SDK to Python too.
  exec 9>"$GLOSSARY_CONFIG_FILE.lock"
  flock -s 9
  set -a
  # shellcheck disable=SC1090
  source "$GLOSSARY_CONFIG_FILE"
  set +a
  export GLOSSARY_WORKER_CONFIG_SHA
  GLOSSARY_WORKER_CONFIG_SHA="$(sha256sum "$GLOSSARY_CONFIG_FILE" | cut -d' ' -f1)"
  flock -u 9
  exec 9>&-
  if [[ "${GLOSSARY_ENABLED:-true}" == false || -z "${MODEL:-}" ]]; then
    echo "glossary_worker: glossary disabled — leaving slice unchanged"
    exit 0
  fi
fi
exec "${GLOSSARY_PYTHON:-python3}" -m glossary_gen "$@"
