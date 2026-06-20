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

# LOG_HASH_SALT (telemetry de-identification) — fetch HOST-SIDE from Secrets Manager, same
# as the Feishu creds above, so the salt NEVER travels through the deploy's SSM RunShellScript
# command body (base64 there is recorded in CloudTrail / SSM history — not secret). If the env
# file already set it (explicit override), keep that; otherwise read source-truth/log-hash-salt
# (the instance role has GetSecretValue on source-truth/*). A missing secret is non-fatal: the
# gateway still runs and log.ts uses its (weak) fallback while emitMetric stamps saltWeak:true,
# so de-identification weakness is observable rather than a crash. Never written to disk.
if [[ -z "${LOG_HASH_SALT:-}" ]]; then
  SALT_VAL="$(aws secretsmanager get-secret-value \
    --secret-id source-truth/log-hash-salt --region "$AWS_REGION" \
    --query SecretString --output text 2>/dev/null || echo "")"
  if [[ -n "$SALT_VAL" ]]; then
    export LOG_HASH_SALT="$SALT_VAL"
  else
    echo "run.sh WARN: source-truth/log-hash-salt not readable — telemetry hashUserId uses the weak public fallback (saltWeak:true will be stamped)" >&2
  fi
fi

exec node dist/index.js
