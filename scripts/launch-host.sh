#!/usr/bin/env bash
# launch-host.sh — one-shot bootstrap for the single-EC2 (`--local`) deployment, run on YOUR machine.
#
# It chains the steps that come before `deploy-all.sh --local`:
#   1. pick an AWS profile (SELECT from your configured profiles — no credentials typed)
#   2. create (or reuse) the EC2 instance role + profile via create-iam.sh
#   3. auto-create the source-truth network (VPC / public+private subnets / IGW / NAT — reused if
#      present) + a host security group that allows your SSH on 22; pick key pair + instance type
#   4. launch ONE ARM64 Ubuntu 24.04 EC2 in the PUBLIC subnet (public IP for SSH), instance profile
#      attached + IMDSv2 required. The AgentCore runtime later lands in the PRIVATE subnet (NAT egress
#      to Bedrock) — a VPC-mode runtime ENI has no public IP, so it can't reach Bedrock via the IGW.
#   5. print the SSH + deploy commands to run next
#
# The EC2 is LONG-LIVED and holds the deployment state in its repo's .local/ (deploy-config +
# projects.json), so later upgrades = SSH back into the SAME box and re-run deploy-all --local.
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

# --- 3. network (auto-create source-truth VPC/subnets/IGW/NAT) + host SG + key/type ------------
# Reuse the same provisioner the default path uses — it's idempotent, reconciles by tag, and has
# the NAT/EIP/route edge cases already handled. It needs a config file to write IDs into; we use a
# throwaway temp file and read the IDs back from it.
TMPCFG="$(mktemp)"; trap 'rm -f "$TMPCFG"' EXIT
echo "▶ ensuring source-truth network (VPC / public+private subnets / IGW / NAT; reuses existing) ..."
"$HERE/lib/provision_network.sh" "$REGION" "$TMPCFG"
# shellcheck disable=SC1090
source "$TMPCFG"   # sets VPC_ID PUBLIC_SUBNET PRIVATE_SUBNET NAT_GATEWAY VPC_CIDR
[ -n "${VPC_ID:-}" ] && [ -n "${PUBLIC_SUBNET:-}" ] \
  || { echo "✗ network provisioning did not yield VPC/public subnet (see output above)." >&2; exit 1; }

# Host SG (describe-or-create): opens 22 to the operator only. The runtime uses a separate
# self-referencing SG (source-truth-index-svc) created later by the index-service phase.
SG="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=source-truth-host" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
if [ "$SG" = None ] || [ -z "$SG" ]; then
  SG="$(aws ec2 create-security-group --group-name source-truth-host \
    --description "source-truth --local host (operator SSH)" --vpc-id "$VPC_ID" \
    --query GroupId --output text)"
  aws ec2 create-tags --resources "$SG" --tags Key=Name,Value=source-truth-host >/dev/null
fi

# SSH source CIDR: default to this operator's egress IP (/32), but allow overriding (e.g. an office
# range). Add the ingress only if absent — idempotent across re-runs.
MYIP="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
DEFCIDR="${MYIP:+$MYIP/32}"
read -rp "允许 SSH(22) 的来源 CIDR / source CIDR allowed to SSH [${DEFCIDR:-必填/required}]: " SSHCIDR || true
SSHCIDR="${SSHCIDR:-$DEFCIDR}"
[[ "$SSHCIDR" =~ ^[0-9.]+/[0-9]+$ ]] || { echo "✗ 需要一个 CIDR（如 1.2.3.4/32）/ need a CIDR like 1.2.3.4/32." >&2; exit 2; }
# Match any existing rule that already covers 22 for this CIDR — exact :22 OR a range OR all-traffic
# (-1, no FromPort). Skipping only the exact-FromPort==22 case would re-authorize over a broader
# rule and hit Duplicate. Belt-and-suspenders: also tolerate the Duplicate error itself.
if ! aws ec2 describe-security-groups --group-ids "$SG" \
     --query "SecurityGroups[0].IpPermissions[?(IpProtocol=='-1') || (FromPort<=\`22\` && ToPort>=\`22\`)].IpRanges[].CidrIp" \
     --output text 2>/dev/null | tr '\t' '\n' | grep -qx "$SSHCIDR"; then
  auth_err="$(aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$SSHCIDR" 2>&1 >/dev/null)" \
    || { [[ "$auth_err" == *Duplicate* ]] || { echo "✗ failed to open SSH 22 for $SSHCIDR on $SG: $auth_err" >&2; exit 1; }; }
fi

mapfile -t KEYS < <(aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n')
[ "${#KEYS[@]}" -gt 0 ] || { echo "✗ no EC2 key pair in $REGION — create one first (you need it to SSH in)." >&2; exit 1; }
KEY="$(pick_one "选择 SSH 密钥对 / pick an SSH key pair:" "${KEYS[@]}")"

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
    vpc           $VPC_ID
    subnet        $PUBLIC_SUBNET (public — instance gets a public IP for SSH)
    type / disk   $ITYPE / ${DISK}GiB   AMI $AMI
    key / sg      $KEY / $SG (SSH 22 from $SSHCIDR)
    profile(role) source-truth-index-profile  ·  IMDSv2 required
SUMMARY
read -rp "  确认启动？/ launch now? [y/N]: " ok || true
[[ "${ok:-}" =~ ^[Yy] ]] || { echo "已取消 / cancelled"; exit 0; }

IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" \
  --subnet-id "$PUBLIC_SUBNET" --associate-public-ip-address --security-group-ids "$SG" --key-name "$KEY" \
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
# One pasteable command for step ②: ssh in (with a tty so the interactive installer works), clone or
# refresh the repo, then run install.sh. No $-vars inside the single-quoted remote script, so this
# heredoc doesn't expand them locally. Add -i <your-key.pem> if your key isn't in ssh-agent.
cat <<NEXT

✓ EC2 $IID 已启动（$IP）。这台机器长期保留：它的仓库 .local/ 会存部署状态，以后升级 SSH 回这台、重跑即可。

下一步：复制这一条命令跑（在这台 EC2 上部署，用它的实例角色，无需配 profile；交互填区域/代码仓/模型/飞书凭证）：

  ssh -t ubuntu@$IP 'if [ -d source-truth/.git ]; then git -C source-truth pull --ff-only; else git clone --depth 1 https://github.com/ddpie/source-truth.git; fi && cd source-truth && ./scripts/install.sh'

（SSH 密钥不在 ssh-agent 里就加 -i：ssh -t -i <你的 key>.pem ubuntu@$IP '...'）

升级版本：SSH 回这台 $IID，跑：cd source-truth && git pull && ./scripts/deploy-all.sh --region $REGION --local
NEXT
