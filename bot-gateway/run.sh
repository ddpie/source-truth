#!/usr/bin/env bash
# run.sh — bot-gateway service launcher (invoked by the bot-gateway.service
# systemd unit on the index-service host; see index-service/bootstrap.sh).
#
# Why a wrapper instead of `ExecStart=node dist/index.js` directly: the Feishu
# app credentials must NOT sit on disk in plaintext. So the non-secret config
# (RUNTIME_ARN, region, locale, salt) lives in /etc/bot-gateway.env, but the
# Feishu app_id/secret/bot_open_id are fetched from AWS Secrets Manager HERE, at
# start, into the process environment only — never written to a file. The
# instance role grants secretsmanager:GetSecretValue on this one secret.
#
# The secret is a JSON object: {"app_id":"...","app_secret":"...","bot_open_id":"..."}
# (bot_open_id optional — the gateway only needs it for self-message echo-guard).
set -euo pipefail

ENV_FILE="${BOT_GATEWAY_ENV:-/etc/bot-gateway.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "run.sh FATAL: $ENV_FILE missing — the deploy's gateway phase writes it after the runtime exists" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${RUNTIME_ARN:?run.sh FATAL: RUNTIME_ARN unset in $ENV_FILE}"
: "${AWS_REGION:?run.sh FATAL: AWS_REGION unset in $ENV_FILE}"
: "${FEISHU_SECRET_ID:?run.sh FATAL: FEISHU_SECRET_ID unset in $ENV_FILE}"

# Fetch the Feishu credential JSON from Secrets Manager (role creds via IMDS).
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --secret-id "$FEISHU_SECRET_ID" --region "$AWS_REGION" \
  --query SecretString --output text)" || {
  echo "run.sh FATAL: cannot read Feishu secret '$FEISHU_SECRET_ID' from Secrets Manager (check the instance role grant)" >&2
  exit 1
}

# Parse with python3 (present on the index host) — robust against quoting/escapes
# that a sed/grep parse would mangle. Missing required keys → loud failure here
# rather than an opaque gateway env-validation crash-loop.
#
# CRITICAL: assign to a variable FIRST and check the exit code, THEN eval. Inlining
# the command substitution directly in `eval "$(...)"` SWALLOWS python's sys.exit(1)
# (the substitution's failure does not propagate under set -e, and `eval ""` returns
# 0), so a missing required key would silently start a broken gateway — exactly the
# crash-loop this guard claims to prevent (cross-review HIGH).
if ! EXPORTS="$(printf '%s' "$SECRET_JSON" | python3 -c '
import sys, json, shlex
d = json.load(sys.stdin)
for env_key, json_key, required in (
    ("FEISHU_APP_ID", "app_id", True),
    ("FEISHU_APP_SECRET", "app_secret", True),
    ("FEISHU_BOT_OPEN_ID", "bot_open_id", False),
):
    v = d.get(json_key)
    if v is None:
        if required:
            sys.stderr.write(f"run.sh FATAL: Feishu secret is missing required key {json_key!r}\n")
            sys.exit(1)
        continue
    print(f"export {env_key}={shlex.quote(str(v))}")
')"; then
  echo "run.sh FATAL: failed to parse Feishu secret '$FEISHU_SECRET_ID' (missing required keys or invalid JSON)" >&2
  exit 1
fi
eval "$EXPORTS"

exec node dist/index.js
