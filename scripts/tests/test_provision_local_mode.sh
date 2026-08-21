#!/usr/bin/env bash
# test_provision_local_mode.sh — static + helper checks for provision_index_service.sh local mode.
# No AWS, no IMDS. Extracts the IMDS helpers and stubs curl.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/scripts/lib/provision_index_service.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_provision_local_mode:"

bash -n "$F"; check "parses" $?
# imds helpers present + extractable (multi-line, closing brace col 0)
HELPER="$(sed -n '/^imds_field() {$/,/^}$/p' "$F"; sed -n '/^imds_token() {$/,/^}$/p' "$F")"
[[ -n "$HELPER" ]]; check "imds helpers extractable" $?
eval "$HELPER"
# 桩校验完整 IMDSv2 契约：token 请求须 PUT 完整 URL；metadata 请求须带 token header
# 且 URL 前缀正确——拼错 URL / 丢 header 都应失败，而不是按子串放行。
curl() {
  local args="$*"
  case "$args" in
    *"http://169.254.169.254/latest/api/token"*)
      [[ "$args" == *"-X PUT"* ]] || return 22
      echo TOKEN ;;
    *"http://169.254.169.254/latest/meta-data/"*)
      [[ "$args" == *"X-aws-ec2-metadata-token: TOKEN"* ]] || return 22
      case "$args" in
        *meta-data/instance-id*) echo i-abc ;;
        *meta-data/local-ipv4*) echo 10.1.2.3 ;;
        *) echo "" ;;
      esac ;;
    *) return 22 ;;
  esac
}
[[ "$(imds_field instance-id)" == "i-abc" ]]; check "imds_field reads instance-id" $?
[[ "$(imds_field local-ipv4)" == "10.1.2.3" ]]; check "imds_field reads local-ipv4" $?
# local mode must derive VPC/subnet via describe-instances, NOT IMDS mac paths.
# 这两条以前是 `grep -q 'describe-instances' "$F"` 和一条否定 grep：前者在全文有 8 处其它
# describe-instances 调用，把整个 local-mode 分支（约 100 行）删掉它依然通过；后者是否定断言，
# 永远不可能失败。改成只在 local-mode 分支内部找，删掉分支就会失败。
_local_block="$(sed -n '/if \[\[ "\$LOCAL_MODE" == "true" \]\]/,/^fi$/p' "$F")"
[[ -n "$_local_block" ]]; check "找到 local-mode 分支" $?
printf '%s' "$_local_block" | grep -q 'describe-instances'
check "local-mode 分支内用 describe-instances 推导 vpc/subnet/sg" $?
printf '%s' "$_local_block" | grep -qv 'macs/.*security-group-ids'
check "local-mode 分支内不刮 IMDS mac sg 路径" $?
# local mode must wrap bootstrap with a timeout; --foreground keeps it in our process group so
# tty access (tee streaming) doesn't get the tree stopped by SIGTTIN/SIGTTOU
grep -qE 'timeout (--foreground )?[0-9].* bash .*bootstrap.sh|run_timeout .* bootstrap.sh' "$F"; check "bootstrap wrapped in a timeout" $?
grep -q 'timeout --foreground' "$F"; check "timeout runs bootstrap in the foreground process group" $?
# A2 fail-loud precheck: read the instance's IAM profile, abort if none, abort if S3 artifact unreadable
grep -q 'IamInstanceProfile.Arn' "$F"; check "local mode reads the instance's IAM profile" $?
grep -q 'NO IAM instance profile' "$F"; check "local mode fails loud when no instance role" $?
grep -q 'cannot read s3' "$F"; check "local mode fails loud when S3 artifact unreadable" $?
# runtime subnet must be the source-truth-private subnet (NAT egress), NOT this host's own subnet —
# a VPC-mode runtime ENI has no public IP and can't reach Bedrock via an IGW.
grep -q 'Name=tag:Name,Values=source-truth-private' "$F"; check "runtime uses the private subnet, not self subnet" $?
grep -q 'no source-truth-private subnet' "$F"; check "fails loud when no private subnet present" $?
[[ "$_fail" -eq 0 ]]; exit $?
