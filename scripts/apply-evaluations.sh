#!/usr/bin/env bash
# apply-evaluations.sh — 部署本项目的两个自定义 AgentCore 评估器（幂等，可重复运行）。
#
# 为什么这是**独立入口**、不挂进 deploy-all 的必经路径：
#   1. 评估不是服务依赖。机器人回答问题不需要它，装不上也不该让一次部署失败。
#   2. 它花钱且花的是另一类钱——一个常驻 Lambda，加上 LLM-as-judge 评估器每次判定的模型 token。
#      把它塞进默认部署，等于让每个只想试用这个 sample 的人为评估付费。
#   3. 它需要一份**已经跑过真实问答**的遥测才有意义。在首次部署时创建它，除了空跑什么都得不到。
# 与 apply-monitoring.sh 同一约定：--only 选单个阶段、--dry-run 只打印、每步 describe-or-create。
#
# 阶段（按序执行，--only 选其一）: package → iam → lambda → evaluators → online
#   package    在 Lambda 目标架构的容器里打出代码型评估器的 zip（pydantic 带二进制轮子，
#              本机 pip 装出来的包在 Lambda 上可能直接 import 失败）
#   iam        Lambda 执行角色（评估服务调用 Lambda 的权限在 online 阶段的执行角色策略里，不加资源策略）
#   lambda     创建/更新函数，挂到私有子网（要能访问 bridge 才能回查仓库）
#   evaluators 用 CreateEvaluator 注册两个评估器：代码型 + LLM-as-judge
#   online     评估服务执行角色 + 每个 runtime 一份实时评估配置；默认创建为 DISABLED
#
# 选项:
#   --region <r>      目标区域（缺省取 .local/deploy-config 的 DEPLOY_REGION）
#   --only <stage>    只跑一个阶段
#   --project <pid>   评估 Lambda 回查哪个项目的 bridge；重跑保留已有选择，新建默认第一个
#   --enable/--disable online 显式切换状态；省略时保留已有状态，新建默认禁用
#   --sampling <N>    online 采样百分比；省略时保留已有值，新建默认 100
#   --dry-run         只打印将要执行的动作
#   环境变量 EVAL_JUDGE_MODEL 可显式指定评委模型推理档 id；缺省按区域自动解析
#
# 用法:
#   ./scripts/apply-evaluations.sh --region <region>
#   ./scripts/apply-evaluations.sh --region <region> --only evaluators
#   ./scripts/apply-evaluations.sh --region <region> --project <pid> --enable --sampling 20
#   ./scripts/apply-evaluations.sh --region <region> --dry-run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env-utils.sh"

REGION=""; ONLY=""; DRY_RUN=false; ENABLE_ONLINE=""; SAMPLING=""; PROJECT=""
FN_NAME="source-truth-citation-evaluator"
ROLE_NAME="source-truth-evaluator-lambda-role"
DEFS="$ROOT/evaluations/evaluators.json"
PKG_DIR="$ROOT/evaluations/citation-evaluator"
CONFIG="$ROOT/.local/deploy-config"

usage() {
  sed -n '2,/^set -euo/{/^set -euo/d;p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region|--only|--sampling|--project)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { say err "$1 requires a value"; exit 2; } ;;
  esac
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    # 实时评估默认只创建不启用：启用中的 config 会锁定评估器，评估器还在迭代时就开等于自锁。
    --enable|--disable)
      WANT_ENABLE=true; [[ "$1" == --disable ]] && WANT_ENABLE=false
      [[ -z "$ENABLE_ONLINE" || "$ENABLE_ONLINE" == "$WANT_ENABLE" ]] || {
        say err "--enable and --disable are mutually exclusive"; exit 2; }
      ENABLE_ONLINE="$WANT_ENABLE"; shift ;;
    --sampling) SAMPLING="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) say err "未知参数: $1"; exit 2 ;;
  esac
done

safe_source_env "$CONFIG" 2>/dev/null || true
REGION="${REGION:-${DEPLOY_REGION:-}}"
[[ -n "$REGION" ]] || { say err "必须给 --region（或先让 deploy-all 写好 .local/deploy-config）"; exit 2; }
require_deploy_region "${DEPLOY_REGION:-}" "$REGION" || exit 2
case "$ONLY" in ""|package|iam|lambda|evaluators|online) ;; *) say err "未知阶段: $ONLY"; exit 2 ;; esac
python3 - "${SAMPLING:-100}" <<'PY'
import sys
try:
    valid = 0 <= float(sys.argv[1]) <= 100
except ValueError:
    valid = False
if not valid:
    raise SystemExit("--sampling must be between 0 and 100")
PY

if [[ "$DRY_RUN" == true ]]; then ACCOUNT="<account-id>"
else ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"; fi
stage() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
run() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] $*"; else "$@"; fi; }
# 成功消息也必须受 --dry-run 约束。第一版把它们写在 run 之外无条件打印，于是一次 dry-run 会报
# 「✓ 角色已创建」「✓ 函数已创建」——宣称了从未发生的事，正是本仓库反复修过的「报告未曾达成的成功」。
done_msg() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] 将会: $*"; else say ok "$*"; fi; }
# Only an explicit missing-resource response authorizes creation.
resource_exists() {
  local err
  if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
  case "$err" in *"(NoSuchEntity)"*|*"(ResourceNotFoundException)"*) return 1 ;; esac
  printf '%s\n' "$err" >&2
  exit 1
}
# 刚 create-role 的角色对 Lambda 可能还不可见（IAM 最终一致）：create-function 会报
# InvalidParameterValueException「The role defined for the function cannot be assumed by Lambda」。
# 只在**本次运行**建了角色时重试（最多 6 次、间隔 10 s）；角色早已存在时这个错误就是真错误，不该被吞。
ROLE_JUST_CREATED=false; ONLINE_ROLE_JUST_CREATED=false
run_after_role() {  # run_after_role <cmd...>
  if [[ "$ROLE_JUST_CREATED" != true || "$DRY_RUN" == true ]]; then run "$@"; return; fi
  local attempt err
  for attempt in 1 2 3 4 5 6; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    if [[ $attempt -lt 6 && "$err" == *"cannot be assumed by Lambda"* ]]; then
      say info "角色尚未传播到 Lambda，10 s 后重试 ($attempt/6) / role not yet visible to Lambda, retrying"
      sleep 10; continue
    fi
    printf '%s\n' "$err" >&2; return 1
  done
}

# --- 前置：evaluator 定义必须可解析。宁可在这里失败，也不要创建出半套资源 ---
[[ -f "$DEFS" ]] || { say err "缺少 $DEFS"; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DEFS" \
  || { say err "$DEFS 不是合法 JSON"; exit 1; }

# =====================================================================================
say step "阶段 package：在 Lambda 目标架构下打包"
ZIP="$ROOT/.local/citation-evaluator.zip"
if stage package; then
  # citation_verify.py 的**唯一副本**在 index-service/。这里在打包时复制进去，而不是在本目录再存一份：
  # 两份副本必然漂移，而漂移的那一天，评估器和线上服务对「什么算合法出处」的判断会悄悄分叉。
  CANON="$ROOT/index-service/citation_verify.py"
  [[ -f "$CANON" ]] || { say err "找不到 $CANON —— 判据模块的唯一副本"; exit 1; }
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] 复制 $CANON 到打包目录并在容器内 pip install，输出 $ZIP"
  else
    mkdir -p "$ROOT/.local"
    BUILD="$(mktemp -d)"
    trap 'rm -rf "$BUILD"' EXIT
    cp "$PKG_DIR/lambda_function.py" "$PKG_DIR/bridge_client.py" "$PKG_DIR/requirements.txt" "$BUILD/"
    cp "$CANON" "$BUILD/citation_verify.py"
    # 用 Lambda 官方基础镜像装依赖：pydantic-core 是二进制轮子，架构不对会在运行时 import 失败，
    # 而那种失败只在真正评估时才暴露。--platform 必须与下面 create-function 的 --architectures arm64
    # 一致：x86 部署机上不带它会装出 x86_64 轮子，且容器内的 import 自检在同一个错误架构上照样通过。
    cat > "$BUILD/Dockerfile" <<'DOCKER'
FROM public.ecr.aws/lambda/python:3.12
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt --target /pkg
COPY lambda_function.py bridge_client.py citation_verify.py /pkg/
DOCKER
    say info "构建打包镜像 ..."
    docker build --platform linux/arm64 -q -t source-truth-eval-pkg "$BUILD" >/dev/null
    CID="$(docker create source-truth-eval-pkg)"
    rm -f "$ZIP"
    docker cp "$CID:/pkg" "$BUILD/pkg" >/dev/null
    docker rm -f "$CID" >/dev/null
    ( cd "$BUILD/pkg" && zip -qr "$ZIP" . )
    say ok "打包完成: $ZIP ($(du -h "$ZIP" | cut -f1))"
    # 装完就地验证 import。一个装错架构的 pydantic-core 只有在真正 import 时才报错，
    # 而那时错误会以「评估器故障」的形式出现在评估数据里，很难追回打包这一步。
    docker run --rm --platform linux/arm64 --entrypoint python source-truth-eval-pkg \
      -c "import sys; sys.path.insert(0,'/pkg'); import lambda_function; print('import ok:', lambda_function.lambda_handler.__name__)" \
      || { say err "打出来的包无法 import —— 依赖或架构不对，拒绝上传"; exit 1; }
  fi
fi

# =====================================================================================
say step "阶段 iam：Lambda 执行角色"
if stage iam; then
  if [[ "$DRY_RUN" != true ]] && resource_exists aws iam get-role --role-name "$ROLE_NAME"; then
    say ok "角色已存在: $ROLE_NAME"
  else
    # 信任策略内联且写成单行、紧接重定向收尾。scripts/tests/validate_iam_policies.py 按「标志名 +
    # 字面 JSON + 重定向」的形状定位文档边界：放进变量它只看到变量名，写成多行它匹配不到，两种情况下
    # 这份策略都处于「未被审」状态而守卫仍是绿的。apply-observability.sh 同样为此内联过。
    #
    # 本段注释刻意不写出那个标志名本身。第一版写了，于是 DOC_RE（带 re.S）从注释里的引号一路匹配到
    # 下面真实 JSON 的结尾，抽出一段垃圾并报「invalid JSON」——守卫分不清代码和讲代码的散文，
    # 这已是本轮第三次踩到同一类问题。
    run aws iam create-role --role-name "$ROLE_NAME" \
      --description "source-truth citation evaluator Lambda" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    ROLE_JUST_CREATED=true
    done_msg "角色已创建: $ROLE_NAME"
  fi
  # 只给两样：写日志，以及在 VPC 里建/删 ENI。评估器不读 S3、不调 Bedrock、不碰 Secrets——
  # 它唯一要做的事就是把一行源码读回来比对。
  run aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole >/dev/null
  done_msg "已附加 AWSLambdaVPCAccessExecutionRole（含 CloudWatch Logs + ENI 管理）"
fi

# =====================================================================================
say step "阶段 lambda：函数（挂私有子网以访问 bridge）"
if stage lambda; then
  [[ "$DRY_RUN" == true || -f "$ZIP" ]] || { say err "缺少 $ZIP —— 先跑 --only package / run --only package first"; exit 1; }
  SUBNET="${PRIVATE_SUBNET:-}"
  [[ -n "$SUBNET" ]] || { say err "deploy-config 里没有 PRIVATE_SUBNET —— 先跑 deploy-all 的 network 阶段"; exit 1; }
  # 复用 index-svc 安全组：bridge 的入站规则是「同 SG 成员的 8080-8099」，所以 Lambda 必须在这个组里
  # 才够得到 bridge。这也意味着评估器和 runtime 一样受这条边界约束，不是额外开了个口子。
  [[ -n "${VPC_ID:-}" ]] || { say err "deploy-config 里没有 VPC_ID"; exit 1; }
  if [[ "$DRY_RUN" == true ]]; then SG="<index-security-group>"
  else SG="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=${VPC_ID:-}" \
    --query 'SecurityGroups[0].GroupId' --output text)"; fi
  [[ -n "$SG" && "$SG" != "None" ]] || { say err "找不到 source-truth-index-svc 安全组"; exit 1; }

  # bridge 主机名与 runtime 用同一来源（deploy_project.sh 的 IDX_ENDPOINT），不再写死区域域名。
  BRIDGE_HOST="${INDEX_DNS_NAME:-${INDEX_SERVICE_IP:-index.${REGION}.source-truth.internal}}"
  FUNCTION_JSON="{}"; FUNCTION_EXISTS=false; EXISTING_BRIDGE=""
  if [[ "$DRY_RUN" != true ]]; then
    if FUNCTION_JSON="$(aws lambda get-function --region "$REGION" --function-name "$FN_NAME" --output json 2>&1)"; then
      FUNCTION_EXISTS=true
      EXISTING_BRIDGE="$(python3 -c 'import json,sys
c=json.load(sys.stdin)["Configuration"]; env=c.get("Environment") or {}
if env.get("Error"): raise SystemExit("Cannot read existing Lambda environment")
print((env.get("Variables") or {}).get("BRIDGE_URL", ""))' <<< "$FUNCTION_JSON")"
    elif [[ "$FUNCTION_JSON" == *"(ResourceNotFoundException)"* ]]; then
      FUNCTION_JSON="{}"
    else
      printf '%s\n' "$FUNCTION_JSON" >&2; exit 1
    fi
  fi
  # 一个 Lambda 只能指向**一个** bridge 端口，而 apply_online_eval.py 会给每个 runtime 各建一份配置。
  # 多项目时只有被选中项目的出处能被校验，其它项目的出处会被判 PATH_REFUSED / FILE_NOT_FOUND 记为 Fail；--project 选哪一个。
  # 输出四行：pid、port、逗号分隔的仓库子目录、项目总数。
  # 仓库子目录是必需的：答案里的出处常写成裸文件名或缺这一层前缀的路径，校验器需要它才能把出处映射回
  # 仓库——真机首次运行时这是最大的假失败来源（4 个 trace 全判 Fail，而出处经核对全部真实存在）。
  # 先捕获再拆行：`mapfile < <(python3 …)` 的退出码来自 mapfile 本身，python 失败会被吞掉，
  # 脚本会拿着空数组继续，把 Lambda 指到默认端口还报「已创建」。
  PROJ_OUT="$(python3 - "$ROOT/.local/projects.json" "$PROJECT" "${EXISTING_BRIDGE:-}" "$BRIDGE_HOST" <<'PYPROJ'
import json, pathlib, sys
p, want = pathlib.Path(sys.argv[1]), sys.argv[2]
d = json.loads(p.read_text()).get("projects") or {} if p.exists() else {}
if not isinstance(d, dict):
    raise SystemExit("projects.json projects must be an object")
if not want and sys.argv[3]:
    matches = [pid for pid, cfg in d.items()
               if sys.argv[3] == f"http://{sys.argv[4]}:{cfg.get('port') or 8080}/mcp"]
    if len(matches) != 1:
        raise SystemExit("Existing Lambda bridge cannot be mapped uniquely; specify --project")
    want = matches[0]
if want and want not in d:
    print(f"projects.json 里没有项目 {want!r}；有: {', '.join(d) or '（无）'}", file=sys.stderr)
    raise SystemExit(1)
pid = want or (next(iter(d)) if d else "")
cfg = d.get(pid) or {}
subs = []
for repo in cfg.get("repos", []):
    s = repo.get("subdir")
    if s and s not in subs:
        subs.append(s)
print(pid); print(cfg.get("port") or 8080); print(",".join(subs)); print(len(d))
PYPROJ
  )" || { say err "无法从 projects.json 选出项目"; exit 1; }
  mapfile -t PROJ <<< "$PROJ_OUT"
  [[ "${#PROJ[@]}" -eq 4 ]] || { say err "projects.json 解析结果异常（期望 4 行，得到 ${#PROJ[@]} 行）"; exit 1; }
  PID="${PROJ[0]}"; PORT="${PROJ[1]}"; PREFIXES="${PROJ[2]}"; NPROJ="${PROJ[3]}"
  # 没有项目就没有可回查的 bridge：指到默认端口再报「已创建」是假成功。
  [[ -n "$PID" ]] || { say err "没有 .local/projects.json 或其中没有项目 —— 评估必须建立在已部署的项目上 / no project to evaluate"; exit 1; }
  if [[ "${NPROJ}" -gt 1 && -z "$PROJECT" ]]; then
    say warn "projects.json 有 ${NPROJ} 个项目：评估 Lambda 只回查项目「${PID}」的 bridge，其它项目的出处会被判 PATH_REFUSED / FILE_NOT_FOUND 记为 Fail"
    say warn "  要评估别的项目，用 --project <pid> 重跑 lambda 阶段（目前一个 Lambda 只能指向一个 bridge）"
  fi
  BRIDGE_URL="http://${BRIDGE_HOST}:${PORT}/mcp"
  say info "bridge 地址: $BRIDGE_URL（项目: ${PID}）"

  say info "仓库前缀: ${PREFIXES:-<无>}"

  # 环境变量用 JSON 文档而不是 CLI 简写：简写里逗号是分隔符，多仓库项目的 REPO_PREFIXES="a,b"
  # 会被拆成两个键，空值则让整段解析失败。
  ENVVARS="$(python3 -c 'import json, sys
existing=json.load(sys.stdin).get("Configuration", {}).get("Environment", {}).get("Variables", {})
existing.update({"BRIDGE_URL": sys.argv[1], "CITATION_WINDOW": "4",
                 "READ_LIMIT": "400", "REPO_PREFIXES": sys.argv[2]})
print(json.dumps({"Variables": existing}))' "$BRIDGE_URL" "$PREFIXES" <<< "${FUNCTION_JSON:-"{}"}")"
  VPCCFG="SubnetIds=$SUBNET,SecurityGroupIds=$SG"
  ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

  if [[ "$FUNCTION_EXISTS" == true ]]; then
    run aws lambda update-function-code --region "$REGION" --function-name "$FN_NAME" \
      --zip-file "fileb://$ZIP" --architectures arm64 >/dev/null
    # 代码与配置分两次调用，中间必须等函数回到 Active，否则第二次调用会撞上
    # ResourceConflictException（更新进行中），而那次失败会让配置停在旧值上。
    run aws lambda wait function-updated --region "$REGION" --function-name "$FN_NAME"
    run aws lambda update-function-configuration --region "$REGION" --function-name "$FN_NAME" \
      --timeout 120 --memory-size 512 --environment "$ENVVARS" --vpc-config "$VPCCFG" >/dev/null
    run aws lambda wait function-updated --region "$REGION" --function-name "$FN_NAME"
  else
    run_after_role aws lambda create-function --region "$REGION" --function-name "$FN_NAME" \
      --runtime python3.12 --architectures arm64 --handler lambda_function.lambda_handler \
      --role "$ROLE_ARN" --zip-file "fileb://$ZIP" \
      --timeout 120 --memory-size 512 --environment "$ENVVARS" --vpc-config "$VPCCFG" \
      --description "Deterministically verifies source citations for AgentCore Evaluations" >/dev/null
  fi
  run aws lambda wait function-active-v2 --region "$REGION" --function-name "$FN_NAME"
  done_msg "函数已就绪: $FN_NAME"
  FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN_NAME}"
  run update_env "$CONFIG" EVALUATOR_LAMBDA_ARN "$FN_ARN"
fi

# =====================================================================================
say step "阶段 evaluators：注册两个自定义评估器"
if stage evaluators; then
  FN_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN_NAME}"
  if [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] 按 evaluators.json 创建/复用评估器（代码型 + LLM-as-judge）"
  else
    OUT="$(python3 "$SCRIPT_DIR/lib/apply_evaluators.py" \
      --region "$REGION" --defs "$DEFS" --lambda-arn "$FN_ARN" \
      --judge-model "${EVAL_JUDGE_MODEL:-}")" || {
        say err "评估器注册失败"; printf '%s\n' "$OUT"; exit 1; }
    printf '%s\n' "$OUT"
    # 评估器 id 是后续 Evaluate / 批量评估的唯一句柄，写回配置，免得只能靠翻控制台找。
    # 只取前两个空白分隔的字段（key 与 id）。第一版用 `\(.*\)$` 抓第二段，把行尾的
    # 「(已存在，复用)」一起写进了配置，下游拿到的是一整行文本而不是 id。
    IDS="$(printf '%s\n' "$OUT" | awk '/^EVALUATOR_ID/ {printf "%s=%s;", $2, $3}')"
    [[ -n "$IDS" ]] && update_env "$CONFIG" EVALUATOR_IDS "$IDS"
  fi
fi

# =====================================================================================
# 实时（online）评估：按采样率自动评估线上流量，不用手工取 span 再调 Evaluate。
#
# 默认**只创建、不启用**，必须显式 --enable。原因不是谨慎，是一条硬约束加一个真实教训：
#   * 启用中的 online config 会**锁定**它引用的评估器——不先禁用 config，评估器既不能改也不能删。
#     所以在评估器还在迭代时开启它，等于给自己上锁。
#   * 100% 采样意味着每一次线上问答都被当前版本评分。评估器若有已知的误判（本项目的 citation 评估器
#     就曾把路径里的目录名当成待核对符号，产出假 symbol_mismatch），这些错误结论会持续写进评估数据，
#     而评估数据的用途恰恰是判断答案质量——污染它比没有它更糟。
# 先让评估器在 on-demand 模式下稳定，再开实时。
say step "阶段 online：实时评估配置（采样 ${SAMPLING:-保留已有值；新建100}%，默认新建为禁用）"
if stage online; then
  ONLINE_ROLE="source-truth-evaluation-exec-role"
  # 评估服务自己的执行角色：读 CloudWatch Logs 取 span、调用代码型评估器的 Lambda、调用评委模型。
  if [[ "$DRY_RUN" != true ]] && resource_exists aws iam get-role --role-name "$ONLINE_ROLE"; then
    say ok "执行角色已存在: $ONLINE_ROLE"
  else
    # 单行内联并以重定向收尾——validate_iam_policies.py 依此定位文档边界（见上文 create-role 处的说明）。
    run aws iam create-role --role-name "$ONLINE_ROLE" \
      --description "AgentCore Evaluations execution role for source-truth" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"'"${ACCOUNT}"'"}}}]}' >/dev/null
    ONLINE_ROLE_JUST_CREATED=true
    done_msg "执行角色已创建: $ONLINE_ROLE"
  fi
  # 两个标志必须相邻（中间只一个空格）：validate_iam_policies.py 的模式要求策略名紧接着文档，
  # 中间隔一个续行符它就匹配不到，于是这份策略处于「未被审」状态而守卫仍是绿的。
  run aws iam put-role-policy --role-name "$ONLINE_ROLE" --policy-name evaluation-exec --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"ReadSpans","Effect":"Allow","Action":["logs:StartQuery","logs:GetQueryResults","logs:FilterLogEvents","logs:DescribeLogGroups","logs:DescribeLogStreams","logs:GetLogEvents"],"Resource":"*"},{"Sid":"WriteEvaluationResults","Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:PutRetentionPolicy"],"Resource":["arn:aws:logs:*:'"${ACCOUNT}"':log-group:/aws/bedrock-agentcore/evaluations/*","arn:aws:logs:*:'"${ACCOUNT}"':log-group:/aws/bedrock-agentcore/evaluations/*:*","arn:aws:logs:*:'"${ACCOUNT}"':log-group::log-stream:*"]},{"Sid":"InvokeCodeEvaluator","Effect":"Allow","Action":["lambda:InvokeFunction","lambda:GetFunction"],"Resource":"arn:aws:lambda:*:'"${ACCOUNT}"':function:source-truth-citation-evaluator"},{"Sid":"InvokeJudgeModel","Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream","bedrock:Converse","bedrock:ConverseStream"],"Resource":"*"}]}' >/dev/null
  done_msg "执行角色策略已写入（读日志 + 调 Lambda + 调评委模型）"

  # 评估器 id：从上一阶段的输出或配置里取
  safe_source_env "$CONFIG" 2>/dev/null || true
  IDS_RAW="${EVALUATOR_IDS:-}"
  if [[ -z "$IDS_RAW" && "$DRY_RUN" == true ]]; then
    # dry-run 下 evaluators 阶段没有真的写配置，这里拿不到 id 是预期内的，不是错误。
    say info "[dry-run] 将使用 evaluators 阶段输出的 id 创建实时评估配置"
  elif [[ -z "$IDS_RAW" ]]; then
    say err "配置里没有 EVALUATOR_IDS —— 先跑 --only evaluators"
    exit 1
  else
    ONLINE_FLAGS=(); [[ "$ENABLE_ONLINE" == true ]] && ONLINE_FLAGS+=(--enable)
    [[ "$ENABLE_ONLINE" == false ]] && ONLINE_FLAGS+=(--disable)
    [[ -n "$SAMPLING" ]] && ONLINE_FLAGS+=(--sampling "$SAMPLING")
    # 角色刚建好时服务端可能还 assume 不了它；把这个事实告诉脚本，让它只在这种情况下重试。
    [[ "$ONLINE_ROLE_JUST_CREATED" == true ]] && ONLINE_FLAGS+=(--role-just-created)
    run python3 "$SCRIPT_DIR/lib/apply_online_eval.py" \
      --region "$REGION" \
      --evaluator-ids "$IDS_RAW" \
      --role-arn "arn:aws:iam::${ACCOUNT}:role/${ONLINE_ROLE}" \
      "${ONLINE_FLAGS[@]}"
  fi
fi

done_msg "apply-evaluations 完成（region=$REGION）"
# 收尾提示只在 evaluators / online 阶段真的跑过时才有意义：--only package 之后说「实时评估已启用」是假话。
if stage evaluators || stage online; then
  say info "按需评估：aws bedrock-agentcore evaluate --region $REGION --evaluator-id <id> --evaluation-input file://spans.json"
  if ! stage online; then
    :
  elif [[ "$DRY_RUN" == true ]]; then
    say info "[dry-run] 实时评估：未显式指定的状态/采样保留已有值，新建默认 DISABLED / 100%"
  elif [[ "$ENABLE_ONLINE" == true ]]; then
    say warn "实时评估已启用——被引用的评估器现在处于锁定状态，改动前须先禁用此配置"
  elif [[ "$ENABLE_ONLINE" == false ]]; then
    say info "实时评估已禁用"
  else
    say info "已有实时评估状态和采样率已保留；新配置默认禁用、100% 采样"
  fi
  say info "拆除：./scripts/teardown.sh 会先删 online config（它锁定评估器），再删评估器与 Lambda"
fi
