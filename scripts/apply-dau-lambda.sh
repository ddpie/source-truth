#!/usr/bin/env bash
# apply-dau-lambda.sh — provision the B-class DAU pre-aggregation Lambda + its daily
# EventBridge schedule (monitoring plan 阶段1, the last 阶段1 item).
#
# Creates/updates, idempotently:
#   1. an execution role (logs:StartQuery/GetQueryResults/StopQuery + cloudwatch:PutMetricData
#      + the basic Lambda logging perms) — deploy-time, NOT a runtime role;
#   2. the Lambda function from infra/monitoring/lambda/dau_preaggregate.py (zipped inline,
#      pure stdlib + the runtime's bundled boto3 — no build step);
#   3. an EventBridge (events) rule on a daily cron + permission + target → the function.
#
# The function runs once/day, queries yesterday's distinct hashUserId count from the gateway
# log group via Logs Insights, and PutMetricData's it as SourceTruth/Gateway DAU (the metric
# the product dashboard's DAU widget reads). See infra/monitoring/lambda/dau_preaggregate.py.
#
# Usage:
#   ./scripts/apply-dau-lambda.sh [--region <r>] [--log-group <g>] [--tz <zone>] [--schedule <cron>] [--dry-run]
#   --region     AWS region (default: DEPLOY_REGION from .local/deploy-config)
#   --log-group  gateway log group (default: /source-truth/bot-gateway)
#   --tz         ops timezone for the day window (default: Asia/Shanghai = 东八区 UTC+8)
#   --schedule   EventBridge schedule expression (default: cron(30 16 * * ? *) = 01:30 JST daily,
#                i.e. ~90min after local midnight so the prior day's logs have settled)
#   --dry-run    print the plan; make NO AWS calls
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/env-utils.sh
source "$ROOT/scripts/lib/env-utils.sh"

LAMBDA_SRC="$ROOT/infra/monitoring/lambda/dau_preaggregate.py"
CONFIG_FILE="$ROOT/.local/deploy-config"

FN_NAME="source-truth-dau-preaggregate"
ROLE_NAME="source-truth-dau-lambda-role"
RULE_NAME="source-truth-dau-daily"
RUNTIME="python3.12"
HANDLER="dau_preaggregate.handler"

REGION="" LOG_GROUP="/source-truth/bot-gateway" TZ_NAME="Asia/Shanghai"
SCHEDULE="cron(30 16 * * ? *)" DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/apply-dau-lambda.sh [--region <r>] [--log-group <g>] [--tz <zone>] [--schedule <cron>] [--dry-run]

Provisions the B-class DAU pre-aggregation Lambda + daily EventBridge schedule (idempotent).

  --region <r>     AWS region (default: DEPLOY_REGION from .local/deploy-config)
  --log-group <g>  gateway log group (default: /source-truth/bot-gateway)
  --tz <zone>      ops timezone for the day window (default: Asia/Shanghai = 东八区 UTC+8)
  --schedule <c>   EventBridge schedule expr (default: cron(30 16 * * ? *) = 01:30 JST daily)
  --dry-run        print the plan; NO AWS calls
  -h, --help       this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --log-group) LOG_GROUP="$2"; shift 2 ;;
    --tz) TZ_NAME="$2"; shift 2 ;;
    --schedule) SCHEDULE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) say err "unknown flag: $1"; usage; exit 2 ;;
  esac
done

require_cmd python3 "install Python 3" || exit 1
[[ -f "$LAMBDA_SRC" ]] || { say err "lambda source not found: $LAMBDA_SRC"; exit 1; }

if [[ -z "$REGION" ]]; then
  safe_source_env "$CONFIG_FILE"
  REGION="${DEPLOY_REGION:-}"
fi
if [[ "$DRY_RUN" -eq 0 && -z "$REGION" ]]; then
  say err "no region: pass --region or set DEPLOY_REGION in $CONFIG_FILE (or use --dry-run)"
  exit 2
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  say step "[dry-run] would provision DAU Lambda (region: ${REGION:-<unset>}):"
  say info "  role:     $ROLE_NAME (logs:StartQuery/GetQueryResults/StopQuery on $LOG_GROUP + cloudwatch:PutMetricData)"
  say info "  function: $FN_NAME ($RUNTIME, handler $HANDLER) from $(basename "$LAMBDA_SRC")"
  say info "  env:      LOG_GROUP=$LOG_GROUP TZ_NAME=$TZ_NAME"
  say info "  schedule: rule $RULE_NAME = $SCHEDULE → $FN_NAME"
  exit 0
fi

require_cmd aws "install/configure the AWS CLI" || exit 1
require_cmd zip "install zip (used to package the Lambda)" || exit 1
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN_NAME}"
RULE_ARN="arn:aws:events:${REGION}:${ACCOUNT}:rule/${RULE_NAME}"

# --- 1. execution role (idempotent) ---
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  say ok "created role $ROLE_NAME"
  sleep 10  # let the role propagate before create-function
fi
# Inline policy (upsert every run → repairs drift), least-privilege:
#  - StartQuery/StopQuery authorize on the LOG-GROUP resource type → scope to THIS group's
#    ARN (so the role can't query arbitrary account log groups, e.g. another team's PII).
#  - GetQueryResults authorizes only on "*" (keyed by queryId, no log-group resource) — it
#    genuinely cannot be log-group-scoped, so "*" is required, not over-broad.
#  - PutMetricData has no resource ARN; constrain by the namespace condition (the only lever).
LG_ARN="arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name dau-insights --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:StartQuery\",\"logs:StopQuery\"],\"Resource\":\"${LG_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:GetQueryResults\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"cloudwatch:PutMetricData\"],\"Resource\":\"*\",
     \"Condition\":{\"StringEquals\":{\"cloudwatch:namespace\":\"SourceTruth/Gateway\"}}}]}" >/dev/null
say ok "role policy dau-insights applied"

# --- 2. package + create/update function (idempotent) ---
ZIP="$(mktemp -d)/dau.zip"
( cd "$(dirname "$LAMBDA_SRC")" && zip -q "$ZIP" "$(basename "$LAMBDA_SRC")" )
ENV_VARS="Variables={LOG_GROUP=$LOG_GROUP,TZ_NAME=$TZ_NAME}"
if aws lambda get-function --region "$REGION" --function-name "$FN_NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --region "$REGION" --function-name "$FN_NAME" \
    --zip-file "fileb://$ZIP" >/dev/null
  # MUST settle the code update before the config update or update-function-configuration
  # throws ResourceConflictException ("an update is in progress"). `wait function-updated`
  # blocks until LastUpdateStatus != InProgress. Do NOT `|| true` it — a swallowed wait
  # failure would let the config update race the conflict it exists to prevent. If `wait`
  # is genuinely unsupported on an old CLI, fall back to a short fixed sleep.
  if ! aws lambda wait function-updated --region "$REGION" --function-name "$FN_NAME" 2>/dev/null; then
    sleep 8  # old-CLI fallback: give the code update time to settle
  fi
  aws lambda update-function-configuration --region "$REGION" --function-name "$FN_NAME" \
    --runtime "$RUNTIME" --handler "$HANDLER" --timeout 180 --environment "$ENV_VARS" >/dev/null
  say ok "updated function $FN_NAME"
else
  aws lambda create-function --region "$REGION" --function-name "$FN_NAME" \
    --runtime "$RUNTIME" --handler "$HANDLER" --role "$ROLE_ARN" \
    --timeout 180 --memory-size 128 --zip-file "fileb://$ZIP" \
    --environment "$ENV_VARS" >/dev/null
  say ok "created function $FN_NAME"
fi
rm -f "$ZIP"; rmdir "$(dirname "$ZIP")" 2>/dev/null || true

# --- 3. EventBridge daily schedule (idempotent) ---
aws events put-rule --region "$REGION" --name "$RULE_NAME" \
  --schedule-expression "$SCHEDULE" --state ENABLED \
  --description "source-truth daily DAU pre-aggregation" >/dev/null
# Permission for EventBridge to invoke the function (idempotent: ignore an existing statement).
aws lambda add-permission --region "$REGION" --function-name "$FN_NAME" \
  --statement-id "${RULE_NAME}-invoke" --action lambda:InvokeFunction \
  --principal events.amazonaws.com --source-arn "$RULE_ARN" >/dev/null 2>&1 || true
aws events put-targets --region "$REGION" --rule "$RULE_NAME" \
  --targets "Id=dau,Arn=$FN_ARN" >/dev/null
say ok "schedule $RULE_NAME = $SCHEDULE → $FN_NAME"

say ok "DAU pre-aggregation Lambda provisioned (region $REGION)"
say info "  it runs daily; the product dashboard's DAU widget reads SourceTruth/Gateway DAU once data accrues."
say info "  manual test: aws lambda invoke --region $REGION --function-name $FN_NAME /tmp/dau-out.json && cat /tmp/dau-out.json"
