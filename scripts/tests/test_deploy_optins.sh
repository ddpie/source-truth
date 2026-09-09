#!/usr/bin/env bash
# test_deploy_optins.sh — opt-in monitoring/glossary, hard-fail preflight, post-deploy probe. Offline.
#   deploy-all.sh          : --with-monitoring / --with-glossary persist + gate; defaults; preflight
#   provision/activate     : glossary OFF ⇒ empty glossary model + GLOSSARY_ENABLED=false on the host
#   glossary_refresh.sh    : empty model ⇒ pull-only no-op (runs the real script with stubs)
#   deploy_project.sh      : probe rc mapping (runs the real probe_verdict function)
# shellcheck disable=SC2034  # DRY_RUN/LOCAL_MODE/FORCE feed the eval'd preflight_ssm_plugin
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="$ROOT/scripts/deploy-all.sh"; DP="$ROOT/scripts/lib/deploy_project.sh"
PV="$ROOT/scripts/lib/provision_index_service.sh"; AP="$ROOT/index-service/activate_project.sh"
GR="$ROOT/index-service/glossary_refresh.sh"; BS="$ROOT/index-service/bootstrap.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_deploy_optins:"
for f in "$D" "$DP" "$PV" "$AP" "$GR" "$BS"; do bash -n "$f"; check "$(basename "$f") parses" $?; done

# ---- deploy-all.sh: flags, defaults, persistence, gating ------------------------------------
help="$("$D" --help 2>&1)"
for f in --with-monitoring --with-glossary --no-probe; do [[ "$help" == *"$f"* ]]; check "--help documents $f" $?; done
grep -q '^DEFAULT_GLOSSARY_MAX_FILES="400"' "$D"; check "DEFAULT_GLOSSARY_MAX_FILES=400 (0 = uncapped only when passed)" $?
grep -q 'WITH_MONITORING="$(resolve_optin "$WITH_MONITORING" "${DEPLOY_WITH_MONITORING:-}" monitoring)"' "$D"; check "monitoring: flag > persisted > legacy/default via resolve_optin" $?
grep -q 'WITH_GLOSSARY="$(resolve_optin "$WITH_GLOSSARY" "${DEPLOY_WITH_GLOSSARY:-}" glossary)"' "$D"; check "glossary: flag > persisted > legacy/default via resolve_optin" $?
for f in '--with-glossary[=true|false]' '--with-monitoring[=true|false]' '60..28800'; do [[ "$help" == *"$f"* ]]; check "--help documents $f" $?; done
grep -q -- '--with-monitoring=\*) WITH_MONITORING="$(_val_bool' "$D" && grep -q -- '--with-glossary=\*) WITH_GLOSSARY="$(_val_bool' "$D"; check "=true|false forms parsed" $?
grep -q 'update_env "$CONFIG_FILE" DEPLOY_WITH_MONITORING "$WITH_MONITORING"' "$D"; check "DEPLOY_WITH_MONITORING persisted" $?
grep -q 'update_env "$CONFIG_FILE" DEPLOY_WITH_GLOSSARY "$WITH_GLOSSARY"' "$D"; check "DEPLOY_WITH_GLOSSARY persisted" $?
grep -q 'elif \[\[ "$WITH_MONITORING" != true \]\]; then' "$D"; check "Phase 7 runs only when monitoring is on" $?
grep -q 'skip monitoring; then' "$D"; check "--skip monitoring still works" $?
grep -q 'export DEPLOY_WITH_GLOSSARY="$WITH_GLOSSARY"' "$D"; check "glossary choice exported for deploy_project.sh" $?
# the persist-and-read-back chain, executed: the REAL resolve_optin / _val_bool from deploy-all.sh
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/common.sh"
eval "$(sed -n '/^resolve_optin() {/,/^}$/p;/^_val_bool() {/,/^}$/p' "$D")"
unset INDEX_SERVICE_INSTANCE
[[ "$(resolve_optin '' '' monitoring 2>/dev/null)" == false ]]; check "no flag, nothing persisted, no host → false" $?
[[ "$(resolve_optin '' true monitoring 2>/dev/null)" == true ]]; check "no flag, persisted true → stays true (later runs keep the choice)" $?
[[ "$(resolve_optin true '' monitoring 2>/dev/null)" == true ]]; check "--with-monitoring on first run → true" $?
[[ "$(resolve_optin false true monitoring 2>/dev/null)" == false ]]; check "--with-monitoring=false wins over persisted true" $?
# F3 upgrade path: host exists, key absent → ON (warned once), never silently OFF
out="$(INDEX_SERVICE_INSTANCE=i-0abc resolve_optin '' '' glossary 2>&1 >/dev/null)"
[[ "$(INDEX_SERVICE_INSTANCE=i-0abc resolve_optin '' '' glossary 2>/dev/null)" == true ]]; check "legacy deploy-config (host, no DEPLOY_WITH_GLOSSARY) → glossary stays ON" $?
[[ "$out" == *"predates the opt-in switches"* && "$out" == *"--with-glossary=false"* && "$out" == *"DEPLOY_WITH_GLOSSARY=false"* ]]; check "legacy default warns and names both ways to turn it off" $?
[[ "$(INDEX_SERVICE_INSTANCE=i-0abc resolve_optin '' false glossary 2>/dev/null)" == false ]]; check "persisted false + host → stays false (only an ABSENT key is legacy)" $?
[[ "$(INDEX_SERVICE_INSTANCE=i-0abc resolve_optin false '' glossary 2>/dev/null)" == false ]]; check "--with-glossary=false turns a legacy deploy off" $?
[[ "$(_val_bool --with-glossary false)" == false && "$(_val_bool --with-glossary yes)" == true ]]; check "_val_bool accepts true/false spellings" $?
( _val_bool --with-glossary maybe ) >/dev/null 2>&1; rc=$?; [[ $rc -eq 2 ]]; check "_val_bool rejects 'maybe' with rc 2" $?
# deploy_project.sh mirrors the legacy default when reached directly (install.sh redeploy) and persists it
grep -q 'if \[\[ -z "${DEPLOY_WITH_GLOSSARY:-}" \]\]; then' "$DP" && grep -q 'update_env "$CONFIG_FILE" DEPLOY_WITH_GLOSSARY true' "$DP"; check "deploy_project: absent DEPLOY_WITH_GLOSSARY → ON + persisted (legacy)" $?
# F6: dry-run wording no longer claims "a real run aborts here" on the unresolved model id
! grep -q 'dry-run: a real run aborts here' "$D"; check "dry-run model-probe wording: no 'a real run aborts here'" $?
grep -q 'no inference' "$D"; check "dry-run explicitly skips inference" $?
# F14: observability preflight prints the complete manual path
grep -q -- '--only observability' "$D"; check "observability preflight prints apply-monitoring.sh --only observability" $?
! grep -q 'say warn "    aws xray update-trace-segment-destination' "$D"; check "…instead of the bare xray command" $?
# F1/F4: deploy-all rc 3 handling + monitoring verification only after a project deployed
grep -q '"$WITH_MONITORING" == true && "$PROJECTS_DEPLOYED" == true \]\]; then' "$D"; check "ALARMS verification requires a deployed project (no misleading 'INCOMPLETE' under --skip-projects)" $?
grep -q '3) say warn "project' "$D" && grep -q '_PROBE_FAILED+=("$_pid")' "$D"; check "deploy-all treats deploy_project rc 3 as deployed-with-warning" $?
grep -q '^  exit 3$' "$D"; check "deploy-all exits 3 at the very end when a project failed the smoke probe" $?
grep -q 'deployed but did not answer the smoke questions — see runbook §5/§8' "$D"; check "deploy-all's closing summary names the project and the runbook sections" $?
# B-7: the rc-3 summary is one function, printed before BOTH exits (a hard failure must not hide it)
_pfs="$(sed -n '/^probe_failed_summary() {/,/^}$/p' "$D")"
[[ -n "$_pfs" && "$_pfs" == *'see runbook §5/§8'* ]]; check "probe_failed_summary() exists and carries the runbook line" $?
[[ "$(grep -cE '^ *probe_failed_summary( +#.*)?$' "$D")" -eq 2 ]]; check "probe_failed_summary called twice (exit-1 path + exit-3 path)" $?
_f1="$(sed -n '/^  if \[\[ ${#_failed\[@\]} -gt 0 \]\]; then$/,/^  fi$/p' "$D")"
[[ "$_f1" == *'probe_failed_summary'*'exit 1'* ]]; check "hard-failure block prints the probe-failed list before exit 1" $?
eval "$_pfs"
_PROBE_FAILED=(alpha beta); out="$(probe_failed_summary 2>&1)"
[[ "$out" == *"project alpha deployed but did not answer"* && "$out" == *"project beta deployed but did not answer"* ]]; check "probe_failed_summary lists every rc-3 project" $?
_PROBE_FAILED=(); out="$(probe_failed_summary 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]]; check "probe_failed_summary with nothing failed prints nothing, rc 0" $?
# B-8: under --skip-projects the monitoring line must not say "add a project" — install.sh applies it right after
grep -q 'elif \[\[ "$SKIP_PROJECTS" == true \]\]; then' "$D"; check "Phase 7 has a dedicated --skip-projects branch" $?
grep -q 'monitoring is applied after the project deploy (install.sh does this; or run ./scripts/apply-monitoring.sh --region $REGION)' "$D"; check "--skip-projects + --with-monitoring says install.sh applies monitoring after the project" $?
_p7="$(sed -n '/^if skip monitoring; then$/,/^fi$/p' "$D")"
_s="${_p7%%SKIP_PROJECTS*}"; _n="${_p7%%PROJECTS_DEPLOYED\" != true*}"
[[ ${#_s} -lt ${#_n} ]]; check "the --skip-projects branch is checked before the generic 'no gateway yet' one" $?
# glossary OFF ⇒ EMPTY glossary model + ST_GLOSSARY_ENABLED to the provisioner
grep -q '^GLOSSARY_MODEL=""' "$D" && grep -q '\[\[ "$WITH_GLOSSARY" == true \]\] && GLOSSARY_MODEL="$MODEL"' "$D"
check "glossary model is empty unless --with-glossary" $?
grep -q '"$ROOT_VOLUME_GB" "$GLOSSARY_MODEL" "$GLOSSARY_MAX_FILES")"' "$D"; check "provisioner receives the glossary model (not the answer model)" $?
grep -q 'ST_GLOSSARY_ENABLED="$WITH_GLOSSARY"' "$D"; check "provisioner receives ST_GLOSSARY_ENABLED" $?

# ---- deploy-all.sh: hard-fail preflight ------------------------------------------------------
_pm="$(sed -n '/^preflight_model_access() {$/,/^}$/p' "$D")"
[[ "$_pm" == *'exit 1'* ]]; check "model-access: clear access/validation error exits 1" $?
[[ "$_pm" == *'"$FORCE" == true'* ]]; check "model-access: --force bypasses" $?
[[ "$_pm" == *'runtime role is checked by post-deploy smoke'* ]]; check "deployment identity denial is not confused with runtime denial" $?
[[ "$_pm" == *'timed out'*'continuing'* ]]; check "model-access: timeout/inconclusive still continue" $?
_sp="$(sed -n '/^preflight_ssm_plugin() {$/,/^}$/p' "$D")"
[[ -n "$_sp" ]]; check "preflight_ssm_plugin exists" $?
[[ "$_sp" == *'command -v session-manager-plugin'* ]]; check "checks for session-manager-plugin" $?
[[ "$_sp" != *'exit 1'* ]]; check "interactive SSM plugin does not block automated deployment" $?
grep -q '^preflight_ssm_plugin$' "$D"; check "preflight_ssm_plugin is called" $?
# run the real function with a stubbed PATH: two-machine → exit 1; --local → rc 0; --force → rc 0
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/common.sh"
eval "$_sp"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( PATH="$T:/nonexistent"; DRY_RUN=false LOCAL_MODE=false FORCE=false; preflight_ssm_plugin ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]]; check "plugin missing, two-machine → warning only (got $rc)" $?
( PATH="$T:/nonexistent"; DRY_RUN=false LOCAL_MODE=true FORCE=false; preflight_ssm_plugin ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]]; check "plugin missing, --local → warn only (rc $rc)" $?
( PATH="$T:/nonexistent"; DRY_RUN=false LOCAL_MODE=false FORCE=true; preflight_ssm_plugin ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]]; check "plugin missing, --force → continues (rc $rc)" $?
( PATH="$T:/nonexistent"; DRY_RUN=true LOCAL_MODE=false FORCE=false; preflight_ssm_plugin ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]]; check "plugin missing, --dry-run → warn, never exits (rc $rc)" $?
printf '#!/bin/sh\nexit 0\n' > "$T/session-manager-plugin"; chmod +x "$T/session-manager-plugin"
( PATH="$T:/nonexistent"; DRY_RUN=false LOCAL_MODE=false FORCE=false; preflight_ssm_plugin ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]]; check "plugin present → rc 0" $?

# ---- host side: glossary OFF passes an empty model ---------------------------------------------
grep -q 'GLOSSARY_ENABLED="${ST_GLOSSARY_ENABLED:-true}"' "$PV" && grep -q '\[\[ "$GLOSSARY_ENABLED" == false \]\] && MODEL=""' "$PV"
check "provisioner: ST_GLOSSARY_ENABLED=false blanks the glossary model" $?
[[ "$(grep -c "GLOSSARY_ENABLED='\$GLOSSARY_ENABLED'" "$PV")" -eq 2 ]] && grep -q 'bash -c "$(rebootstrap_payload)"' "$PV"
check "local and remote updates share the glossary env transaction; new hosts receive it too" $?
grep -q "MODEL='\${GL_MODEL}' GLOSSARY_ENABLED='\${GLOSSARY_ENABLED}'" "$DP"; check "deploy_project passes the glossary model + flag to activate_project" $?
grep -q '\[\[ "$GLOSSARY_ENABLED" == true \]\] || GL_MODEL=""' "$DP"
check "deploy_project: glossary model empty unless DEPLOY_WITH_GLOSSARY=true" $?
grep -q -- '--model "$RT_MODEL"' "$DP"; check "deploy_project: the runtime still gets the real answer model" $?
grep -q '\[ "$GLOSSARY_ENABLED" != "false" \] || MODEL=""' "$AP"; check "activate_project: GLOSSARY_ENABLED=false forces MODEL empty (initial build skipped)" $?
grep -q 'elif \[ -z "$MODEL" \]; then' "$AP"; check "activate_project keeps the MODEL-empty → engine-disabled branch" $?
grep -q 'GLOSSARY_ENABLED=%s' "$AP"; check "activate_project writes GLOSSARY_ENABLED into the per-project env (refresh unit sees it)" $?
grep -q '"${GLOSSARY_ENABLED:-true}" = "false"' "$BS"; check "bootstrap skips the claude CLI when GLOSSARY_ENABLED=false" $?
_gb="$(sed -n '/^if \[ "${GLOSSARY_ENABLED:-true}" = "false" \]; then$/,/^elif ensure_node/p' "$BS")"
[[ "$_gb" == *ensure_node* ]]; check "bootstrap still installs Node when the glossary is off (gateway needs it)" $?

# glossary_refresh.sh with an EMPTY model: pull happens, glossary_gen is never invoked, rc 0
mkdir -p "$T/app" "$T/bin" "$T/ws"
cp "$ROOT/index-service/glossary_worker.sh" "$T/app/"
cat > "$T/app/git_fetch.sh" <<'EOF'
#!/bin/sh
echo "git_fetch_shas: $1 OLD=aaa NEW=bbb"
exit "${FETCH_RC:-0}"
EOF
cat > "$T/bin/python3" <<'EOF'
#!/bin/sh
echo "python3 $*" >> "$STUB_LOG"; exit 0
EOF
chmod +x "$T/app/git_fetch.sh" "$T/bin/python3"
run_refresh() {  # run_refresh <model> [env...]
  : > "$T/log"
  env "${@:2}" PATH="$T/bin:$PATH" STUB_LOG="$T/log" GLOSSARY_APP_DIR="$T/app" GLOSSARY_ROOT="$T/gl" \
    bash "$GR" sub https://x/y.git main "$T/ws" proj "$1" us-east-1 > "$T/out" 2>&1
  echo $?
}
rc="$(run_refresh "")"
[[ "$rc" -eq 0 ]]; check "refresh with empty model exits 0 (got $rc)" $?
grep -q 'git_fetch_shas' "$T/out"; check "refresh with empty model still pulled the repo" $?
! grep -q 'glossary_gen' "$T/log"; check "refresh with empty model never runs glossary_gen (clean no-op)" $?
grep -q 'glossary disabled' "$T/out"; check "refresh with empty model says why it skipped" $?
rc="$(run_refresh "some-model" GLOSSARY_ENABLED=false)"
[[ "$rc" -eq 0 ]] && ! grep -q 'glossary_gen' "$T/log"; check "GLOSSARY_ENABLED=false wins even with a model set" $?
rc="$(run_refresh "some-model")"
grep -q 'glossary_gen' "$T/log"; check "refresh with a model still builds the slice (control)" $?
rc="$(run_refresh "" FETCH_RC=7)"
[[ "$rc" -eq 7 ]]; check "a failed pull still fails the unit with glossary off (got $rc)" $?

# ---- deploy_project.sh: post-deploy probe + rc mapping -------------------------------------------
grep -q 'e2e-probe.py" --region "$REGION" --project "$PID"' "$DP"; check "runs e2e-probe.py after 'fully deployed'" $?
grep -q '"${NO_PROBE:-0}" == 1 || "${E2E_PROBE:-1}" == 0' "$DP"; check "--no-probe (NO_PROBE=1) / E2E_PROBE=0 skip the probe" $?
_tail="$(sed -n '/^if \[\[ "$ALL_LOCAL" == true \]\]; then$/,/^fi$/p' "$DP")"
[[ "$_tail" == *'e2e-probe.py'* ]]; check "probe is skipped only when ALL repos are local (same if/elif chain)" $?
grep -q 'push-local-repo.sh' "$DP"; check "push hint kept for the local repos" $?
# the ALL_LOCAL predicate, executed
_all="$(sed -n '/^ALL_LOCAL="$(REPO_MANIFEST_JSON/,/echo false)"$/p' "$DP")"
[[ -n "$_all" ]]; check "ALL_LOCAL block extracted" $?
all_local() { local REPO_MANIFEST_JSON="$1" ALL_LOCAL; eval "$_all"; printf '%s' "$ALL_LOCAL"; }
[[ "$(all_local '{"repos":[{"subdir":"a","source":"local"}]}')" == true ]]; check "ALL_LOCAL: single local repo → true (probe skipped)" $?
[[ "$(all_local '{"repos":[{"subdir":"a","source":"local"},{"subdir":"b","source":"git"}]}')" == false ]]; check "ALL_LOCAL: mixed local + git → false (probe runs)" $?
[[ "$(all_local '{"repos":[{"subdir":"b","source":"git"}]}')" == false ]]; check "ALL_LOCAL: git only → false" $?
grep -q 'model cost' "$DP"; check "one-line notice about real questions + model cost before probing" $?
eval "$(sed -n '/^probe_verdict() {$/,/^}$/p' "$DP")"
out="$(probe_verdict 0 demo 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"真实问答通过"* && "$out" == *"answered a real question"* ]]; check "rc 0 → ok: deployed and answered a real question" $?
out="$(probe_verdict 2 demo 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"无法运行"* ]]; check "rc 2 → unverified smoke must propagate a nonzero verdict" $?
out="$(probe_verdict 1 demo 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"runbook"* && "$out" == *"§5"* && "$out" == *"§8"* ]]; check "rc 1 → err pointing at runbook §5/§8, deploy fails" $?
grep -q 'probe_verdict "$_PRC" "$PID" || exit 3' "$DP"; check "a failed verdict exits 3 (deployed, smoke failed — not a failed deploy)" $?

# --- opt-in persistence timing (deploy-all.sh) ---
DA="$ROOT/scripts/deploy-all.sh"
# First deploy (no host yet): persist DEPLOY_WITH_* early, but never overwrite an existing key.
early="$(sed -n '/Persist resolved config/,/DEPLOY_FEISHU_DOMAIN/p' "$DA")"
grep -q 'if \[\[ -z "\${INDEX_SERVICE_INSTANCE:-}" \]\]' <<<"$early"; check "first deploy (no host) persists the opt-in switches before provisioning" $?
grep -q '\[\[ -n "\${DEPLOY_WITH_GLOSSARY:-}" \]\]   || update_env' <<<"$early"; check "early persistence never overwrites an existing DEPLOY_WITH_GLOSSARY" $?
# Existing host: persist only after Phase 3 succeeded, and not when Phase 3 was skipped.
late="$(sed -n '/persist them here/,/^fi$/p' "$DA")"
grep -q '! skip index-svc' <<<"$late"; check "late persistence is skipped with --skip index-svc (host unchanged)" $?
grep -q 'DEPLOY_WITH_GLOSSARY "\$WITH_GLOSSARY"' <<<"$late"; check "late persistence writes DEPLOY_WITH_GLOSSARY after Phase 3" $?

# --- region guard: a deploy-config from another region must be refused, not reused ---
guard="$(sed -n '/One .local\/deploy-config describes ONE region/,/^fi$/p' "$DA")"
grep -q '"\$DEPLOY_REGION" != "\$REGION"' <<<"$guard"; check "deploy-config from another region is detected" $?
grep -q 'exit 2' <<<"$guard"; check "region mismatch is a usage error (exit 2) before any AWS call" $?
out="$(bash -c 'say(){ printf "%s\n" "$*"; }; REGION=us-east-1; DEPLOY_REGION=ap-northeast-1; '"$guard" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"ap-northeast-1"* && "$out" == *"us-east-1"* ]]; check "guard executes: exit 2 naming both regions" $?
out="$(bash -c 'say(){ printf "%s\n" "$*"; }; REGION=us-east-1; DEPLOY_REGION=us-east-1; '"$guard"'; echo same-ok' 2>&1)"
[[ "$out" == "same-ok" ]]; check "guard is silent when deploy-config region matches" $?

# --- model probe uses the model-neutral Converse API ---
probe="$(sed -n '/^preflight_model_access() {$/,/^}$/p' "$DA")"
grep -q 'bedrock-runtime converse' <<<"$probe" && ! grep -q 'anthropic_version' <<<"$probe"; check "model preflight supports OpenAI and Claude through Converse" $?

echo "  $_run run, $_fail failed"
[[ "$_fail" -eq 0 ]]
