#!/usr/bin/env bash
# create-iam.sh — ensure the EC2 instance role + profile that --local mode needs.
#
# Usually you don't run this directly — launch-host.sh calls it. It picks an AWS profile (you SELECT
# from your configured profiles — no credentials typed) and a region, then makes sure the instance
# role `source-truth-index-role` + profile `source-truth-index-profile` exist and carry the
# deploy-time permissions --local needs (it runs the whole deploy on the EC2 itself).
#
# Idempotent and reuse-friendly: if the role/profile already exist (e.g. a default two-machine deploy
# already created them in this account), it does NOT recreate them — it only adds the deploy-* policies
# on top. Note: the role is account-global, so adding deploy-* perms here also grants them to any other
# instance already using this role (e.g. an existing index-service host). Don't run --local in an
# account whose default deploy you want to keep permission-isolated.
#
#   scripts/create-iam.sh                    # interactive: pick profile + region
#   scripts/create-iam.sh --profile admin --region ap-northeast-1   # non-interactive
#
# It also creates the AgentCore service-linked role (fresh-account safe; ignored if it exists).
set -euo pipefail

ROLE=source-truth-index-role
PROFILE_NAME=source-truth-index-profile

PROFILE="" REGION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region)  REGION="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; sed -n '2,18p' "$0"; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "✗ aws CLI not found — install AWS CLI v2 first." >&2; exit 1; }

# --- pick a profile (select, don't type) -------------------------------------------------------
if [ -z "$PROFILE" ]; then
  mapfile -t PROFILES < <(aws configure list-profiles 2>/dev/null || true)
  if [ "${#PROFILES[@]}" -eq 0 ]; then
    echo "✗ no AWS profiles found (aws configure list-profiles is empty)." >&2
    echo "  Configure one (aws configure --profile <name> / SSO), or pass --profile <name>." >&2
    exit 1
  fi
  echo "选择部署用的 AWS profile / pick the AWS profile to deploy with:"
  select p in "${PROFILES[@]}"; do
    [ -n "${p:-}" ] && { PROFILE="$p"; break; }
    echo "  请输入列表中的编号 / enter a number from the list"
  done
fi
export AWS_PROFILE="$PROFILE"

# Prove the profile works + show who/where, so the operator catches a wrong account before creating roles.
ACCOUNT="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)" \
  || { echo "✗ profile '$PROFILE' has no working credentials (try: aws sso login --profile $PROFILE)." >&2; exit 1; }

# --- region ------------------------------------------------------------------------------------
if [ -z "$REGION" ]; then
  DEF="$(aws configure get region 2>/dev/null || echo ap-northeast-1)"
  read -rp "AWS region [${DEF}]: " REGION || true
  REGION="${REGION:-$DEF}"
fi

echo
echo "  profile : $PROFILE  (account $ACCOUNT)"
echo "  region  : $REGION"
echo "  role    : $ROLE  (+ instance profile $PROFILE_NAME)"
read -rp "确认在以上账号创建/更新 IAM 角色？/ create or update the IAM role in this account? [y/N]: " ok || true
[[ "${ok:-}" =~ ^[Yy] ]] || { echo "已取消 / cancelled"; exit 0; }

# --- role (create if missing; account-global, so reuse an existing one) ------------------------
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "• role $ROLE already exists — reusing it (adding deploy-* policies on top)."
else
  echo "▶ creating role $ROLE ..."
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
# SSM access (shell into the box to troubleshoot). attach-role-policy is idempotent.
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null

# --- deploy-time policies (put = overwrite; safe to re-run) ------------------------------------
# These are what --local needs on top of the runtime policies that deploy-all's Phase 1b
# (provision_iam.sh) writes. Kept here as the single source of truth for the deploy-time grant.
echo "▶ writing deploy-* policies ..."

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-network --policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Action":[
    "ec2:Describe*","ec2:CreateVpc","ec2:CreateSubnet","ec2:CreateInternetGateway",
    "ec2:AttachInternetGateway","ec2:CreateNatGateway","ec2:AllocateAddress","ec2:CreateRouteTable",
    "ec2:CreateRoute","ec2:AssociateRouteTable","ec2:CreateSecurityGroup",
    "ec2:AuthorizeSecurityGroupIngress","ec2:CreateTags","ec2:ModifyVpcAttribute",
    "ec2:ModifySubnetAttribute","ec2:ModifyInstanceAttribute","ec2:RunInstances","ec2:TerminateInstances"],
    "Resource":"*"}]}' >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-ecr --policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Action":[
    "ecr:GetAuthorizationToken","ecr:DescribeRepositories","ecr:CreateRepository",
    "ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload","ecr:PutImage"],
    "Resource":"*"}]}' >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-agentcore --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":[
      "bedrock-agentcore:CreateAgentRuntime","bedrock-agentcore:UpdateAgentRuntime",
      "bedrock-agentcore:GetAgentRuntime","bedrock-agentcore:ListAgentRuntimes",
      "bedrock-agentcore:DeleteAgentRuntime","bedrock-agentcore:InvokeAgentRuntime"],
      "Resource":"*"},
    {"Effect":"Allow","Action":["bedrock:ListInferenceProfiles","bedrock:GetInferenceProfile"],
      "Resource":"*"}]}' >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-secrets --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[{\"Effect\":\"Allow\",\"Action\":[
    \"secretsmanager:CreateSecret\",\"secretsmanager:PutSecretValue\",
    \"secretsmanager:DescribeSecret\",\"secretsmanager:DeleteSecret\"],
    \"Resource\":\"arn:aws:secretsmanager:*:${ACCOUNT}:secret:source-truth/*\"}]}" >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-iam --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[
      \"iam:GetRole\",\"iam:CreateRole\",\"iam:PutRolePolicy\",\"iam:DeleteRolePolicy\",
      \"iam:AttachRolePolicy\",\"iam:GetInstanceProfile\",\"iam:CreateInstanceProfile\",
      \"iam:AddRoleToInstanceProfile\",\"iam:CreateServiceLinkedRole\",\"iam:PassRole\"],
      \"Resource\":[
        \"arn:aws:iam::${ACCOUNT}:role/source-truth-*\",
        \"arn:aws:iam::${ACCOUNT}:role/SourceTruthAgentRuntimeRole\",
        \"arn:aws:iam::${ACCOUNT}:instance-profile/source-truth-*\"]},
    {\"Effect\":\"Allow\",\"Action\":\"iam:CreateServiceLinkedRole\",\"Resource\":\"*\",
      \"Condition\":{\"StringEquals\":{\"iam:AWSServiceName\":\"bedrock-agentcore.amazonaws.com\"}}}]}" >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name deploy-misc --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["s3:PutObject","s3:CreateBucket","s3:GetBucketLocation","s3:ListAllMyBuckets"],
      "Resource":"*"},
    {"Effect":"Allow","Action":["ssm:SendCommand","ssm:GetCommandInvocation"],"Resource":"*"},
    {"Effect":"Allow","Action":[
      "route53:ListHostedZonesByVPC","route53:ListHostedZones","route53:ChangeResourceRecordSets",
      "route53:CreateHostedZone","route53:GetChange"],"Resource":"*"},
    {"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}' >/dev/null

# --- instance profile (create if missing; attach role if not already on it) --------------------
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "▶ creating instance profile $PROFILE_NAME ..."
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
fi
# add-role-to-instance-profile errors if the role is already attached — tolerate that one case.
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
     --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null | grep -qw "$ROLE"; then
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE" >/dev/null
fi

# AgentCore service-linked role (manages the microVM's VPC ENIs). Fresh-account safe; already-exists
# / not-authorized are tolerated — never fail the run on it.
aws iam create-service-linked-role --aws-service-name bedrock-agentcore.amazonaws.com >/dev/null 2>&1 \
  && echo "• created AgentCore service-linked role" \
  || echo "• AgentCore service-linked role: already present or auto-managed (skipped)"

echo
echo "✓ done. role $ROLE + profile $PROFILE_NAME ready in account $ACCOUNT."
echo
echo "下一步 / next:"
echo "  1) 把 $PROFILE_NAME 挂到索引主机 EC2 / attach instance profile '$PROFILE_NAME' to the index-host EC2"
echo "  2) SSH 进该 EC2，克隆仓库后跑：./scripts/deploy-all.sh --region $REGION --local"
echo "     （部署用这台机器的实例角色，无需在 EC2 上配 profile）"
echo "  提示：launch-host.sh 会自动完成开机 + 挂角色 + 打印这些步骤。"
