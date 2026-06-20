#!/usr/bin/env bash
# provision_iam.sh <region> <config_file> <bucket>
# Idempotent IAM for a FRESH account:
#   1. index-service EC2 instance profile (SSM + read the artifact bucket).
#   2. AgentCore runtime role (assumed by bedrock-agentcore; pull image, reach
#      the VPC, invoke Bedrock models). No EFS: the agent reads code over the
#      index-service HTTP bridge, so no elasticfilesystem permissions are needed.
# IAM is global; names are fixed (not region-scoped) so re-runs reconcile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"; source "$SCRIPT_DIR/env-utils.sh"
REGION="$1"; CONFIG="$2"; BUCKET="$3"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

INDEX_ROLE=source-truth-index-role
INDEX_PROFILE=source-truth-index-profile
RUNTIME_ROLE=SourceTruthAgentRuntimeRole

# ---- 1. index-service instance profile ----
if ! aws iam get-role --role-name "$INDEX_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$INDEX_ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$INDEX_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
fi
# Inline policy: read the artifact bucket.
aws iam put-role-policy --role-name "$INDEX_ROLE" --policy-name s3-artifacts --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
  \"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
  \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}" >/dev/null
# Inline policy: read the Feishu app credentials from Secrets Manager. The
# co-located bot-gateway's run.sh fetches the secret at start (creds never touch
# disk). Scoped to this project's secret-name prefix (source-truth/*) so the
# instance can't read unrelated secrets. The 6-char suffix Secrets Manager appends
# is covered by the trailing wildcard.
aws iam put-role-policy --role-name "$INDEX_ROLE" --policy-name feishu-secret --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
  \"Action\":[\"secretsmanager:GetSecretValue\"],
  \"Resource\":[\"arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:source-truth/*\"]}]}" >/dev/null
# Inline policy: ship the co-located bot-gateway's journald logs to CloudWatch. Until now
# only the AgentCore runtime role had logs perms; the gateway (a systemd unit ON the index
# host since co-location) had none, so its structured metric:true lines stayed in local
# journald and never reached CloudWatch — blocking the telemetry log pipeline + the whole
# monitoring dashboard/alarms (telemetry plan 阶段0 / monitoring plan §0 front gate). The
# CloudWatch agent on the host assumes THIS instance role; grant it create/put. CreateLogGroup
# can't be name-scoped (it acts on the group being created), so it's "*"; the stream/put are
# scoped to this project's log group prefix for least privilege. Idempotent (put-role-policy
# upserts), so a re-run just reasserts it — no new instance needed to apply.
# ⚠️ COUPLING: the bootstrap.sh CloudWatch-agent config (gate 2/3) MUST use a log_group_name
# under the LEADING-SLASH prefix /source-truth/ (e.g. /source-truth/bot-gateway). A config
# that drops the slash or uses another prefix silently AccessDenies every PutLogEvents. Both
# ARN forms below are required: the bare :log-group:/source-truth/* for DescribeLogStreams,
# and the :log-group:/source-truth/*:* (log-stream) variant for CreateLogStream/PutLogEvents.
aws iam put-role-policy --role-name "$INDEX_ROLE" --policy-name cloudwatch-logs --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\",\"logs:DescribeLogStreams\",\"logs:PutRetentionPolicy\"],
     \"Resource\":[\"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/source-truth/*\",
                   \"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/source-truth/*:*\"]}]}" >/dev/null
if ! aws iam get-instance-profile --instance-profile-name "$INDEX_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INDEX_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$INDEX_PROFILE" --role-name "$INDEX_ROLE" >/dev/null
  sleep 10  # let the instance profile propagate before EC2 launch
fi

# ---- 2. AgentCore runtime role ----
if ! aws iam get-role --role-name "$RUNTIME_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$RUNTIME_ROLE" --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
    \"Principal\":{\"Service\":\"bedrock-agentcore.amazonaws.com\"},
    \"Action\":\"sts:AssumeRole\",
    \"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT}\"}}}]}" >/dev/null
fi
# Inline policy: pull ECR image, invoke Bedrock, attach ENIs (VPC), logs. No EFS.
aws iam put-role-policy --role-name "$RUNTIME_ROLE" --policy-name runtime-perms --policy-document '{
  "Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":"*"},
    {"Effect":"Allow","Action":["ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:BatchCheckLayerAvailability","ecr:GetAuthorizationToken"],"Resource":"*"},
    {"Effect":"Allow","Action":["ec2:CreateNetworkInterface","ec2:DescribeNetworkInterfaces","ec2:DeleteNetworkInterface","ec2:DescribeSecurityGroups","ec2:DescribeSubnets"],"Resource":"*"},
    {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}
  ]}' >/dev/null

# ---- 3. AgentCore SERVICE-LINKED role (fresh-account safe) ----
# On a brand-new account, AgentCore's VPC mode needs the AWS service-linked role
# (manages ENIs for the microVM). The CUSTOMER role above is not enough — without
# the SLR, create_agent_runtime can fail at Phase 5 with an opaque error AFTER the
# long build/image phases. Best-effort: create it if absent; already-exists /
# not-authorized / unknown-service are all tolerated (older accounts have it
# auto-created, and some partitions name it differently). Never blocks the deploy.
if aws iam create-service-linked-role --aws-service-name bedrock-agentcore.amazonaws.com >/dev/null 2>&1; then
  say ok "created AgentCore service-linked role"
else
  say info "AgentCore service-linked role: already present or auto-managed (skipped)"
fi

update_env "$CONFIG" AGENT_RUNTIME_ROLE "arn:aws:iam::${ACCOUNT}:role/${RUNTIME_ROLE}"
update_env "$CONFIG" INDEX_INSTANCE_PROFILE "$INDEX_PROFILE"
say ok "iam ready: profile=$INDEX_PROFILE runtime-role=$RUNTIME_ROLE"
