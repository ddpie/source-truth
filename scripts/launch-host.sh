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
#   5. print the SSH + deploy command to run next
#
# The EC2 is LONG-LIVED and holds the deployment state in its repo's .local/ (deploy-config +
# projects.json), so later upgrades = SSH back into the SAME box and re-run deploy-all --local.
# If a source-truth-host already exists (e.g. a prior run died before deploy finished), this REUSES
# it by default — ensures IAM, then prints the step-② command for that box. Pass --new-host to force
# launching another. Prior choices (region / type / disk / SSH CIDR / key) are remembered in
# .local/launch-host.env and pre-filled on re-run.
#
#   scripts/launch-host.sh                 # fully interactive (reuse existing host if any)
#   scripts/launch-host.sh --profile admin --region ap-northeast-1   # skip those two prompts
#   scripts/launch-host.sh --new-host      # force a brand-new host even if one exists
#   scripts/launch-host.sh --dry-run       # print what it would create/launch, change nothing
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/lib/env-utils.sh"

# Prior-choice state for pre-fill is per-account (set once ACCOUNT is known, below): keys like the
# SSH key name / CIDR / region only make sense within one account, so a single shared file would
# cross-fill wrong values when an operator switches accounts. (gitignored under .local/)
STATE=""

PROFILE="" REGION="" NEW_HOST=false DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region)  REGION="${2:-}"; shift 2 ;;
    --new-host) NEW_HOST=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) say err "unknown flag: $1"; sed -n '2,24p' "$0"; exit 2 ;;
  esac
done

# Hard deps. aws/curl are used directly here; mktemp stages the network config; ssh/git run in the
# command we print for step ② (on the EC2), so they're advisory locally, not required.
require_cmd aws "install AWS CLI v2" || exit 1
require_cmd curl "needed to detect your egress IP for the SSH rule" || exit 1
require_cmd mktemp || exit 1

# pick_one <prompt> <default-value> <value...> : numbered menu on stderr, chosen value on stdout.
# Empty <default-value> = no default (must pick). A non-empty default is pre-selected: pressing
# enter takes it, and the menu marks it. Matching is on each option's leading whitespace token.
pick_one() {
  local prompt="$1" def="$2"; shift 2
  local opts=("$@") choice i=1 mark
  {
    echo "$prompt"
    for o in "${opts[@]}"; do
      mark=' '; [[ -n "$def" && "${o%%[[:space:]]*}" == "$def" ]] && mark='*'
      echo "  $i)$mark $o"; i=$((i+1))
    done
    [[ -n "$def" ]] && echo "  （回车=默认 $def / enter for default）"
  } >&2
  while true; do
    read -rp "  # " choice >&2 || true
    [[ -z "$choice" && -n "$def" ]] && { echo "$def"; return; }
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#opts[@]} )) && { echo "${opts[$((choice-1))]}"; return; }
    echo "  请输入 1-${#opts[@]}（或回车取默认）/ enter 1-${#opts[@]} (or enter for default)" >&2
  done
}

# remote_deploy_script <gh_ready> : assemble the script that runs ON the EC2 for step ②.
# When gh_ready=true, it first pulls the GitHub token from Secrets Manager (via THIS host's instance
# role — no token in the command text), installs gh if missing, logs in, and wires gh into git; then
# clones-or-pulls the repo and runs install.sh. When false (public repo / no token), it just
# clones-or-pulls + install.sh. All $-vars stay literal here (single-quoted at the ssh call site).
remote_deploy_script() {
  local clone='command -v git >/dev/null || sudo apt-get install -y git; if [ -d source-truth/.git ]; then git -C source-truth pull --ff-only; else git clone https://github.com/ddpie/source-truth.git; fi'
  if [ "${1:-false}" = true ]; then
    cat <<'REMOTE'
command -v aws >/dev/null || { command -v unzip >/dev/null || sudo apt-get install -y unzip; curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip && (cd /tmp && unzip -oq awscliv2.zip && sudo ./aws/install --update) && rm -rf /tmp/aws /tmp/awscliv2.zip; }; T=$(aws secretsmanager get-secret-value --region REGION_PLACEHOLDER --secret-id source-truth/deploy-github-token --query SecretString --output text 2>/dev/null || true); if [ -n "$T" ]; then command -v gh >/dev/null || { sudo mkdir -p -m 755 /etc/apt/keyrings && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && sudo apt-get update && sudo apt-get install -y gh; }; gh auth login --with-token <<<"$T" && gh auth setup-git; fi; CLONE_PLACEHOLDER && cd source-truth && ./scripts/install.sh
REMOTE
  else
    printf '%s && cd source-truth && ./scripts/install.sh\n' "$clone"
  fi
}

# print_next_steps <instance-id> <ip> <gh_ready> : the step-② command to run ON the host. One
# pasteable ssh -t one-liner (tty for the interactive installer). Shared by the launch path and the
# reuse path so the two never drift.
print_next_steps() {
  local iid="$1" ip="$2" gh_ready="${3:-false}"
  local clone='command -v git >/dev/null || sudo apt-get install -y git; if [ -d source-truth/.git ]; then git -C source-truth pull --ff-only; else git clone https://github.com/ddpie/source-truth.git; fi'
  local remote; remote="$(remote_deploy_script "$gh_ready")"
  remote="${remote//CLONE_PLACEHOLDER/$clone}"
  remote="${remote//REGION_PLACEHOLDER/$REGION}"
  cat <<NEXT

✓ EC2 ${iid}（${ip}）。这台机器长期保留：它的仓库 .local/ 会存部署状态，以后升级 SSH 回这台、重跑即可。

下一步：复制这一条命令跑（在这台 EC2 上部署，用它的实例角色，无需配 profile；命令里不含任何 token）：

  ssh -t ubuntu@${ip} '${remote}'

（SSH 密钥不在 ssh-agent 里就加 -i：ssh -t -i <你的 key>.pem ubuntu@${ip} '...'）
install.sh 会交互问：AWS 区域、代码仓、回答模型、飞书 App ID/Secret——先把飞书凭证准备好。

升级版本：SSH 回这台 ${iid}，跑：cd source-truth && git pull && ./scripts/deploy-all.sh --region ${REGION} --local
NEXT
}

# --- 1. profile (menu-picked; not pre-filled — pick is cheap and the account isn't known yet) ---
if [ -z "$PROFILE" ]; then
  mapfile -t PROFILES < <(aws configure list-profiles 2>/dev/null || true)
  [ "${#PROFILES[@]}" -gt 0 ] || { say err "no AWS profiles (run aws configure / SSO, or pass --profile)."; exit 1; }
  PROFILE="$(pick_one "选择 AWS profile / pick the AWS profile:" "" "${PROFILES[@]}")"
fi
export AWS_PROFILE="$PROFILE"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { say err "profile '$PROFILE' credentials not working (try: aws sso login --profile $PROFILE)."; exit 1; }

# Now that the account is known, load THIS account's prior choices for pre-fill (region/type/disk/
# cidr/key). Absent file (first run / new account) → all LH_* unset → fallbacks below.
STATE="$HERE/../.local/launch-host.${ACCOUNT}.env"
safe_source_env "$STATE" 2>/dev/null || true

if [ -z "$REGION" ]; then
  DEF="${LH_REGION:-$(aws configure get region 2>/dev/null || echo ap-northeast-1)}"
  read -rp "AWS region [${DEF}]: " REGION || true; REGION="${REGION:-$DEF}"
fi
export AWS_DEFAULT_REGION="$REGION"
dr=""; [ "$DRY_RUN" = true ] && dr="  (dry-run)"
say info "profile=$PROFILE  account=$ACCOUNT  region=$REGION${dr}"

# --- 2. IAM (reuse create-iam.sh; idempotent) ---------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  say info "[dry-run] would ensure IAM role + profile via create-iam.sh"
else
  say step "ensuring IAM roles (create-iam.sh) ..."
  "$HERE/create-iam.sh" --profile "$PROFILE" --region "$REGION"
fi

# --- 2b. GitHub token → Secrets Manager --------------------------------------------------------
# The EC2 runs the whole deploy itself, so it needs GitHub access to clone the repo, `gh release
# download` the codegraph binary, and pull on upgrade. We stash a token in Secrets Manager here (on
# your machine, which has both AWS access and — usually — a logged-in gh); step ② pulls it back via
# the instance role, so the token never appears in the printed command. Reuse the operator's local
# gh token; else prompt. Blank = public repo → skip (step ② then just clones directly).
GH_TOKEN_READY=false
if [ "$DRY_RUN" = true ]; then
  say info "[dry-run] would stash a GitHub token in source-truth/deploy-github-token (or skip for a public repo)"
else
  GH_TOK="$(gh auth token 2>/dev/null || true)"
  if [ -z "$GH_TOK" ]; then
    say info "未检测到本机 gh 登录态。私有仓需要一个只读 GitHub token（scope 仅需 repo:read）；公开仓可留空跳过。"
    read -rsp "  GitHub token（留空 = 公开仓，跳过）: " GH_TOK || true; echo >&2
  fi
  if [ -n "$GH_TOK" ]; then
    # Pass the token via stdin (file:///dev/stdin), NOT --secret-string "$GH_TOK": a command-line
    # argument is visible to other users on this machine via `ps` / /proc/<pid>/cmdline.
    if aws secretsmanager describe-secret --secret-id source-truth/deploy-github-token >/dev/null 2>&1; then
      printf '%s' "$GH_TOK" | aws secretsmanager put-secret-value --secret-id source-truth/deploy-github-token --secret-string file:///dev/stdin >/dev/null
    else
      printf '%s' "$GH_TOK" | aws secretsmanager create-secret --name source-truth/deploy-github-token --secret-string file:///dev/stdin >/dev/null
    fi
    say ok "GitHub 凭证已写入 Secrets Manager（source-truth/deploy-github-token）"
    GH_TOKEN_READY=true
  else
    say info "未提供 GitHub token —— 按公开仓处理（第二步直接 clone）"
  fi
  unset GH_TOK
fi

# Only one host is meant to exist (it holds the deploy state). If one is already up — e.g. a prior
# run that died after launch but before deploy finished — REUSE it by default: IAM is now ensured
# above, so just hand back the step-② command to run on that box. Pass --new-host to force a second.
mapfile -t EXISTING < <(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=source-truth-host" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' --output text 2>/dev/null | grep -v '^[[:space:]]*$' || true)
if [ "${#EXISTING[@]}" -gt 0 ] && [ "$NEW_HOST" != true ]; then
  say info "发现已有 source-truth-host，复用它（不再起新机；要强制新建用 --new-host）："
  printf '    %s\n' "${EXISTING[@]}" >&2
  read -r EX_ID EX_STATE EX_IP <<<"${EXISTING[0]}"
  if [ "$DRY_RUN" = true ]; then
    say info "[dry-run] would reuse $EX_ID (state=$EX_STATE) and print its step-② command"
    exit 0
  fi
  # A stopped box must be started before you can SSH in.
  if [ "$EX_STATE" = stopped ] || [ "$EX_STATE" = stopping ]; then
    say info "实例当前 ${EX_STATE}，正在启动 / starting it ..."
    aws ec2 start-instances --instance-ids "$EX_ID" >/dev/null
    aws ec2 wait instance-running --instance-ids "$EX_ID"
  fi
  EX_IP="$(aws ec2 describe-instances --instance-ids "$EX_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)"
  [ -n "$EX_IP" ] && [ "$EX_IP" != None ] || EX_IP="$(aws ec2 describe-instances --instance-ids "$EX_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  print_next_steps "$EX_ID" "$EX_IP" "$GH_TOKEN_READY"
  exit 0
fi

# --- 3. network (auto-create source-truth VPC/subnets/IGW/NAT) + host SG + key/type ------------
if [ "$DRY_RUN" = true ]; then
  say info "[dry-run] would ensure source-truth network (VPC / public+private subnets / IGW / NAT) via provision_network.sh"
  say info "[dry-run] would ensure a source-truth-host SG opening 22 to your IP, pick key/type, and launch one EC2 in the public subnet"
  exit 0
fi
# Reuse the same provisioner the default path uses — it's idempotent, reconciles by tag, and has
# the NAT/EIP/route edge cases already handled. It writes IDs into a throwaway temp file we read back.
TMPCFG="$(mktemp)"; trap 'rm -f "$TMPCFG"' EXIT
say step "ensuring source-truth network (VPC / public+private subnets / IGW / NAT; reuses existing) ..."
"$HERE/lib/provision_network.sh" "$REGION" "$TMPCFG"
# shellcheck disable=SC1090
source "$TMPCFG"   # sets VPC_ID PUBLIC_SUBNET PRIVATE_SUBNET NAT_GATEWAY VPC_CIDR
[ -n "${VPC_ID:-}" ] && [ -n "${PUBLIC_SUBNET:-}" ] \
  || { say err "network provisioning did not yield VPC/public subnet (see output above)."; exit 1; }

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

# SSH source CIDR: default to last run's, else this operator's egress IP (/32); overridable.
MYIP="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
DEFCIDR="${LH_SSHCIDR:-${MYIP:+$MYIP/32}}"
read -rp "允许 SSH(22) 的来源 CIDR / source CIDR allowed to SSH [${DEFCIDR:-必填/required}]: " SSHCIDR || true
SSHCIDR="${SSHCIDR:-$DEFCIDR}"
[[ "$SSHCIDR" =~ ^[0-9.]+/[0-9]+$ ]] || { say err "需要一个 CIDR（如 1.2.3.4/32）/ need a CIDR like 1.2.3.4/32."; exit 2; }
# Match any existing rule that already covers 22 for this CIDR — exact :22 OR a range OR all-traffic
# (-1, no FromPort). Skipping only the exact-FromPort==22 case would re-authorize over a broader
# rule and hit Duplicate. Belt-and-suspenders: also tolerate the Duplicate error itself.
if ! aws ec2 describe-security-groups --group-ids "$SG" \
     --query "SecurityGroups[0].IpPermissions[?(IpProtocol=='-1') || (FromPort<=\`22\` && ToPort>=\`22\`)].IpRanges[].CidrIp" \
     --output text 2>/dev/null | tr '\t' '\n' | grep -qx "$SSHCIDR"; then
  auth_err="$(aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "$SSHCIDR" 2>&1 >/dev/null)" \
    || { [[ "$auth_err" == *Duplicate* ]] || { say err "failed to open SSH 22 for $SSHCIDR on $SG: $auth_err"; exit 1; }; }
fi

mapfile -t KEYS < <(aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n')
if [ "${#KEYS[@]}" -eq 0 ]; then
  say err "no EC2 key pair in $REGION — you need one to SSH in. Create one, e.g.:"
  say err "  aws ec2 create-key-pair --region $REGION --key-name source-truth --query KeyMaterial --output text > source-truth.pem && chmod 600 source-truth.pem"
  say err "then re-run launch-host.sh."
  exit 1
fi
KEY="$(pick_one "选择 SSH 密钥对 / pick an SSH key pair:" "${LH_KEY:-}" "${KEYS[@]}")"

ITYPE="$(pick_one "选择机型（ARM/Graviton）/ pick an instance type (ARM):" "${LH_ITYPE:-t4g.large}" \
  "t4g.large" "t4g.xlarge" "m7g.large" "m7g.xlarge" "m7g.2xlarge")"
DEFDISK="${LH_DISK:-30}"
read -rp "根卷大小 GiB / root volume GiB [${DEFDISK}]: " DISK || true; DISK="${DISK:-$DEFDISK}"
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK>=8 )) || { say err "根卷需为 >=8 的整数 GiB / root volume must be an integer GiB >= 8."; exit 2; }

# Latest Ubuntu 24.04 ARM64 AMI (Canonical owner id), same source as the default deploy path.
AMI="$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text 2>/dev/null)"
if [ -z "$AMI" ] || [ "$AMI" = None ]; then
  say err "no Ubuntu 24.04 arm64 AMI found in $REGION via describe-images. Try the Canonical SSM parameter:"
  say err "  aws ssm get-parameter --region $REGION --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text"
  say err "then pass it as --image-id to run-instances manually (see runbook)."
  exit 1
fi

# Remember these for next time (per account). Saved BEFORE the launch confirmation below — so even
# if you cancel at the confirm step, the choices are pre-filled next run (nothing was launched).
mkdir -p "$(dirname "$STATE")"
update_env "$STATE" LH_REGION  "$REGION"
update_env "$STATE" LH_ITYPE   "$ITYPE"
update_env "$STATE" LH_DISK    "$DISK"
update_env "$STATE" LH_SSHCIDR "$SSHCIDR"
update_env "$STATE" LH_KEY     "$KEY"

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
[[ "${ok:-}" =~ ^[Yy] ]] || { say warn "已取消 / cancelled"; exit 0; }

IID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" \
  --subnet-id "$PUBLIC_SUBNET" --associate-public-ip-address --security-group-ids "$SG" --key-name "$KEY" \
  --iam-instance-profile Name=source-truth-index-profile \
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${DISK},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=source-truth-host}]' \
  --query 'Instances[0].InstanceId' --output text)"
say info "launched $IID — waiting for it to run ..."
aws ec2 wait instance-running --instance-ids "$IID"
IP="$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)"
[ -n "$IP" ] && [ "$IP" != None ] || IP="$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

# --- 5. next steps ------------------------------------------------------------------------------
print_next_steps "$IID" "$IP" "$GH_TOKEN_READY"
