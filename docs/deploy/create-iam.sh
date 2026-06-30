#!/usr/bin/env bash
# create-iam.sh — pre-create the EC2 instance role --local mode needs, via CloudFormation.
#
# Usually you don't run this directly — launch-host.sh calls it. Run it standalone only to (re)create
# the IAM stack. It picks an AWS profile (you SELECT from your configured profiles — no credentials
# typed) and a region, then deploys docs/deploy/source-truth-iam.yaml: one instance role (carrying
# both deploy-time and runtime permissions, since --local runs the whole deploy on the EC2 itself)
# plus its instance profile. Idempotent.
#
#   docs/deploy/create-iam.sh                    # interactive: pick profile + region
#   docs/deploy/create-iam.sh --profile admin --region ap-northeast-1   # non-interactive
#
# It also creates the AgentCore service-linked role (fresh-account safe; ignored if it exists).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/source-truth-iam.yaml"
STACK="source-truth-iam"

PROFILE="" REGION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region)  REGION="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; sed -n '2,14p' "$0"; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "✗ aws CLI not found — install AWS CLI v2 first." >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "✗ template not found: $TEMPLATE" >&2; exit 1; }

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
WHO="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)" \
  || { echo "✗ profile '$PROFILE' has no working credentials (try: aws sso login --profile $PROFILE)." >&2; exit 1; }

# --- region ------------------------------------------------------------------------------------
if [ -z "$REGION" ]; then
  DEF="$(aws configure get region 2>/dev/null || echo ap-northeast-1)"
  read -rp "AWS region [${DEF}]: " REGION || true
  REGION="${REGION:-$DEF}"
fi

echo
echo "  profile : $PROFILE  (account $WHO)"
echo "  region  : $REGION"
echo "  stack   : $STACK  ←  $TEMPLATE"
read -rp "确认用以上账号/区域创建 IAM 角色？/ create the IAM roles in this account/region? [y/N]: " ok || true
[[ "${ok:-}" =~ ^[Yy] ]] || { echo "已取消 / cancelled"; exit 0; }

echo "▶ deploying CloudFormation stack $STACK ..."
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"

# AgentCore service-linked role (manages the microVM's VPC ENIs). Fresh-account safe; already-exists
# / not-authorized are tolerated — never fail the run on it (the CFN roles are what matter here).
aws iam create-service-linked-role --aws-service-name bedrock-agentcore.amazonaws.com >/dev/null 2>&1 \
  && echo "• created AgentCore service-linked role" \
  || echo "• AgentCore service-linked role: already present or auto-managed (skipped)"

echo
echo "✓ done. Outputs:"
aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text 2>/dev/null || true
echo
echo "下一步 / next:"
echo "  1) 把 source-truth-index-profile 挂到索引主机 EC2"
echo "     attach instance profile 'source-truth-index-profile' to the index-host EC2"
echo "  2) SSH 进该 EC2，克隆仓库后跑：./scripts/deploy-all.sh --region $REGION --local"
echo "     （部署用这台机器的实例角色，无需在 EC2 上配 profile）"
echo "  提示：launch-host.sh 会自动完成开机 + 挂角色 + 打印这些步骤。"
