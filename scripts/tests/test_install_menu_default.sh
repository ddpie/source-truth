#!/usr/bin/env bash
# test_install_menu_default.sh — install.sh one-run behaviour, offline.
#   * menu default is "add a project" whether or not a base host exists (that flow creates the base
#     and the project in one run); the old uncapped-glossary cost gate is gone.
#   * ask_extras: glossary + monitoring are opt-in, default no; --yes takes the persisted choice;
#     flags win; the cap is asked only when the glossary is on.
#   * --action / --project (F3): unattended redeploy; --yes + host without --action exits 2.
#   * redeploy (F1): a glossary change is persisted by deploy-all, never before it runs.
#   * redeploy (F2): a host-wide glossary change re-activates the OTHER projects too (NO_PROBE=1).
# Runs a COPY of install.sh with stubbed aws/docker/git/curl — no AWS, no network, no IMDS wait.
# shellcheck disable=SC2034  # ASSUME_YES/GLOS_FLAG/MON_FLAG/GMF_FLAG/GLOSSARY_OPTIONS feed the eval'd install.sh functions
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
I="$ROOT/scripts/install.sh"
_run=0 _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_install_menu_default:"

bash -n "$I"; check "install.sh parses" $?

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/bin"
cp "$I" "$T/scripts/install.sh"
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/env-utils.sh" "$T/scripts/lib/"
cat > "$T/bin/aws" <<'EOF'
#!/bin/sh
case "$*" in *get-caller-identity*) echo 123456789012; exit 0 ;; esac
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/git"
printf '#!/bin/sh\nexit 22\n' > "$T/bin/curl"   # IMDS unreachable, instantly
chmod +x "$T/bin"/*
run_install() {  # run_install <args...>  (prints combined output; rc in $?)
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" NO_COLOR=1 bash "$T/scripts/install.sh" "$@" </dev/null 2>&1
}

# --- 1) no base host: --yes lands on "add a project" (not init-env) ---------------------------
out="$(run_install --yes --region us-east-1)"
[[ "$out" == *"添加项目 / add a project"* ]]; check "no base host → default flow is 添加项目 / add a project" $?
[[ "$out" != *"初始化环境（不挂项目）/ init environment only"* ]]; check "no base host → init-env is NOT the default" $?
# under --yes there is no projectId to default to: stop EARLY with exit 2 + the scripted-path hint
# (it used to fall through to the prompt and die with "projectId 非法").
run_install --yes --region us-east-1 >/dev/null; rc=$?
[[ $rc -eq 2 ]]; check "--yes first add-project exits 2 (got $rc)" $?
[[ "$out" == *"non-interactive first add-project is not supported"* && "$out" == *"脚本化路径"* ]]; check "--yes first add-project points at the scripted path (runbook appendix A)" $?
[[ "$out" != *"projectId 非法"* ]]; check "--yes no longer dies with 'projectId 非法'" $?

# --- 2) with a base host: --yes alone cannot pick a flow → exit 2 pointing at --action ----------
mkdir -p "$T/.local"; printf 'INDEX_SERVICE_INSTANCE=i-0123456789abcdef0\nDEPLOY_REGION=us-east-1\n' > "$T/.local/deploy-config"
out2="$(run_install --yes)"; rc=$?
[[ $rc -eq 2 ]]; check "with base host → --yes without --action exits 2 (got $rc)" $?
[[ "$out2" == *"--action <init|add|redeploy|remove>"* && "$out2" == *"--action redeploy"* ]]; check "…and the hint names --action (with a redeploy example)" $?
[[ "$out2" != *"choose an action"* ]]; check "…without drawing the menu" $?
rm -f "$T/.local/deploy-config"

# --- 3) the uncapped-glossary cost gate is gone; --help documents the new flags ----------------
! grep -q 'UNCAPPED glossary build' "$I"; check "uncapped-glossary warning+confirm block removed" $?
! grep -q 'MENU_DEFAULT=0' "$I"; check "menu default no longer flips on INDEX_SERVICE_INSTANCE" $?
help="$(bash "$I" --help 2>&1)"
for f in --with-glossary --with-monitoring --no-probe --glossary-max-files '--with-glossary[=true|false]' '--with-monitoring[=true|false]' '--action <init|add|redeploy|remove>' '--project <pid>' '--yes --action redeploy'; do
  [[ "$help" == *"$f"* ]]; check "--help documents $f" $?
done
! grep -q '"1/5 检查依赖' "$I"; check "dependency step no longer numbered 1/5 (there are no steps 2-5)" $?
! grep -q 'exec bash "$SCRIPT_DIR/lib/deploy_project.sh"' "$I"; check "deploy_project.sh is called, not exec'd (rc must come back for monitoring + the closing line)" $?
[[ "$(grep -c 'finish_project_deploy "$rc"' "$I")" -eq 3 ]]; check "add-project and redeploy (plain + fan-out-failed) go through finish_project_deploy" $?
# both deploy-all invocations forward the opt-in flags
n=$(grep -c '"\${EXTRA_FLAGS\[@\]}"' "$I"); [[ "$n" -ge 2 ]]; check "both deploy-all calls forward EXTRA_FLAGS (got $n)" $?
n=$(grep -c '"\${PROBE_FLAG\[@\]}"' "$I"); [[ "$n" -ge 2 ]]; check "both deploy-all calls forward PROBE_FLAG (got $n)" $?
grep -q 'export NO_PROBE=1' "$I"; check "--no-probe exports NO_PROBE=1 for the direct deploy_project.sh execs" $?

# --- 4) ask_extras under --yes: default no; persisted choice honoured; flags win ---------------
# shellcheck disable=SC1090
source "$ROOT/scripts/lib/common.sh"
eval "$(sed -n '/^ask_yn() {$/,/^}$/p;/^ask_extras() {$/,/^}$/p;/^pick_field() {$/,/^}$/p;/^index_of_token() {$/,/^}$/p;/^optin_default() {/,/^}$/p;/^flag_value() {/,/^}$/p;/^glossary_changed() {$/,/^}$/p;/^finish_project_deploy() {$/,/^}$/p' "$I")"
ask() { printf -v "$1" '%s' "${3:-}"; }   # --yes semantics: default only
ASSUME_YES=true; GLOS_FLAG=(); MON_FLAG=(); GMF_FLAG=(); GLOSSARY_OPTIONS=("400 x" "0 y")
unset DEPLOY_WITH_GLOSSARY DEPLOY_WITH_MONITORING DEPLOY_GLOSSARY_MAX_FILES INDEX_SERVICE_INSTANCE
# the OFF answer is forwarded EXPLICITLY (=false) so deploy-all cannot re-apply its legacy default over it
ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false --with-monitoring=false" ]]; check "--yes, nothing persisted, no host → both OFF, forwarded explicitly (got: ${EXTRA_FLAGS[*]})" $?
[[ "$GLOSSARY_ON" == false && "$MONITORING_ON" == false ]]; check "GLOSSARY_ON / MONITORING_ON follow the answers (both false)" $?
DEPLOY_WITH_MONITORING=true ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false --with-monitoring" && "$MONITORING_ON" == true ]]; check "--yes honours persisted DEPLOY_WITH_MONITORING=true" $?
DEPLOY_WITH_GLOSSARY=true ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary --glossary-max-files 400 --with-monitoring=false" ]]; check "glossary on → cap asked, default 400 (got: ${EXTRA_FLAGS[*]})" $?
# persisted false stays false even with a host present (only an ABSENT key means legacy)
DEPLOY_WITH_GLOSSARY=false DEPLOY_WITH_MONITORING=false INDEX_SERVICE_INSTANCE=i-0abc ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false --with-monitoring=false" ]]; check "persisted false + host → stays OFF (got: ${EXTRA_FLAGS[*]})" $?
# F3 legacy: a host exists but neither DEPLOY_WITH_* key does → the deploy predates the switches → ON
out="$(INDEX_SERVICE_INSTANCE=i-0abc ask_extras 2>&1)"; INDEX_SERVICE_INSTANCE=i-0abc ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary --glossary-max-files 400 --with-monitoring" ]]; check "legacy deploy-config (host, no DEPLOY_WITH_* keys) → glossary + monitoring default ON (got: ${EXTRA_FLAGS[*]})" $?
[[ "$out" == *"predates the switches"* && "$out" == *"--with-glossary=false"* ]]; check "legacy default is announced with the way to turn it off" $?
unset INDEX_SERVICE_INSTANCE
GLOS_FLAG=(--with-glossary); GMF_FLAG=(--glossary-max-files 0); MON_FLAG=(--with-monitoring)
ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary --glossary-max-files 0 --with-monitoring" ]]; check "flags win: explicit 0 = uncapped, monitoring on (got: ${EXTRA_FLAGS[*]})" $?
# =false flags win over the legacy default
GLOS_FLAG=(--with-glossary=false); GMF_FLAG=(); MON_FLAG=(--with-monitoring=false)
out="$(INDEX_SERVICE_INSTANCE=i-0abc ask_extras 2>&1)"; INDEX_SERVICE_INSTANCE=i-0abc ask_extras >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false --with-monitoring=false" && "$MONITORING_ON" == false ]]; check "--with-glossary=false / --with-monitoring=false win over the legacy default (got: ${EXTRA_FLAGS[*]})" $?
# B-6: the "predates the switches — keeping X ON" warning is about the DEFAULT; an explicit flag silences it
[[ "$out" != *"predates the switches"* ]]; check "explicit =false flags suppress the legacy 'defaults to ON' warning" $?
GLOS_FLAG=(--with-glossary); MON_FLAG=(); out="$(INDEX_SERVICE_INSTANCE=i-0abc ask_extras 2>&1)"
[[ "$out" != *"glossary defaults to ON"* && "$out" == *"monitoring defaults to ON"* ]]; check "legacy warning is per switch: silenced only for the one given as a flag" $?
unset INDEX_SERVICE_INSTANCE
# base mode (init-env): glossary only; monitoring is neither asked nor forwarded unless flagged
GLOS_FLAG=(); MON_FLAG=()
DEPLOY_WITH_MONITORING=true ask_extras base >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false" && "$MONITORING_ON" == false ]]; check "init-env (base) asks only the glossary, forwards nothing about monitoring (got: ${EXTRA_FLAGS[*]})" $?
MON_FLAG=(--with-monitoring); ask_extras base >/dev/null 2>&1
[[ "${EXTRA_FLAGS[*]}" == "--with-glossary=false --with-monitoring" ]]; check "init-env forwards an explicit --with-monitoring (persisted by deploy-all)" $?
MON_FLAG=(); grep -q 'ask_extras base' "$I" && grep -q 'ask_extras project' "$I"; check "init-env uses base mode, add-project uses project mode" $?
# --with-x=<bad> is rejected up front
run_install --with-glossary=maybe >/dev/null 2>&1; rc=$?; [[ $rc -eq 2 ]]; check "--with-glossary=maybe is rejected (rc $rc)" $?

# --- 4b) redeploy (B-2): a CHANGED glossary switch/cap re-bootstraps the host via deploy-all first ---
_rd="$(sed -n '/^flow_redeploy() {$/,/^}$/p' "$I")"
[[ "$_rd" == *'glossary_changed "$fv" "$gmf" && rebootstrap=true'* ]]; check "redeploy decides via glossary_changed" $?
[[ "$_rd" == *'"$SCRIPT_DIR/deploy-all.sh" --region "$REGION" --skip-projects "${LOCAL_FLAG[@]}"'* ]]; check "redeploy runs deploy-all --skip-projects (the only path that re-bootstraps the host)" $?
[[ "$_rd" == *'"${GLOS_FLAG[@]}" "${GMF_FLAG[@]}" "${MON_FLAG[@]}"'* ]]; check "redeploy forwards the opt-in flags to that deploy-all call" $?
# deploy-all must run BEFORE deploy_project.sh in the function body
_a="${_rd%%\"\$SCRIPT_DIR/deploy-all.sh\"*}"; _b="${_rd%%bash \"\$SCRIPT_DIR/lib/deploy_project.sh\"*}"
[[ ${#_a} -lt ${#_b} ]]; check "redeploy: deploy-all (re-bootstrap) precedes deploy_project.sh" $?
[[ "$_rd" == *"re-bootstrapping the index host"* && "$_rd" == *"skipping the base re-bootstrap"* ]]; check "redeploy says which path it took (re-bootstrap vs fast path)" $?
# the predicate, executed: only a GIVEN flag that differs from the persisted value triggers it
unset DEPLOY_WITH_GLOSSARY DEPLOY_GLOSSARY_MAX_FILES INDEX_SERVICE_INSTANCE
! glossary_changed "" ""; check "glossary_changed: no flags → unchanged (fast path)" $?
DEPLOY_WITH_GLOSSARY=true glossary_changed false ""; check "glossary_changed: --with-glossary=false vs persisted true → changed" $?
! DEPLOY_WITH_GLOSSARY=true glossary_changed true ""; check "glossary_changed: --with-glossary vs persisted true → unchanged" $?
DEPLOY_WITH_GLOSSARY=false glossary_changed true ""; check "glossary_changed: --with-glossary vs persisted false → changed" $?
glossary_changed true ""; check "glossary_changed: --with-glossary, nothing persisted, no host → changed (default is OFF)" $?
! INDEX_SERVICE_INSTANCE=i-0abc glossary_changed true ""; check "glossary_changed: legacy host (no key) counts as ON → --with-glossary unchanged" $?
INDEX_SERVICE_INSTANCE=i-0abc glossary_changed false ""; check "glossary_changed: legacy host + --with-glossary=false → changed" $?
DEPLOY_GLOSSARY_MAX_FILES=400 glossary_changed "" 0; check "glossary_changed: cap 400 → 0 → changed" $?
! DEPLOY_GLOSSARY_MAX_FILES=400 glossary_changed "" 400; check "glossary_changed: same cap → unchanged" $?
! glossary_changed "" 400; check "glossary_changed: no persisted cap = 400 default → 400 unchanged" $?
glossary_changed "" 4000; check "glossary_changed: no persisted cap → 4000 changed" $?

# --- 5) finish_project_deploy: rc semantics + monitoring after the project (F1/F4) -----------------
SCRIPT_DIR="$T/scripts"; : > "$T/mon.log"
printf '#!/usr/bin/env bash\necho "apply-monitoring $*" >> "%s"\nexit "${MON_RC:-0}"\n' "$T/mon.log" > "$T/scripts/apply-monitoring.sh"; chmod +x "$T/scripts/apply-monitoring.sh"
out="$( (finish_project_deploy 0 demo us-east-1 true) 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'apply-monitoring --region us-east-1' "$T/mon.log"; check "rc 0 + monitoring on → apply-monitoring.sh runs after the project, exit 0" $?
: > "$T/mon.log"; out="$( (finish_project_deploy 0 demo us-east-1 false) 2>&1 )"; rc=$?
[[ $rc -eq 0 && ! -s "$T/mon.log" ]]; check "rc 0 + monitoring off → apply-monitoring.sh not run" $?
: > "$T/mon.log"; out="$( (finish_project_deploy 3 demo us-east-1 true) 2>&1 )"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'apply-monitoring' "$T/mon.log"; check "rc 3 (deployed, smoke failed) → monitoring still applied, exit 3 propagated" $?
[[ "$out" == *"deployed but did not answer the smoke questions"* && "$out" == *"§5/§8"* ]]; check "rc 3 prints the accurate 'deployed but smoke failed' line" $?
: > "$T/mon.log"; out="$( (MON_RC=1 finish_project_deploy 0 demo us-east-1 true) 2>&1 )"; rc=$?
[[ $rc -eq 0 && "$out" == *"apply-monitoring.sh --region"* ]]; check "monitoring failure is best-effort: warns, exit code stays 0" $?
: > "$T/mon.log"; out="$( (finish_project_deploy 1 demo us-east-1 true) 2>&1 )"; rc=$?
[[ $rc -eq 1 && ! -s "$T/mon.log" && "$out" == *"deploy failed"* ]]; check "rc 1 → no monitoring, 'deploy failed', exit 1" $?
# interactive default: empty answer = no
ASSUME_YES=false
ask_yn "q?" n <<< ""; rc=$?; [[ $rc -ne 0 ]]; check "ask_yn: empty answer takes default no" $?
ask_yn "q?" y <<< ""; rc=$?; [[ $rc -eq 0 ]]; check "ask_yn: empty answer takes default yes" $?
ask_yn "q?" n <<< "y"; rc=$?; [[ $rc -eq 0 ]]; check "ask_yn: explicit y overrides default no" $?

# --- 6) unattended flows end-to-end (stubbed deploy-all.sh / deploy_project.sh) ------------------
# deploy_project stub: log "<region> <pid> NO_PROBE=<v>", fail for the pid named in $T/dp_fail.
cat > "$T/scripts/lib/deploy_project.sh" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2 NO_PROBE=\${NO_PROBE:-0}" >> "$T/dp.log"
[[ -f "$T/dp_fail" && "\$(cat "$T/dp_fail")" == "\$2" ]] && exit 1
exit 0
EOF
# deploy-all stub: log args; rc from $T/da_rc; on success persist the glossary flag like the real one.
cat > "$T/scripts/deploy-all.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/da.log"
rc=0; [[ -f "$T/da_rc" ]] && rc="\$(cat "$T/da_rc")"
[[ "\$rc" -eq 0 ]] || exit "\$rc"
for a in "\$@"; do case "\$a" in
  --with-glossary=false) sed -i 's/^DEPLOY_WITH_GLOSSARY=.*/DEPLOY_WITH_GLOSSARY=false/' "$T/.local/deploy-config" ;;
  --with-glossary) sed -i 's/^DEPLOY_WITH_GLOSSARY=.*/DEPLOY_WITH_GLOSSARY=true/' "$T/.local/deploy-config" ;;
esac; done
exit 0
EOF
chmod +x "$T/scripts/lib/deploy_project.sh" "$T/scripts/deploy-all.sh"
reset_host() {  # reset_host <glossary true|false> <pid...> : deploy-config + projects.json + empty logs
  local g="$1"; shift
  printf 'INDEX_SERVICE_INSTANCE=i-0123456789abcdef0\nDEPLOY_REGION=us-east-1\nDEPLOY_WITH_GLOSSARY=%s\n' "$g" > "$T/.local/deploy-config"
  { printf '{"projects":{'; local sep=""; for p in "$@"; do printf '%s"%s":{"port":8000,"feishuSecretId":"s","repos":[]}' "$sep" "$p"; sep=","; done; printf '}}\n'; } > "$T/.local/projects.json"
  : > "$T/dp.log"; : > "$T/da.log"; rm -f "$T/da_rc" "$T/dp_fail"
}
persisted() { grep "^$1=" "$T/.local/deploy-config" | cut -d= -f2-; }

# F3: --action redeploy under --yes with ONE project picks it and runs deploy_project.sh
reset_host true demo
out="$(run_install --yes --action redeploy --region us-east-1)"; rc=$?
[[ $rc -eq 0 ]]; check "--yes --action redeploy, one project → exit 0 (got $rc)" $?
[[ "$(cat "$T/dp.log")" == "us-east-1 demo NO_PROBE=0" ]]; check "…deploy_project.sh ran once for the sole project (got: $(cat "$T/dp.log"))" $?
[[ ! -s "$T/da.log" ]]; check "…no glossary flag → deploy-all not run (fast path)" $?
[[ "$out" == *"the only project"* && "$out" != *"choose an action"* ]]; check "…says it auto-picked the sole project; no menu" $?
reset_host true demo
run_install --yes --action=redeploy --region us-east-1 >/dev/null; rc=$?
[[ $rc -eq 0 && -s "$T/dp.log" ]]; check "--action=redeploy (equals form) works too (rc $rc)" $?
run_install --action bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "--action bogus exits 2 (got $rc)" $?
run_install --action >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "--action without a value exits 2 (got $rc)" $?
reset_host true demo
out="$(run_install --yes --action redeploy --project nope --region us-east-1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"not in projects.json"* && ! -s "$T/dp.log" ]]; check "--project not in the manifest → exit 2, nothing deployed (rc $rc)" $?
run_install --yes --action redeploy --project 'Bad Name' >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "--project with an invalid projectId exits 2 (got $rc)" $?
reset_host true alpha beta gamma
out="$(run_install --yes --action redeploy --region us-east-1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"needs --project"* && ! -s "$T/dp.log" ]]; check "--yes with 3 projects and no --project → exit 2 asking for --project (rc $rc)" $?

# F1: the glossary change is NOT persisted before deploy-all; a failed re-bootstrap keeps the old value
reset_host true demo; echo 1 > "$T/da_rc"
out="$(run_install --yes --action redeploy --with-glossary=false --region us-east-1)"; rc=$?
[[ $rc -eq 1 ]]; check "F1: deploy-all fails → redeploy exits 1 (got $rc)" $?
[[ "$(persisted DEPLOY_WITH_GLOSSARY)" == true ]]; check "F1: deploy-config still says DEPLOY_WITH_GLOSSARY=true after the failed re-bootstrap (got $(persisted DEPLOY_WITH_GLOSSARY))" $?
[[ ! -s "$T/dp.log" ]]; check "F1: deploy_project.sh not run after a failed re-bootstrap" $?
[[ "$out" == *"persisted by deploy-all on success"* && "$out" != *"已持久化）"* ]]; check "F1: re-bootstrap path announces deferred persistence, not '已持久化'" $?
# …so the retry still sees a change and re-bootstraps again (the bug was: fast path, host never rebuilt)
: > "$T/da.log"; rm -f "$T/da_rc"
out="$(run_install --yes --action redeploy --with-glossary=false --region us-east-1)"; rc=$?
[[ $rc -eq 0 && "$(grep -c . "$T/da.log")" -eq 1 ]]; check "F1: the retry re-runs deploy-all (rc $rc, deploy-all runs: $(grep -c . "$T/da.log"))" $?
[[ "$(persisted DEPLOY_WITH_GLOSSARY)" == false ]]; check "F1: after a successful re-bootstrap the value is persisted (by deploy-all)" $?
grep -q -- '--skip-projects' "$T/da.log" && grep -q -- '--with-glossary=false' "$T/da.log"; check "F1: deploy-all got --skip-projects + the glossary flag" $?
# fast path: flags given but unchanged → persisted here (explicit key), no deploy-all
reset_host false demo
out="$(run_install --yes --action redeploy --with-glossary=false --glossary-max-files 400 --region us-east-1)"; rc=$?
[[ $rc -eq 0 && ! -s "$T/da.log" && "$(persisted DEPLOY_GLOSSARY_MAX_FILES)" == 400 ]]; check "fast path: unchanged flags → no deploy-all, cap persisted by install.sh (rc $rc)" $?
[[ "$out" == *"skipping the base re-bootstrap"* ]]; check "fast path: says so" $?
# the source order still holds: nothing is persisted between glossary_changed and the deploy-all call
_rd="$(sed -n '/^flow_redeploy() {$/,/^}$/p' "$I")"
_seg="${_rd#*glossary_changed \"\$fv\" \"\$gmf\" && rebootstrap=true}"; _seg="${_seg%%\"\$SCRIPT_DIR/deploy-all.sh\"*}"
[[ "$_seg" != *'update_env "$CONFIG_FILE" DEPLOY_WITH_GLOSSARY'* && "$_seg" != *'DEPLOY_GLOSSARY_MAX_FILES'* ]]; check "F1: no glossary update_env between glossary_changed and the deploy-all call" $?

# F2: a host-wide glossary change re-activates every OTHER project, NO_PROBE=1, selected one first
reset_host true alpha beta gamma
out="$(run_install --yes --action redeploy --project alpha --with-glossary=false --region us-east-1)"; rc=$?
[[ $rc -eq 0 ]]; check "F2: 3 projects, glossary flipped → exit 0 (got $rc)" $?
[[ "$(cat "$T/dp.log")" == $'us-east-1 alpha NO_PROBE=0\nus-east-1 beta NO_PROBE=1\nus-east-1 gamma NO_PROBE=1' ]]; check "F2: alpha (probe) first, then beta + gamma with NO_PROBE=1 (got: $(tr '\n' '|' < "$T/dp.log"))" $?
[[ "$(grep -c . "$T/da.log")" -eq 1 ]]; check "F2: deploy-all ran exactly once" $?
[[ "$out" == *"其余 2 个项目也重新下发"* && "$out" == *"glossary switch is host-wide; redeploying the other 2 projects"* ]]; check "F2: one bilingual info line names the other 2 projects" $?
# no glossary change → no fan-out
reset_host true alpha beta gamma
run_install --yes --action redeploy --project alpha --region us-east-1 >/dev/null; rc=$?
[[ $rc -eq 0 && "$(cat "$T/dp.log")" == "us-east-1 alpha NO_PROBE=0" ]]; check "F2: no glossary change → only the selected project is redeployed" $?
# one of the others fails: warn, continue with the rest, exit non-zero at the end
reset_host true alpha beta gamma; echo beta > "$T/dp_fail"
out="$(run_install --yes --action redeploy --project alpha --with-glossary=false --region us-east-1)"; rc=$?
[[ $rc -ne 0 ]]; check "F2: a failed fan-out redeploy makes the run exit non-zero (got $rc)" $?
grep -q 'gamma NO_PROBE=1' "$T/dp.log"; check "F2: …but the remaining project (gamma) was still redeployed" $?
[[ "$out" == *"redeploy of beta failed"* && "$out" == *"--action redeploy --project beta"* ]]; check "F2: warns per failed project with the exact re-run command" $?
[[ "$out" == *"the other projects failed to redeploy: beta"* ]]; check "F2: closing error lists the failed projects" $?
[[ "$(persisted DEPLOY_GLOSSARY_PENDING_PROJECTS)" == beta ]]
check "failed project remains pending after the global choice was committed" $?
rm -f "$T/dp_fail"; : > "$T/dp.log"
out="$(run_install --yes --action redeploy --project alpha --region us-east-1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/dp.log")" == $'us-east-1 alpha NO_PROBE=0\nus-east-1 beta NO_PROBE=1' ]]
check "retry without glossary flags reconciles the unfinished project" $?
[[ -z "$(persisted DEPLOY_GLOSSARY_PENDING_PROJECTS)" ]]
check "successful retry clears the pending project list" $?

# A removed failed project must not keep poisoning the host-wide rollout.
# Keep another real pending project to prove the filter still retries it.
reset_host false alpha gamma
printf 'DEPLOY_GLOSSARY_PENDING_PROJECTS=beta gamma\n' >> "$T/.local/deploy-config"
echo beta > "$T/dp_fail"
out="$(run_install --yes --action redeploy --project alpha --region us-east-1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/dp.log")" == $'us-east-1 alpha NO_PROBE=0\nus-east-1 gamma NO_PROBE=1' ]]
check "deleted pending beta is skipped while the remaining pending gamma is redeployed" $?
[[ -z "$(persisted DEPLOY_GLOSSARY_PENDING_PROJECTS)" ]]
check "deleted projects are removed from the durable pending list" $?
: > "$T/dp.log"
out="$(run_install --yes --action redeploy --project alpha --region us-east-1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/dp.log")" == "us-east-1 alpha NO_PROBE=0" ]]
check "a second redeploy no longer retries or fails on the deleted project" $?
rm -f "$T/.local/deploy-config" "$T/.local/projects.json"

echo "  $_run run, $_fail failed"
[[ "$_fail" -eq 0 ]]
