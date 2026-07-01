#!/usr/bin/env bash
# test_prepare_local_host.sh — static checks for prepare-local-host.sh + launch-host's scp/run flow.
# No AWS, no SSH. Pure grep/bash -n.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/prepare-local-host.sh"
L="$ROOT/scripts/launch-host.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_prepare_local_host:"

bash -n "$P"; check "prepare parses" $?
grep -q 'REGION' "$P" && grep -q 'is required' "$P"; check "REGION required (fails loud if unset)" $?
# installs the deps install.sh checks for
grep -q 'awscli-exe-linux' "$P"; check "installs AWS CLI v2" $?
grep -q 'docker.io' "$P"; check "installs docker" $?
grep -q 'apt-get install -y git' "$P"; check "ensures git" $?
# token via Secrets Manager + here-string (not argv), never in the process list
grep -q 'secretsmanager get-secret-value' "$P"; check "reads token from Secrets Manager" $?
grep -q 'gh auth login --with-token <<<"\$T"' "$P"; check "gh login via here-string (token not in argv)" $?
grep -q 'gh auth setup-git' "$P"; check "wires gh into git for private clone" $?
# docker group takes effect via sg (usermod alone needs a fresh login)
grep -q "sg docker -c './scripts/install.sh'" "$P"; check "runs install under sg docker (group live now)" $?
# it clones (or pulls) the repo
grep -qE 'git clone|git -C .* pull' "$P"; check "clones or pulls the repo" $?

echo "test_launch_host_deploy_flow:"
bash -n "$L"; check "launch-host parses" $?
# launch-host scp's the prepare script up and runs it, instead of a long inline command
grep -qE 'scp .*prepare-local-host\.sh' "$L"; check "launch-host scp's prepare-local-host.sh" $?
grep -q 'bash /tmp/prepare-local-host.sh' "$L"; check "launch-host runs the prepared script over ssh" $?
# asks for the private key (launch-host doesn't know its path)
grep -q 'SSH 私钥路径' "$L"; check "asks for the SSH private key path" $?
# manual fallback prints TWO short commands (scp + ssh), not one long line
grep -q 'print_manual_fallback' "$L"; check "has a manual fallback" $?
# reuse-path KEY may be unset → must be guarded under set -u
grep -q '\${KEY:-}' "$L"; check "guards KEY (unset on reuse path) under set -u" $?

[[ "$_fail" -eq 0 ]]; exit $?
