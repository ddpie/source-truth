#!/usr/bin/env bash
# 可观测性接线的 AWS 侧配置。幂等，可重复执行。
#
# 为什么需要这个脚本：容器改成经 opentelemetry-instrument 启动之后，agent 会产出 span，但那些 span
# 能不能被查询到，取决于三件**不在容器里**的事，而它们此前只以 runbook 散文的形式存在，只能手工做：
#
#   1. CloudWatch Transaction Search（账号 + 区域级）——把 trace segment 投向 CloudWatch Logs，
#      并给 X-Ray 加一条 logs 资源策略。不开的话 span 产出了也无处落。
#   2. 每个 runtime 的 TRACES 投递——账号级开关只是前提，trace 仍要按 runtime 配置投递源与目标。
#   3. 每个 runtime 的 APPLICATION_LOGS 投递——不配的话 runtime 日志组里只有平台事件（例如拉镜像
#      失败），应用自己的输出一行都不会到，日志流全是 0 字节。这一条实测踩过。
#
# 三件都缺时的症状完全一样：一切看起来配好了，就是没有数据。所以这里每一步做完都回读校验，
# 而不是以命令返回 0 为准。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REGION="${1:?usage: apply-observability.sh <region> [account-id]}"
ACCOUNT="${2:-$(aws sts get-caller-identity --query Account --output text)}"

# ---- 1. Transaction Search（账号 + 区域级，一次性）--------------------------------------
# 策略内联书写（而非用 heredoc 变量传入），是为了让 scripts/tests/validate_iam_policies.py 能解析
# 它。那个校验器按 `--policy-document '<字面量>'` 的形状抽取文档，用变量引用会让它抽到 "$VAR"
# 本身、解析失败——那正是它加强过的"文档在场却匹配不到"的情形。让策略真的被校验，比登记后豁免好。
POLICY_NAME="TransactionSearchXRayAccess"
if aws logs put-resource-policy --region "$REGION" --policy-name "$POLICY_NAME" --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{
    \"Sid\":\"TransactionSearchXRayAccess\",\"Effect\":\"Allow\",
    \"Principal\":{\"Service\":\"xray.amazonaws.com\"},\"Action\":\"logs:PutLogEvents\",
    \"Resource\":[
      \"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:aws/spans:*\",
      \"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/application-signals/data:*\"],
    \"Condition\":{
      \"ArnLike\":{\"aws:SourceArn\":\"arn:aws:xray:${REGION}:${ACCOUNT}:*\"},
      \"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT}\"}}}]}" >/dev/null 2>&1; then
  say ok "X-Ray → CloudWatch Logs 资源策略已就位（$POLICY_NAME）"
else
  say warn "资源策略写入失败——缺 logs:PutResourcePolicy？span 将无法投递。"
fi

DEST="$(aws xray get-trace-segment-destination --region "$REGION" \
  --query 'Destination' --output text 2>/dev/null || echo "")"
if [[ "$DEST" != "CloudWatchLogs" ]]; then
  aws xray update-trace-segment-destination --region "$REGION" \
    --destination CloudWatchLogs >/dev/null 2>&1 \
    || say warn "update-trace-segment-destination 失败（缺 xray 写权限？）"
fi
# 回读：这一步是异步的，PENDING 也算已受理，但要如实告知而不是宣布成功。
DEST_NOW="$(aws xray get-trace-segment-destination --region "$REGION" \
  --query 'Destination' --output text 2>/dev/null || echo "?")"
STATUS_NOW="$(aws xray get-trace-segment-destination --region "$REGION" \
  --query 'Status' --output text 2>/dev/null || echo "?")"
if [[ "$DEST_NOW" == "CloudWatchLogs" && "$STATUS_NOW" == "ACTIVE" ]]; then
  say ok "Transaction Search: CloudWatchLogs / ACTIVE"
elif [[ "$DEST_NOW" == "CloudWatchLogs" ]]; then
  say info "Transaction Search: CloudWatchLogs / $STATUS_NOW（生效需几分钟，可稍后重跑本 stage 复核）"
else
  say warn "Transaction Search 仍为 $DEST_NOW / $STATUS_NOW —— span 不会进 CloudWatch Logs。"
fi

# ---- 2/3. 每个 runtime 的 TRACES + APPLICATION_LOGS 投递 --------------------------------
# 账号级开关不足以让某个 agent 的 trace 和应用日志流动；投递要按 runtime 配。
configured=0; skipped=0
while read -r rt_name rt_arn; do
  [[ -n "$rt_name" ]] || continue
  case "$rt_name" in source_truth_agent*) ;; *) continue ;; esac
  for log_type in TRACES APPLICATION_LOGS; do
    src="${rt_name}-$(printf '%s' "$log_type" | tr 'A-Z_' 'a-z-')-source"
    if aws logs put-delivery-source --region "$REGION" --name "$src" \
         --log-type "$log_type" --resource-arn "$rt_arn" >/dev/null 2>&1; then
      : # 幂等：已存在时同样返回成功
    else
      say warn "put-delivery-source 失败: $src"
      skipped=$((skipped + 1)); continue
    fi

    if [[ "$log_type" == "TRACES" ]]; then
      dest_name="${rt_name}-traces-destination"
      aws logs put-delivery-destination --region "$REGION" --name "$dest_name" \
        --delivery-destination-type XRAY >/dev/null 2>&1 || true
    else
      dest_name="${rt_name}-logs-destination"
      lg="/aws/bedrock-agentcore/runtimes/$(printf '%s' "$rt_arn" | sed 's|.*/||')-DEFAULT"
      aws logs create-log-group --region "$REGION" --log-group-name "$lg" >/dev/null 2>&1 || true
      aws logs put-delivery-destination --region "$REGION" --name "$dest_name" \
        --delivery-destination-type CWL \
        --delivery-destination-configuration "destinationResourceArn=arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${lg}" \
        >/dev/null 2>&1 || true
    fi

    dest_arn="$(aws logs get-delivery-destination --region "$REGION" --name "$dest_name" \
      --query 'deliveryDestination.arn' --output text 2>/dev/null || echo "")"
    if [[ -z "$dest_arn" || "$dest_arn" == "None" ]]; then
      say warn "投递目标未就绪: $dest_name"; skipped=$((skipped + 1)); continue
    fi
    if aws logs create-delivery --region "$REGION" --delivery-source-name "$src" \
         --delivery-destination-arn "$dest_arn" >/dev/null 2>&1; then
      configured=$((configured + 1))
    else
      # 已存在即视为成功；其余情况才是真失败。
      if aws logs describe-deliveries --region "$REGION" \
           --query "deliveries[?deliverySourceName=='$src'] | length(@)" --output text 2>/dev/null \
           | grep -qE '^[1-9]'; then
        configured=$((configured + 1))
      else
        say warn "create-delivery 失败: $src → $dest_name"; skipped=$((skipped + 1))
      fi
    fi
  done
done < <(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
           --query 'agentRuntimes[].[agentRuntimeName,agentRuntimeArn]' --output text 2>/dev/null || true)

# 回读，而不是以调用成功为准。
live="$(aws logs describe-deliveries --region "$REGION" \
  --query 'deliveries | length(@)' --output text 2>/dev/null || echo 0)"
if [[ "$live" =~ ^[1-9] ]]; then
  say ok "runtime 投递已配置：$configured 条（账号内现存 deliveries: $live）"
else
  say warn "未查到任何 delivery —— 应用日志与 trace 都不会流动（configured=$configured skipped=$skipped）"
fi
