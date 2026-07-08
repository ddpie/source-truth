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
#   5. ask for the SSH key, scp prepare-local-host.sh to the box, and print the one command to run it
#      yourself over ssh (installs deps, logs gh in, clones, runs install.sh) — you watch it live
#
# The EC2 is LONG-LIVED and holds the deployment state in its repo's .local/ (deploy-config +
# projects.json), so later upgrades = SSH back into the SAME box and re-run deploy-all --local.
# If a source-truth-host already exists (e.g. a prior run died before deploy finished), this REUSES
# it by default — ensures IAM, then deploys onto that box the same way. Pass --new-host to force
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

# The branch this launch-host is running from — passed to prepare-local-host.sh so the EC2 checks
# out the SAME code, not a stale main. Falls back to main if we can't tell (not a git checkout).
REPO_REF="$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
[ -n "$REPO_REF" ] && [ "$REPO_REF" != HEAD ] || REPO_REF=main

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
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) say err "unknown flag: $1"; sed -n '2,25p' "$0"; exit 2 ;;
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

# print_manual_fallback <ip> : if we can't scp/run for you (no key / SSH failed), print the two
# SHORT commands to do it by hand. Kept short on purpose — the old one-long-line form got mangled by
# terminal line-wrapping on paste.
print_manual_fallback() {
  local ip="$1"
  cat >&2 <<NEXT
  手动部署（把 <你的key>.pem 换成你的私钥）：
    # ① 本机：把脚本传上去
    scp -i <你的key>.pem "$HERE/lib/prepare-local-host.sh" ubuntu@${ip}:/tmp/
    # ② 本机：SSH 登录机器
    ssh -t -i <你的key>.pem ubuntu@${ip}
    # ③ 登录后在机器上运行（region 由机器自动检测，无需传）
    REPO_REF=${REPO_REF} bash /tmp/prepare-local-host.sh
NEXT
}

# deploy_to_host <instance-id> <ip> : scp prepare-local-host.sh onto the box, then hand the operator
# the one command to run it themselves over ssh. We upload for you (we have the key), but DON'T
# auto-run — running it interactively lets you watch each step and handle a hiccup (e.g. a preflight
# stop) on the spot. Ask for the SSH key (launch-host only knows the key-pair NAME, not its path);
# blank / a failed connect still prints the manual scp+ssh pair.
deploy_to_host() {
  local iid="$1" ip="$2" key def
  cat >&2 <<NEXT

✓ EC2 ${iid}（${ip}）。这台机器长期保留：它的仓库 .local/ 会存部署状态，以后升级登录同一台机器重跑即可。
NEXT
  if [ "$DRY_RUN" = true ]; then
    say info "[dry-run] would scp scripts/lib/prepare-local-host.sh to ubuntu@${ip} and run it (installs deps, gh login, clone, install.sh)"
    return 0
  fi
  # KEY is the chosen key-pair name on the launch path; on the reuse path it's unset — default blank.
  def=""; [ -n "${KEY:-}" ] && def="$HOME/.ssh/${KEY}.pem"
  read -e -rp "  SSH 私钥路径（用于把部署脚本传上去；留空=稍后手动）[${def}]: " key || true
  key="${key:-$def}"
  # `read` does NOT expand a leading ~ (tilde), so a hand-typed ~/.ssh/foo.pem would be taken
  # literally and fail the -f check below. Expand ~ / ~user ourselves. (The ~ in these case
  # patterns is a literal we're matching against the input — not shell tilde expansion; SC2088 N/A.)
  # shellcheck disable=SC2088
  case "$key" in
    "~") key="$HOME" ;;
    "~/"*) key="$HOME/${key#\~/}" ;;
    "~"*) key="$(eval echo "$key")" ;;   # ~otheruser/... — let the shell resolve the home dir
  esac
  if [ -z "$key" ] || [ ! -f "$key" ]; then
    [ -n "$key" ] && say warn "私钥文件不存在：$key"
    say info "跳过自动部署。请手动执行："
    print_manual_fallback "$ip"
    return 0
  fi
  local sshopt=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -i "$key")
  # Fresh instance: SSH may not answer for a bit. Bounded backoff, not back-to-back.
  say step "等待 SSH 就绪 ..."
  local ok=false i
  for i in $(seq 1 24); do   # ~120s: a fresh EC2's cloud-init can take >60s to open sshd
    if ssh "${sshopt[@]}" -o BatchMode=yes ubuntu@"$ip" true 2>/dev/null; then ok=true; break; fi
    sleep 5
  done
  if [ "$ok" != true ]; then
    say warn "SSH 暂时连不上 $ip。常见原因：① 私钥不对；② 安全组的 22 端口放行的不是你真实出口 IP（launch-host 用 curl checkip 取，经 NAT/代理可能不准——到控制台核对）；③ 机器还没起好。稍后手动执行："
    print_manual_fallback "$ip"; return 0
  fi
  say step "把部署脚本传到 EC2（/tmp/prepare-local-host.sh）..."
  if ! scp "${sshopt[@]}" "$HERE/lib/prepare-local-host.sh" ubuntu@"$ip":/tmp/prepare-local-host.sh; then
    say warn "scp 失败。请手动执行："; print_manual_fallback "$ip"; return 0
  fi
  say ok "脚本已上传。接下来 SSH 进机器、手动运行它（能看到每一步；卡住就地处理，断了重连再跑即可）："
  cat >&2 <<NEXT

  ssh -t -i ${key} ubuntu@${ip}
  # 登录后，在机器上运行（region 由机器自动检测，无需传）：
  REPO_REF=${REPO_REF} bash /tmp/prepare-local-host.sh
NEXT
}

# --- 1. profile (menu-picked; not pre-filled — pick is cheap and the account isn't known yet) ---
if [ -z "$PROFILE" ]; then
  # bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
  PROFILES=(); while IFS= read -r _line; do PROFILES+=("$_line"); done \
    < <(aws configure list-profiles 2>/dev/null || true)
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
  "$HERE/lib/create-iam.sh" --profile "$PROFILE" --region "$REGION"
fi

# --- 2b. GitHub token → Secrets Manager --------------------------------------------------------
# The EC2 runs the whole deploy itself, so it needs GitHub access to clone the repo, `gh release
# download` the codegraph binary, and pull on upgrade. We stash a token in Secrets Manager here (on
# your machine, which has both AWS access and — usually — a logged-in gh); step ② pulls it back via
# the instance role, so the token never appears in the printed command. Reuse the operator's local
# gh token; else prompt. Blank = public repo → skip (step ② then just clones directly).
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
  else
    say info "未提供 GitHub token —— 按公开仓处理（clone 时若为私有仓会失败）"
  fi
  unset GH_TOK
fi

# Only one host is meant to exist (it holds the deploy state). If one is already up — e.g. a prior
# run that died after launch but before deploy finished — REUSE it by default: IAM is now ensured
# above, so we just deploy onto that box (scp + run the prepare script). Pass --new-host to force one.
# bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
EXISTING=(); while IFS= read -r _line; do EXISTING+=("$_line"); done < <(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=source-truth-host" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' --output text 2>/dev/null | grep -v '^[[:space:]]*$' || true)
if [ "${#EXISTING[@]}" -gt 0 ] && [ "$NEW_HOST" != true ]; then
  say info "发现已有 source-truth-host，复用它（不再起新机；要强制新建用 --new-host）："
  printf '    %s\n' "${EXISTING[@]}" >&2
  read -r EX_ID EX_STATE EX_IP <<<"${EXISTING[0]}"
  if [ "$DRY_RUN" = true ]; then
    say info "[dry-run] would reuse $EX_ID (state=$EX_STATE) and deploy onto it (scp + run prepare-local-host.sh)"
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
  deploy_to_host "$EX_ID" "$EX_IP"
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

# bash 3.2 (stock macOS) has no mapfile — while-read keeps the deploy box portable.
KEYS=(); while IFS= read -r _line; do KEYS+=("$_line"); done \
  < <(aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text 2>/dev/null | tr '\t' '\n')
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

# --- 5. deploy to the host (scp prepare-local-host.sh + run it) ---------------------------------
deploy_to_host "$IID" "$IP"
