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
# 阶段:
#   package    在 Lambda 目标架构的容器里打出代码型评估器的 zip（pydantic 带二进制轮子，
#              本机 pip 装出来的包在 Lambda 上可能直接 import 失败）
#   iam        Lambda 执行角色 + 允许评估服务调用它的资源策略
#   lambda     创建/更新函数，挂到私有子网（要能访问 bridge 才能回查仓库）
#   evaluators 用 CreateEvaluator 注册两个评估器：代码型 + LLM-as-judge
#
# 用法:
#   ./scripts/apply-evaluations.sh --region ap-northeast-1
#   ./scripts/apply-evaluations.sh --region ap-northeast-1 --only evaluators
#   ./scripts/apply-evaluations.sh --region ap-northeast-1 --dry-run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env-utils.sh"

REGION=""; ONLY=""; DRY_RUN=false
FN_NAME="source-truth-citation-evaluator"
ROLE_NAME="source-truth-evaluator-lambda-role"
DEFS="$ROOT/evaluations/evaluators.json"
PKG_DIR="$ROOT/evaluations/citation-evaluator"
CONFIG="$ROOT/.local/deploy-config"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) say err "未知参数: $1"; exit 2 ;;
  esac
done

safe_source_env "$CONFIG" 2>/dev/null || true
REGION="${REGION:-${DEPLOY_REGION:-}}"
[[ -n "$REGION" ]] || { say err "必须给 --region（或先让 deploy-all 写好 .local/deploy-config）"; exit 2; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
stage() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
run() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] $*"; else "$@"; fi; }
# 成功消息也必须受 --dry-run 约束。第一版把它们写在 run 之外无条件打印，于是一次 dry-run 会报
# 「✓ 角色已创建」「✓ 函数已创建」——宣称了从未发生的事，正是本仓库反复修过的「报告未曾达成的成功」。
done_msg() { if [[ "$DRY_RUN" == true ]]; then say info "[dry-run] 将会: $*"; else say ok "$*"; fi; }

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
    # 而那种失败只在真正评估时才暴露。本机是 aarch64，原生 build 出的就是 arm64 包（docker 无 buildx）。
    cat > "$BUILD/Dockerfile" <<'DOCKER'
FROM public.ecr.aws/lambda/python:3.12
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt --target /pkg
COPY lambda_function.py bridge_client.py citation_verify.py /pkg/
DOCKER
    say info "构建打包镜像 ..."
    docker build -q -t source-truth-eval-pkg "$BUILD" >/dev/null
    CID="$(docker create source-truth-eval-pkg)"
    rm -f "$ZIP"
    docker cp "$CID:/pkg" "$BUILD/pkg" >/dev/null
    docker rm -f "$CID" >/dev/null
    ( cd "$BUILD/pkg" && zip -qr "$ZIP" . )
    say ok "打包完成: $ZIP ($(du -h "$ZIP" | cut -f1))"
    # 装完就地验证 import。一个装错架构的 pydantic-core 只有在真正 import 时才报错，
    # 而那时错误会以「评估器故障」的形式出现在评估数据里，很难追回打包这一步。
    docker run --rm --entrypoint python source-truth-eval-pkg \
      -c "import sys; sys.path.insert(0,'/pkg'); import lambda_function; print('import ok:', lambda_function.lambda_handler.__name__)" \
      || { say err "打出来的包无法 import —— 依赖或架构不对，拒绝上传"; exit 1; }
  fi
fi

# =====================================================================================
say step "阶段 iam：Lambda 执行角色"
if stage iam; then
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
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
  SUBNET="${PRIVATE_SUBNET:-}"
  [[ -n "$SUBNET" ]] || { say err "deploy-config 里没有 PRIVATE_SUBNET —— 先跑 deploy-all 的 network 阶段"; exit 1; }
  # 复用 index-svc 安全组：bridge 的入站规则是「同 SG 成员的 8080-8099」，所以 Lambda 必须在这个组里
  # 才够得到 bridge。这也意味着评估器和 runtime 一样受这条边界约束，不是额外开了个口子。
  SG="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=source-truth-index-svc" "Name=vpc-id,Values=${VPC_ID:-}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")"
  [[ -n "$SG" && "$SG" != "None" ]] || { say err "找不到 source-truth-index-svc 安全组"; exit 1; }

  BRIDGE_HOST="index.${REGION}.source-truth.internal"
  PORT="$(python3 -c "
import json,sys,pathlib
p = pathlib.Path('$ROOT/.local/projects.json')
if not p.exists():
    print(8080); raise SystemExit
d = json.loads(p.read_text()).get('projects') or {}
first = next(iter(d.values()), {}) if isinstance(d, dict) else (d[0] if d else {})
print(first.get('port') or 8080)
" 2>/dev/null || echo 8080)"
  BRIDGE_URL="http://${BRIDGE_HOST}:${PORT}/mcp"
  say info "bridge 地址: $BRIDGE_URL"

  # 仓库子目录名。答案里的出处常写成裸文件名或缺这一层前缀的路径，校验器需要它才能把出处映射回
  # 仓库——真机首次运行时这是最大的假失败来源（4 个 trace 全判 Fail，而出处经核对全部真实存在）。
  PREFIXES="$(python3 -c "
import json, pathlib
p = pathlib.Path('$ROOT/.local/projects.json')
if not p.exists():
    print(''); raise SystemExit
d = json.loads(p.read_text()).get('projects') or {}
items = d.values() if isinstance(d, dict) else d
subs = []
for cfg in items:
    for repo in (cfg or {}).get('repos', []):
        s = repo.get('subdir')
        if s and s not in subs:
            subs.append(s)
print(','.join(subs))
" 2>/dev/null || echo "")"
  say info "仓库前缀: ${PREFIXES:-<无>}"

  ENVVARS="Variables={BRIDGE_URL=$BRIDGE_URL,CITATION_WINDOW=4,READ_LIMIT=400,REPO_PREFIXES=$PREFIXES}"
  VPCCFG="SubnetIds=$SUBNET,SecurityGroupIds=$SG"
  ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

  if aws lambda get-function --region "$REGION" --function-name "$FN_NAME" >/dev/null 2>&1; then
    run aws lambda update-function-code --region "$REGION" --function-name "$FN_NAME" \
      --zip-file "fileb://$ZIP" >/dev/null
    # 代码与配置分两次调用，中间必须等函数回到 Active，否则第二次调用会撞上
    # ResourceConflictException（更新进行中），而那次失败会让配置停在旧值上。
    run aws lambda wait function-updated --region "$REGION" --function-name "$FN_NAME"
    run aws lambda update-function-configuration --region "$REGION" --function-name "$FN_NAME" \
      --timeout 120 --memory-size 512 --environment "$ENVVARS" --vpc-config "$VPCCFG" >/dev/null
    done_msg "函数已更新: $FN_NAME"
  else
    run aws lambda create-function --region "$REGION" --function-name "$FN_NAME" \
      --runtime python3.12 --architectures arm64 --handler lambda_function.lambda_handler \
      --role "$ROLE_ARN" --zip-file "fileb://$ZIP" \
      --timeout 120 --memory-size 512 --environment "$ENVVARS" --vpc-config "$VPCCFG" \
      --description "Deterministically verifies source citations for AgentCore Evaluations" >/dev/null
    done_msg "函数已创建: $FN_NAME"
  fi
  run aws lambda wait function-active-v2 --region "$REGION" --function-name "$FN_NAME" 2>/dev/null || true
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
      --region "$REGION" --defs "$DEFS" --lambda-arn "$FN_ARN")" || {
        say err "评估器注册失败"; printf '%s\n' "$OUT"; exit 1; }
    printf '%s\n' "$OUT"
    # 评估器 id 是后续 Evaluate / 批量评估的唯一句柄，写回配置，免得只能靠翻控制台找。
    IDS="$(printf '%s\n' "$OUT" | sed -n 's/^EVALUATOR_ID *\([^ ]*\) *\(.*\)$/\1=\2/p' | tr '\n' ';')"
    [[ -n "$IDS" ]] && update_env "$CONFIG" EVALUATOR_IDS "$IDS"
  fi
fi

say ok "apply-evaluations 完成（region=$REGION）"
say info "跑一次评估：aws bedrock-agentcore evaluate --region $REGION --evaluator-id <id> --evaluation-input file://spans.json"
say info "拆除：./scripts/teardown.sh 会删除这两个评估器与该 Lambda"
