#!/usr/bin/env bash
# Run deployment entrypoints in an isolated checkout with no network/AWS access.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/agent-container" "$T/bin"
cp "$ROOT/scripts/deploy-all.sh" "$T/scripts/"
cp "$ROOT/scripts/lib/"{common.sh,env-utils.sh,resolve_model.sh,deploy_project.sh,deploy_runtime.py,render_manifest.py} "$T/scripts/lib/"
cp "$ROOT/agent-container/agent_settings.py" "$T/agent-container/"
cat > "$T/bin/aws" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AWS_CALLS"
case "$*" in
  *get-caller-identity*) echo 123456789012 ;;
  *describe-regions*) echo ap-northeast-1 ;;
  *list-agent-runtimes*) echo '{}' ;;
  *get-trace-segment-destination*) echo CloudWatchLogs ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH" AWS_CALLS="$T/aws.calls"
run=0 fail=0
check() {
  run=$((run+1))
  if [[ "$2" == 0 ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi
}
: > "$AWS_CALLS"
bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 --max-lifetime 28801 --dry-run > "$T/out" 2>&1
rc=$?
[[ "$rc" == 2 && ! -s "$AWS_CALLS" ]]
check "unsupported lifecycle rejected before any AWS operation" $?
rm -rf "$T/.local"; : > "$AWS_CALLS"
bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 --skip image --dry-run > "$T/out" 2>&1
rc=$?
[[ "$rc" == 0 && ! -e "$T/.local" ]]
check "fresh dry-run succeeds without creating local deployment state" $?
! grep -E 'create-|put-|modify-|update-|send-command|converse|invoke-' "$AWS_CALLS" >/dev/null
check "dry-run performs no mutation or model inference" $?

mkdir -p "$T/.local"
cat > "$T/.local/deploy-config" <<'CONF'
DEPLOY_REGION=ap-northeast-1
ARTIFACT_BUCKET=test-bucket
INDEX_SERVICE_INSTANCE=i-test
INDEX_SERVICE_IP=10.0.0.1
INDEX_SERVICE_SG=sg-test
DEPLOY_WITH_GLOSSARY=false
CONF
cat > "$T/.local/projects.json" <<'JSON'
{"schemaVersion":2,"projects":{"demo":{"port":8080,"repos":[{"subdir":"demo","source":"git","git":"https://example.com/demo.git"}]}}}
JSON
: > "$AWS_CALLS"
bash "$T/scripts/lib/deploy_project.sh" ap-northeast-1 demo > "$T/out" 2>&1
rc=$?
[[ "$rc" != 0 ]] && grep -q PRIVATE_SUBNET "$T/out" && ! grep -q send-command "$AWS_CALLS"
check "missing runtime network fails before modifying the index host" $?
printf 'PRIVATE_SUBNET=subnet-test\nDEPLOY_MAX_LIFETIME=86400\n' >> "$T/.local/deploy-config"
: > "$AWS_CALLS"
bash "$T/scripts/lib/deploy_project.sh" ap-northeast-1 demo > "$T/out" 2>&1
rc=$?
[[ "$rc" == 2 ]] && grep -q 'max-lifetime' "$T/out" && ! grep -q send-command "$AWS_CALLS"
check "direct redeploy validates persisted lifecycle before changing the host" $?
printf 'DEPLOY_MAX_LIFETIME=28800\n' >> "$T/.local/deploy-config"
: > "$AWS_CALLS"
bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 --skip image --skip index-svc \
  --with-glossary --dry-run > "$T/out" 2>&1
rc=$?
[[ "$rc" == 2 ]] && grep -q 'skip index-svc' "$T/out"
check "changed host glossary options cannot be combined with skipping that host phase" $?

cat > "$T/.local/projects.json" <<'JSON'
{"schemaVersion":2,"projects":{"first":{"port":8080,"repos":[{"subdir":"same","source":"local"}]},"second":{"port":8081,"repos":[{"subdir":"same","source":"local"}]}}}
JSON
bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 --skip image --dry-run > "$T/out" 2>&1
rc=$?
[[ "$rc" == 2 ]] && grep -q 'subdir' "$T/out"
check "shared repository subdirs across projects fail in preflight" $?
: > "$AWS_CALLS"
bash "$T/scripts/lib/deploy_project.sh" ap-northeast-1 second > "$T/out" 2>&1
rc=$?
[[ "$rc" == 2 ]] && grep -q 'subdir' "$T/out" && [[ ! -s "$AWS_CALLS" ]]
check "direct project deployment rejects shared subdirs before contacting AWS" $?

cat > "$T/.local/projects.json" <<'JSON'
{"schemaVersion":2,"projects":{"first":{"port":8080,"repos":[{"subdir":"first","source":"local"}]},"second":{"port":8080,"repos":[{"subdir":"second","source":"local"}]}}}
JSON
for entry in all direct; do
  : > "$AWS_CALLS"
  if [[ "$entry" == all ]]; then
    bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 --skip image --dry-run > "$T/out" 2>&1
  else
    bash "$T/scripts/lib/deploy_project.sh" ap-northeast-1 second > "$T/out" 2>&1
  fi
  rc=$?
  [[ "$rc" == 2 ]] && grep -q 'port 8080 shared' "$T/out" && ! grep -q 'send-command' "$AWS_CALLS"
  check "$entry deployment rejects shared ports before any SSM mutation" $?
done

# A concurrent base re-bootstrap owns the same live tree. Exercise the actual
# project payload prefix up through its first AWS operation; all paths are temp.
python3 - "$ROOT/scripts/lib/deploy_project.sh" "$T/prefix.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
prefix = source.split('REMOTE_CMD="', 1)[1].split("# rsync is REQUIRED", 1)[0]
Path(sys.argv[2]).write_text('REMOTE_CMD="' + prefix + '"\neval "$REMOTE_CMD"\n')
PY
: > "$AWS_CALLS"
(
  exec 9>"$T/host.lock"
  flock -n 9 || exit 1
  export REBOOT_LOCK_FILE="$T/host.lock" ARTIFACT_BUCKET=test REGION=ap-northeast-1
  bash "$T/prefix.sh" > "$T/out" 2>&1
); rc=$?
[[ "$rc" == 75 && ! -s "$AWS_CALLS" ]]
check "project activation refuses to publish while a base re-bootstrap holds the host lock" $?

# Monitoring is a deployment choice, independent of the index host's baked-in
# glossary settings. Exercise the real CLI and config writer, then start a new
# process without a monitoring flag to verify persistence rather than just logs.
printf '{"schemaVersion":2,"projects":{}}\n' > "$T/.local/projects.json"
run_monitoring_config() {
  bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 \
    --skip artifacts --skip iam --skip network --skip index-svc \
    --skip image --skip projects "$@" > "$T/out" 2>&1
}
for previous in true false; do
  wanted=true; [[ "$previous" == true ]] && wanted=false
  cat > "$T/.local/deploy-config" <<CONF
DEPLOY_REGION=ap-northeast-1
INDEX_SERVICE_INSTANCE=i-test
DEPLOY_WITH_GLOSSARY=false
DEPLOY_GLOSSARY_MAX_FILES=400
DEPLOY_WITH_MONITORING=$previous
CONF
  cp "$T/.local/deploy-config" "$T/config-before"
  : > "$AWS_CALLS"
  run_monitoring_config "--with-monitoring=$wanted" --dry-run
  rc=$?
  [[ "$rc" == 0 ]] && cmp -s "$T/config-before" "$T/.local/deploy-config"
  check "monitoring $previous to $wanted with --skip index-svc: dry-run leaves config unchanged" $?

  run_monitoring_config "--with-monitoring=$wanted"
  rc=$?
  [[ "$rc" == 0 ]] && grep -qx "DEPLOY_WITH_MONITORING=$wanted" "$T/.local/deploy-config"
  check "monitoring $previous to $wanted persists despite --skip index-svc" $?

  run_monitoring_config
  rc=$?
  [[ "$rc" == 0 ]] && grep -q "monitoring=$wanted" "$T/out" \
    && grep -qx "DEPLOY_WITH_MONITORING=$wanted" "$T/.local/deploy-config"
  check "next deploy without a monitoring flag retains $wanted" $?
  grep -qx 'DEPLOY_WITH_GLOSSARY=false' "$T/.local/deploy-config" \
    && grep -qx 'DEPLOY_GLOSSARY_MAX_FILES=400' "$T/.local/deploy-config"
  check "skipping the index host preserves its glossary selection and cap" $?
  ! grep -E 'create-|put-|modify-|update-|send-command|converse|invoke-' "$AWS_CALLS" >/dev/null
  check "monitoring config regression uses only discovery stubs, no mutation or model call" $?
done

# A base-only reconcile says what THIS run deployed, not whether pre-existing
# services are available. Run the actual CLI for both skip spellings and for
# empty/missing declarations; all infrastructure phases remain skipped.
run_project_footer() {
  bash "$T/scripts/deploy-all.sh" --region ap-northeast-1 \
    --skip artifacts --skip iam --skip network --skip index-svc \
    --skip image --skip monitoring "$@" > "$T/out" 2>&1
}
for declaration in configured empty missing; do
  case "$declaration" in
    configured)
      cat > "$T/.local/projects.json" <<'JSON'
{"schemaVersion":2,"projects":{"first":{"port":8080,"repos":[{"subdir":"first","source":"local"}]},"second":{"port":8081,"repos":[{"subdir":"second","source":"local"}]}}}
JSON
      ;;
    empty) printf '{"schemaVersion":2,"projects":{}}\n' > "$T/.local/projects.json" ;;
    missing) rm -f "$T/.local/projects.json" ;;
  esac
  for mode in skip-phase base-only automatic; do
    # With configured projects, automatic mode would actually deploy them.
    [[ "$declaration" == configured && "$mode" == automatic ]] && continue
    args=()
    case "$mode" in
      skip-phase) args=(--skip projects) ;;
      base-only) args=(--skip-projects) ;;
    esac
    run_project_footer "${args[@]}"
    rc=$?
    footer="$(sed -n '/deploy-all complete/,$p' "$T/out")"
    [[ "$rc" == 0 && "$footer" == *"No projects were deployed in this run"* ]]
    check "$declaration/$mode footer reports only this run's project deployment" $?
    if [[ "$declaration" == configured ]]; then
      [[ "$footer" == *"Configured projects: first second"* && "$footer" == *"/health"* \
        && "$footer" == *"/ready"* && "$footer" == *"verify"* && "$footer" != *"add a project"* ]]
      check "$declaration/$mode directs existing projects to health checks, not first-install guidance" $?
    else
      [[ "$footer" == *"No projects configured in .local/projects.json"* \
        && "$footer" == *"./scripts/install.sh"* && "$footer" == *"add a project"* ]]
      check "$declaration/$mode offers setup guidance for an unconfigured project list" $?
    fi
    ! grep -E 'NO project/bot is active yet|answer will NOT work|no gateway active yet|all 1 project\(s\) deployed' "$T/out" >/dev/null
    check "$declaration/$mode does not infer an outage or claim an empty project was deployed" $?
  done
done

# Control: real per-project dispatch (to a local stub) must still count projects
# that were deployed in this run and suppress the skipped-project footer.
cat > "$T/.local/projects.json" <<'JSON'
{"schemaVersion":2,"projects":{"first":{"port":8080,"repos":[{"subdir":"first","source":"local"}]},"second":{"port":8081,"repos":[{"subdir":"second","source":"local"}]}}}
JSON
cat > "$T/scripts/lib/deploy_project.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$2" >> "$DEPLOYED_PROJECTS"
SH
export DEPLOYED_PROJECTS="$T/deployed-projects"
run_project_footer --with-monitoring=false
rc=$?
[[ "$rc" == 0 && "$(cat "$DEPLOYED_PROJECTS")" == $'first\nsecond' ]] \
  && grep -q 'all 2 project(s) deployed' "$T/out"
check "normal deployment still dispatches and counts both configured projects" $?
! grep -q 'No projects were deployed in this run' "$T/out"
check "successful project deployment does not print the skipped-project footer" $?
printf '  ran=%s failed=%s\n' "$run" "$fail"
[[ "$fail" == 0 ]]
