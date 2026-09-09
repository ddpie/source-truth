#!/usr/bin/env bash
# Run the production model preflight against an offline AWS substitute.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
eval "$(sed -n '/^preflight_model_access() {$/,/^}$/p;/^preflight_project_models() {$/,/^}$/p' "$ROOT/scripts/deploy-all.sh")"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
CALLS="$TASK_TMP/calls"
_run=0 _fail=0
check() {
  _run=$((_run + 1))
  if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; _fail=$((_fail + 1)); fi
}
aws() {
  printf '%s\n' "$*" >> "$CALLS"
  printf '%s\n' "${PROBE_ERROR:-{}}"
  return "${PROBE_RC:-0}"
}
run_timeout() { shift; "$@"; }
resolve_model_for_region() { printf '%s' "$1"; }
DRY_RUN=false FORCE=false REGION=ap-northeast-1
PROBE_RC=0 PROBE_ERROR=""
: > "$CALLS"
preflight_model_access global.openai.gpt-6-astra >/dev/null 2>&1
check "OpenAI model invokes successfully" $?
grep -q 'bedrock-runtime converse.*global.openai.gpt-6-astra' "$CALLS"
check "uses Converse with the selected OpenAI profile" $?
! grep -q 'anthropic_version\|invoke-model' "$CALLS"
check "no Claude-specific request body" $?
: > "$CALLS"
DRY_RUN=true preflight_model_access global.openai.gpt-6-astra >/dev/null 2>&1
[[ ! -s "$CALLS" ]]; check "dry-run never invokes a model" $?

( PROBE_RC=1 PROBE_ERROR=ValidationException; preflight_model_access invalid ) >/dev/null 2>&1
rc=$?; [[ "$rc" -eq 1 ]]; check "invalid model configuration fails early" $?
out="$(PROBE_RC=1 PROBE_ERROR=$'\nValidationException: model is invalid'; preflight_model_access invalid 2>&1)"
[[ "$out" == *"invalid model or region for invalid: ValidationException: model is invalid"* ]]
check "AWS CLI leading newline does not erase the failure reason" $?
( PROBE_RC=1 PROBE_ERROR=ValidationException FORCE=true; preflight_model_access invalid ) >/dev/null 2>&1
check "--force permits an explicit override" $?
( PROBE_RC=1 PROBE_ERROR=AccessDeniedException; preflight_model_access global.openai.gpt-6-astra ) >/dev/null 2>&1
check "deployer IAM denial defers to the actual-runtime smoke" $?
( PROBE_RC=124 PROBE_ERROR=timeout; preflight_model_access global.openai.gpt-6-astra ) >/dev/null 2>&1
check "inconclusive network timeout does not block deployment" $?

PROJECTS_CFG="$TASK_TMP/projects.json"
cat > "$PROJECTS_CFG" <<'JSON'
{"schemaVersion":2,"projects":{"first":{},"second":{"agent":{"glossaryModel":"global.openai.gpt-5.6-sol"}},"third":{"agent":{"sdk":"claude"}}}}
JSON
MODEL_DECLARED=global.anthropic.claude-opus-4-8
WITH_GLOSSARY=false
: > "$CALLS"
preflight_project_models >/dev/null 2>&1
check "project models are resolved from the shared SDK configuration" $?
[[ "$(wc -l < "$CALLS")" -eq 2 ]] && grep -q 'global.openai.gpt-6-astra' "$CALLS" && grep -q 'global.anthropic.claude-opus-4-8' "$CALLS"
check "one probe per distinct answer model across both SDKs" $?
: > "$CALLS"
WITH_GLOSSARY=true preflight_project_models >/dev/null 2>&1
[[ "$(wc -l < "$CALLS")" -eq 3 ]] && grep -q 'global.openai.gpt-5.6-sol' "$CALLS"
check "enabled glossary adds only its distinct model" $?
: > "$CALLS"
DRY_RUN=true preflight_project_models >/dev/null 2>&1
[[ ! -s "$CALLS" ]]; check "project dry-run skips all model calls" $?
printf '{"projects":{}}\n' > "$PROJECTS_CFG"
preflight_project_models >/dev/null 2>&1
[[ ! -s "$CALLS" ]]; check "base-only setup needs no model invocation" $?
printf '  ran=%s failed=%s\n' "$_run" "$_fail"
[[ "$_fail" -eq 0 ]]
