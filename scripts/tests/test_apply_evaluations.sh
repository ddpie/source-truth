#!/usr/bin/env bash
# test_apply_evaluations.sh — apply-evaluations.sh 的离线测试（不碰 aws / docker）。
#   项目选择块  : 抽出真实代码段，用临时 projects.json 驱动 —— 缺失 --project → rc 1；空目录 → rc 1；
#                 正常 → 4 行输出，且 Lambda 环境变量是 JSON、多仓库前缀与空前缀都能原样往返
#   打包阶段    : docker build / docker run 都带 --platform linux/arm64（与 --architectures arm64 一致）
#   run_after_role: 角色刚建时对「cannot be assumed by Lambda」有限次重试，其它错误立即失败
#   dry-run     : online 阶段缺 EVALUATOR_IDS 不报错；收尾提示受 stage 门控
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/scripts/apply-evaluations.sh"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }
echo "test_apply_evaluations:"
bash -n "$F"; check "apply-evaluations.sh parses" $?

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 项目选择块：抽出 PROJ_OUT=… 到 ENVVARS=… 这一段真实代码，喂不同的 projects.json ----
# 结束标记取其后一行 VPCCFG=（ENVVARS 的 python -c 跨了三行），再把那一行去掉。
BLOCK="$(sed -n '/^  PROJ_OUT="\$(python3 - /,/^  VPCCFG=/p' "$F" | sed '$d')"
[[ -n "$BLOCK" && "$BLOCK" == *'ENVVARS='* ]]; check "project-selection block extracted (PROJ_OUT … ENVVARS)" $?

drive() {  # drive <root> <--project 值>  -> stdout: 块的输出 + ENVVARS= 行；rc = 块的 rc
  {
    printf 'say() { printf "%%s %%s\\n" "$1" "${*:2}" >&2; }\n'
    printf 'ROOT=%q; PROJECT=%q; BRIDGE_HOST=bridge.test\n' "$1" "$2"
    printf '%s\n' "$BLOCK"
    printf 'printf "NPROJ_LINES=%%s\\n" "${#PROJ[@]}"\nprintf "ENVVARS=%%s\\n" "$ENVVARS"\n'
  } | bash 2>/dev/null
}

# 两个项目：alpha 有两个仓库子目录（逗号！），beta 没有 subdir
mkdir -p "$TMP/two/.local"
cat > "$TMP/two/.local/projects.json" <<'JSON'
{"projects": {
  "alpha": {"port": 8081, "repos": [{"subdir": "core-lib"}, {"subdir": "game/client"}]},
  "beta":  {"port": 8082, "repos": [{"url": "x"}]}
}}
JSON

out="$(drive "$TMP/two" nope)"; rc=$?
[[ $rc -eq 1 ]]; check "--project 指向不存在的项目 → rc 1" $?

out="$(drive "$TMP/two" alpha)"; rc=$?
[[ $rc -eq 0 && "$out" == *"NPROJ_LINES=4"* ]]; check "正常项目 → rc 0，解析出 4 行" $?
env_json="${out##*ENVVARS=}"
vars="$(printf '%s' "$env_json" | python3 -c 'import json,sys; v=json.load(sys.stdin)["Variables"]; print(v["REPO_PREFIXES"]); print(v["BRIDGE_URL"]); print(sorted(v))' 2>/dev/null)"
[[ -n "$vars" ]]; check "--environment 是合法 JSON 且含 Variables" $?
[[ "$(sed -n 1p <<<"$vars")" == "core-lib,game/client" ]]; check "两个 subdir 的前缀以逗号连接并原样往返（CLI 简写会把它拆成两个键）" $?
[[ "$(sed -n 2p <<<"$vars")" == "http://bridge.test:8081/mcp" ]]; check "BRIDGE_URL 取自被选项目的端口" $?
[[ "$(sed -n 3p <<<"$vars")" == "['BRIDGE_URL', 'CITATION_WINDOW', 'READ_LIMIT', 'REPO_PREFIXES']" ]]; check "四个环境变量键齐全" $?

out="$(drive "$TMP/two" beta)"; rc=$?
env_json="${out##*ENVVARS=}"
empty="$(printf '%s' "$env_json" | python3 -c 'import json,sys; print(repr(json.load(sys.stdin)["Variables"]["REPO_PREFIXES"]))' 2>/dev/null)"
[[ $rc -eq 0 && "$empty" == "''" ]]; check "没有 subdir 的项目：REPO_PREFIXES 为空串且 JSON 仍合法" $?

# 没有 projects.json（--local 之前 / 从未部署过项目）：必须失败，不能指到 8080 报成功
mkdir -p "$TMP/none/.local"
out="$(drive "$TMP/none" "" 2>&1)"; rc=$?
[[ $rc -eq 1 ]]; check "没有 .local/projects.json → rc 1（不再默认 8080 + 空前缀）" $?
[[ "$out" != *"ENVVARS="* ]]; check "  …且没有走到构造环境变量这一步" $?
printf '{"projects": {}}' > "$TMP/none/.local/projects.json"
drive "$TMP/none" "" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]]; check "projects.json 里没有项目 → rc 1" $?
grep -q 'no project to evaluate' "$F"; check "失败提示带英文说明（bilingual）" $?

# ---- package 阶段：两条 docker 命令都钉住目标架构 ----
grep -qE '^\s*docker build .*--platform linux/arm64' "$F"; check "docker build 带 --platform linux/arm64" $?
grep -qE '^\s*docker run .*--platform linux/arm64' "$F"; check "docker run（import 自检）带 --platform linux/arm64" $?
grep -q -- '--architectures arm64' "$F"; check "create-function 仍是 --architectures arm64（两处必须一致）" $?

# ---- run_after_role：IAM 传播重试 ----
RAR="$(sed -n '/^run_after_role() {/,/^}$/p' "$F")"
[[ -n "$RAR" ]]; check "run_after_role() 存在" $?
drive_rar() {  # drive_rar <ROLE_JUST_CREATED> <失败次数> <错误文本>
  # 被测函数用 $(…) 捕获命令的 stderr，桩在子 shell 里跑，所以调用次数记在文件里而不是变量里。
  local cnt="$TMP/rar.count"; printf 0 > "$cnt"
  {
    printf 'say() { printf "%%s %%s\\n" "$1" "${*:2}"; }\nsleep() { printf "SLEEP\\n"; }\n'
    printf 'run() { printf "RUN\\n"; "$@"; }\nDRY_RUN=false; ROLE_JUST_CREATED=%s\n' "$1"
    printf 'CNT=%q\nflaky() { local n; n=$(( $(cat "$CNT") + 1 )); printf %%s "$n" > "$CNT"; if [[ $n -le %s ]]; then echo %q >&2; return 254; fi; echo created; }\n' "$cnt" "$2" "$3"
    printf '%s\n' "$RAR"
    printf 'run_after_role flaky; printf "RC=%%s N=%%s\\n" "$?" "$(cat "$CNT")"\n'
  } | bash 2>&1
}
ASSUME='An error occurred (InvalidParameterValueException) when calling the CreateFunction operation: The role defined for the function cannot be assumed by Lambda.'
out="$(drive_rar true 2 "$ASSUME")"
[[ "$out" == *"RC=0 N=3"* ]]; check "角色刚建 + 传播错误：重试后成功（2 次失败 → 第 3 次成功）" $?
[[ "$(grep -c SLEEP <<<"$out")" -eq 2 ]]; check "  …每次重试之间等待一次" $?
out="$(drive_rar true 9 "$ASSUME")"
[[ "$out" == *"RC=1 N=6"* ]]; check "传播错误持续：最多 6 次后放弃并返回非零" $?
out="$(drive_rar true 9 'An error occurred (AccessDeniedException): not authorized to perform lambda:CreateFunction')"
[[ "$out" == *"RC=1 N=1"* && "$out" == *"AccessDeniedException"* ]]; check "非传播类错误：不重试，原文透出" $?
out="$(drive_rar false 9 "$ASSUME")"
[[ "$out" == *"RUN"* && "$out" == *"N=1"* ]]; check "角色早已存在：不重试，直接走 run（错误就是真错误）" $?

# ---- dry-run / stage 门控（文本断言：这些分支无法离线执行到）----
grep -q '\[dry-run\] 将使用 evaluators 阶段输出的 id' "$F"; check "dry-run 下 online 阶段缺 EVALUATOR_IDS 只提示不报错" $?
grep -q '^done_msg "apply-evaluations 完成' "$F"; check "收尾成功行走 done_msg（dry-run 不宣称完成）" $?
grep -q '^if stage evaluators || stage online; then' "$F"; check "收尾提示块受 stage 门控" $?
! grep -q '允许评估服务调用它的资源策略' "$F"; check "头部注释不再声称 iam 阶段加 Lambda 资源策略" $?
grep -q -- '--role-just-created' "$F" && grep -q -- '--role-just-created' "$ROOT/scripts/lib/apply_online_eval.py"; check "online 阶段把「角色刚建」传给 apply_online_eval.py" $?

# Run the actual entry point in an isolated checkout; all AWS calls are recorded
# by a stub, including read calls. Never use the developer's deployment config.
TEST_ROOT="$TMP/entry"
mkdir -p "$TEST_ROOT/scripts/lib" "$TEST_ROOT/.local" "$TEST_ROOT/evaluations" "$TEST_ROOT/index-service" "$TMP/bin"
cp "$F" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/lib/"{common.sh,env-utils.sh} "$TEST_ROOT/scripts/lib/"
cp "$ROOT/evaluations/evaluators.json" "$TEST_ROOT/evaluations/"
cp "$ROOT/index-service/citation_verify.py" "$TEST_ROOT/index-service/"
cp "$TMP/two/.local/projects.json" "$TEST_ROOT/.local/projects.json"
printf 'DEPLOY_REGION=ap-northeast-1\nPRIVATE_SUBNET=subnet-test\nVPC_ID=vpc-test\n' > "$TEST_ROOT/.local/deploy-config"
touch "$TEST_ROOT/.local/citation-evaluator.zip"
export EVAL_TEST_CALLS="$TMP/aws.calls"
cat > "$TMP/bin/aws" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EVAL_TEST_CALLS"
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "ec2 describe-security-groups") echo sg-test ;;
  "lambda get-function")
    if [[ "${EVAL_TEST_DENIED:-}" == 1 ]]; then echo AccessDeniedException >&2; exit 254; fi
    echo '{"Configuration":{"Environment":{"Variables":{"BRIDGE_URL":"http://index.ap-northeast-1.source-truth.internal:8082/mcp","CUSTOM_SETTING":"preserve"}}}}' ;;
  "lambda wait")
    if [[ "${EVAL_TEST_WAIT_FAIL:-}" == 1 && "$*" == *function-active-v2* ]]; then echo waiter_failed >&2; exit 255; fi ;;
esac
SH
chmod +x "$TMP/bin/aws"
export PATH="$TMP/bin:$PATH"
: > "$EVAL_TEST_CALLS"
out="$(bash "$TEST_ROOT/scripts/apply-evaluations.sh" --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -s "$EVAL_TEST_CALLS" ]]; check "full dry-run performs no AWS calls" $?

: > "$EVAL_TEST_CALLS"
EVAL_TEST_DENIED=1 bash "$TEST_ROOT/scripts/apply-evaluations.sh" --only lambda >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'lambda create-function' "$EVAL_TEST_CALLS"
check "GetFunction denial cannot be mistaken for a missing function" $?

: > "$EVAL_TEST_CALLS"
EVAL_TEST_WAIT_FAIL=1 bash "$TEST_ROOT/scripts/apply-evaluations.sh" --only lambda >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q EVALUATOR_LAMBDA_ARN "$TEST_ROOT/.local/deploy-config"
check "failed Lambda waiter returns nonzero and does not persist success" $?

: > "$EVAL_TEST_CALLS"
bash "$TEST_ROOT/scripts/apply-evaluations.sh" --only lambda >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep 'update-function-configuration' "$EVAL_TEST_CALLS" | grep -q '8082/mcp'
check "rerun without --project preserves the existing Lambda bridge selection" $?
grep 'update-function-configuration' "$EVAL_TEST_CALLS" | grep -q CUSTOM_SETTING
check "Lambda update preserves unrelated environment variables" $?
grep 'update-function-code' "$EVAL_TEST_CALLS" | grep -q -- '--architectures arm64'
check "Lambda update converges architecture to the ARM64 package" $?

# Capture Python helper invocation to verify omitted flags stay omitted. The
# native Python interpreter still handles the entry point's JSON validation.
TEST_PYTHON="$(command -v python3)"
cat > "$TMP/bin/python3" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == *apply_online_eval.py ]]; then
  printf '%s\n' "\$*" > "$TMP/online.args"
  exit 0
fi
exec "$TEST_PYTHON" "\$@"
SH
chmod +x "$TMP/bin/python3"
printf 'EVALUATOR_IDS=faith=Builtin.Faithfulness\n' >> "$TEST_ROOT/.local/deploy-config"
bash "$TEST_ROOT/scripts/apply-evaluations.sh" --only online >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -qE -- '--enable|--disable|--sampling' "$TMP/online.args"
check "online rerun forwards no implicit status or sampling overrides" $?
bash "$TEST_ROOT/scripts/apply-evaluations.sh" --only online --disable --sampling 5 >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q -- '--disable --sampling 5' "$TMP/online.args"
check "explicit online state and sampling are forwarded" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
