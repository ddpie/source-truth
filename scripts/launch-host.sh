#!/usr/bin/env bash
# launch-host.sh — one-shot bootstrap for the single-EC2 (`--local`) deployment, run on YOUR machine.
#
# It chains the steps that come before `deploy-all.sh --local`:
#   1. pick an AWS profile (SELECT from your configured profiles — no credentials typed)
#   2. create the EC2 instance role + profile via create-iam.sh (CloudFormation)
#   3. pick VPC / subnet / key pair / instance type interactively
#   4. launch ONE ARM64 Ubuntu 24.04 EC2 with the instance profile attached + IMDSv2 required
#   5. print the SSH + deploy commands to run next
#
# The EC2 is LONG-LIVED and holds the deployment state in its repo's .local/ (deploy-config +
# projects.json), so later upgrades = SSH back into the SAME box and re-run deploy-all --local.
# That's why the box is NOT part of any CloudFormation stack (deleting a stack would take the
# state with it) — only IAM is.
#
#   scripts/launch-host.sh                 # fully interactive
#   scripts/launch-host.sh --profile admin --region ap-northeast-1   # skip those two prompts
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# pick_one <prompt> <value...> : numbered menu, echoes the chosen value on stdout (prompts on stderr).
pick_one() {
  local prompt="$1"; shift
  local opts=("$@") choice
  { echo "$prompt"; local i=1; for o in "${opts[@]}"; do echo "  $i) $o"; i=$((i+1)); done; } >&2
  while true; do
    read -rp "  # " choice >&2 || true
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#opts[@]} )) && { echo "${opts[$((choice-1))]}"; return; }
    echo "  请输入 1-${#opts[@]} / enter 1-${#opts[@]}" >&2
  done
}

# --- 1. profile ---------------------------------------------------------------------------------
if [ -z "$PROFILE" ]; then
  mapfile -t PROFILES < <(aws configure list-profiles 2>/dev/null || true)
  [ "${#PROFILES[@]}" -gt 0 ] || { echo "✗ no AWS profiles (run aws configure / SSO, or pass --profile)." >&2; exit 1; }
  PROFILE="$(pick_one "选择 AWS profile / pick the AWS profile:" "${PROFILES[@]}")"
fi
export AWS_PROFILE="$PROFILE"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { echo "✗ profile '$PROFILE' credentials not working (try: aws sso login --profile $PROFILE)." >&2; exit 1; }
[ -n "$REGION" ] || { DEF="$(aws configure get region 2>/dev/null || echo ap-northeast-1)"; read -rp "AWS region [${DEF}]: " REGION || true; REGION="${REGION:-$DEF}"; }
export AWS_DEFAULT_REGION="$REGION"
echo "• profile=$PROFILE  account=$ACCOUNT  region=$REGION"

# --- 2. IAM (reuse create-iam.sh; idempotent) ---------------------------------------------------
echo "▶ ensuring IAM roles (create-iam.sh) ..."
"$HERE/create-iam.sh" --profile "$PROFILE" --region "$REGION"

# Only one host is meant to exist (it holds the deploy state); warn before launching a second.
mapfile -t RUNNING < <(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=source-truth-host" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' --output text 2>/dev/null | grep -v '^$' || true)
if [ "${#RUNNING[@]}" -gt 0 ]; then
  echo "⚠ already running a source-truth-host:" >&2
  printf '    %s\n' "${RUNNING[@]}" >&2
  echo "  这台机器应只有一台（部署状态存在它的 .local/，升级是 SSH 回这台重跑，不是新起一台）。" >&2
  read -rp "  仍要再起一台？/ launch ANOTHER one anyway? [y/N]: " more || true
  [[ "${more:-}" =~ ^[Yy] ]] || { echo "已取消 / cancelled"; exit 0; }
fi

# --- 3. pick VPC / subnet / key pair / instance type --------------------------------------------
mapfile -t VPCS < <(aws ec2 describe-vpcs --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' '\n')
[ "${#VPCS[@]}" -gt 0 ] || { echo "✗ no VPC in $REGION." >&2; exit 1; }
VPC="$(pick_one "选择 VPC / pick a VPC:" "${VPCS[@]}")"

mapfile -t SUBNETS < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock]' --output text 2>/dev/null | awk '{print $1" ("$2" "$3")"}')
[ "${#SUBNETS[@]}" -gt 0 ] || { echo "✗ no subnet in $VPC." >&2; exit 1; }
SUBNET="$(pick_one "选择子网（需能出公网拉取依赖：公有子网或带 NAT 的私有子网）/ pick a subnet (must reach the internet):" "${SUBNETS[@]}")"
SUBNET="${SUBNET%% *}"

mapfile -t KEYS < <(aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n')
[ "${#KEYS[@]}" -gt 0 ] || { echo "✗ no EC2 key pair in $REGION — create one first (you need it to SSH in)." >&2; exit 1; }
KEY="$(pick_one "选择 SSH 密钥对 / pick an SSH key pair:" "${KEYS[@]}")"

mapfile -t SGS < <(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text 2>/dev/null | awk '{print $1" ("$2")"}')
[ "${#SGS[@]}" -gt 0 ] || { echo "✗ no security group in $VPC." >&2; exit 1; }
SG="$(pick_one "选择安全组（需放行你的 SSH 22 端口）/ pick a security group (must allow your SSH on 22):" "${SGS[@]}")"
SG="${SG%% *}"
# Soft-check the SG actually opens 22 (FromPort<=22<=ToPort, or all-traffic -1) — wrong SG = can't SSH in.
HAS22="$(aws ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[?(IpProtocol=='-1') || (FromPort<=\`22\` && ToPort>=\`22\`)] | [0]" \
  --output text 2>/dev/null || true)"
if [ -z "$HAS22" ] || [ "$HAS22" = None ]; then
  echo "⚠ 所选安全组 $SG 似乎没放行 22 端口入站——起好后可能 SSH 连不上。" >&2
  read -rp "  仍用它？/ use it anyway? [y/N]: " sgok || true
  [[ "${sgok:-}" =~ ^[Yy] ]] || { echo "请先在该安全组放行你的 IP 的 22 端口再重跑 / open 22 first, then re-run"; exit 1; }
fi

ITYPE="$(pick_one "选择机型（ARM/Graviton）/ pick an instance type (ARM):" \
  "t4g.large" "t4g.xlarge" "m7g.large" "m7g.xlarge" "m7g.2xlarge")"
read -rp "根卷大小 GiB / root volume GiB [30]: " DISK || true; DISK="${DISK:-30}"
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK>=8 )) || { echo "✗ 根卷需为 >=8 的整数 GiB / root volume must be an integer GiB >= 8." >&2; exit 2; }

# Latest Ubuntu 24.04 ARM64 AMI (Canonical owner id), same source as the default deploy path.
AMI="$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/dev/null)"
if [ -z "$AMI" ] || [ "$AMI" = None ]; then
  echo "✗ no Ubuntu 24.04 arm64 AMI found in $REGION via describe-images. Try the Canonical SSM parameter:" >&2
  echo "    aws ssm get-parameter --region $REGION --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text" >&2
  echo "  then pass it as --image-id to run-instances manually (see runbook)." >&2
  exit 1
fi

# --- 4. confirm + launch ------------------------------------------------------------------------
cat >&2 <<SUMMARY

  即将启动 / about to launch:
    region        $REGION   account $ACCOUNT
    vpc / subnet  $VPC / $SUBNET
    type / disk   $ITYPE / ${DISK}GiB   AMI $AMI
    key / sg      $KEY / $SG
    profile(role) source-truth-index-profile  ·  IMDSv2 required
SUMMARY
read -rp "  确认启动？/ launch now? [y/N]: " ok || true
[[ "${ok:-}" =~ ^[Yy] ]] || { echo "已取消 / cancelled"; exit 0; }

IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" \
  --subnet-id "$SUBNET" --security-group-ids "$SG" --key-name "$KEY" \
  --iam-instance-profile Name=source-truth-index-profile \
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${DISK},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=source-truth-host}]' \
  --query 'Instances[0].InstanceId' --output text)"
echo "• launched $IID — waiting for it to run ..."
aws ec2 wait instance-running --instance-ids "$IID"
IP="$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)"
[ -n "$IP" ] && [ "$IP" != None ] || IP="$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

# --- 5. next steps ------------------------------------------------------------------------------
cat <<NEXT

✓ EC2 $IID 已启动（$IP）。这台机器长期保留：它的仓库 .local/ 会存部署状态，以后升级 SSH 回这台、重跑即可。

接下来在这台 EC2 上（部署用这台机器的实例角色，无需配 profile）：
  ssh ubuntu@$IP
  bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)
  cd source-truth
  ./scripts/install.sh                              # 交互：区域/代码仓/模型/飞书凭证
  #   或：./scripts/deploy-all.sh --region $REGION --local

升级版本：SSH 回这台 $IID → cd source-truth && git pull && ./scripts/deploy-all.sh --region $REGION --local
NEXT
