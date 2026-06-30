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
curl() { case "$*" in *api/token*) echo TOKEN;; *instance-id*) echo i-abc;; *local-ipv4*) echo 10.1.2.3;; *) echo "";; esac; }
[[ "$(imds_field instance-id)" == "i-abc" ]]; check "imds_field reads instance-id" $?
[[ "$(imds_field local-ipv4)" == "10.1.2.3" ]]; check "imds_field reads local-ipv4" $?
# local mode must derive VPC/subnet via describe-instances, NOT IMDS mac paths
grep -q 'describe-instances' "$F"; check "uses describe-instances for vpc/subnet/sg" $?
! grep -q 'macs/.*security-group-ids' "$F"; check "does NOT scrape IMDS mac sg path" $?
# local mode must wrap bootstrap with a timeout
grep -qE 'timeout [0-9].* bash .*bootstrap.sh|run_timeout .* bootstrap.sh' "$F"; check "bootstrap wrapped in a timeout" $?
# A2 fail-loud precheck: read the instance's IAM profile, abort if none, abort if S3 artifact unreadable
grep -q 'IamInstanceProfile.Arn' "$F"; check "local mode reads the instance's IAM profile" $?
grep -q 'NO IAM instance profile' "$F"; check "local mode fails loud when no instance role" $?
grep -q 'cannot read s3' "$F"; check "local mode fails loud when S3 artifact unreadable" $?
[[ "$_fail" -eq 0 ]]; exit $?
