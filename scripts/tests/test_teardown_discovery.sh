#!/usr/bin/env bash
# teardown 资源发现测试：断言"枚举"而不是"取第一个"。
#
# 为什么需要这一套：test_teardown_accounting.sh 验的是 del/wait_gone 的计数与退出码，
# test_teardown_vpc_ownership.sh 验的是 VPC 归属闸门。两者都不看发现查询的形状，所以
# `NatGateways[0]` 这一类退化可以在全绿的构建下重新长回来——而它每次的代价是一个
# 静默计费的 NAT（约 $33/月）或 EIP（约 $3.65/月），操作者只会看到 "teardown complete"。
#
# 这类断言故意做在文本层：查询字符串就是语义本身，`[0]` 与 `[]` 的区别无法通过
# 运行时打桩观察到（两者都会"成功"，只是少删了资源）。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
TD="scripts/teardown.sh"
ran=0; failed=0

check() {  # check <描述> <条件命令...>
  local desc="$1"; shift
  ran=$((ran + 1))
  if "$@"; then
    echo "  ok   $desc"
  else
    echo "  FAIL $desc"
    failed=$((failed + 1))
  fi
}

# 只看真正的代码行：注释里可以合法地讨论 `NatGateways[0]` 这个历史缺陷。
#
# 去注释后的内容先落成一份临时文件，再对文件做匹配——不要用 `code_only | grep -q`。
# 那种写法里 `-q` 一命中就退出，上游 grep 收到 SIGPIPE 返回 141，在 pipefail 下整条
# 管线判为失败，于是断言的结果取决于匹配出现在文件的第几行：靠前的匹配失败、靠后的
# 通过。一个按行号决定通过与否的断言比没有断言更糟，这套件第一版就是这么错的。
CODE="$(mktemp)"
trap 'rm -f "$CODE"' EXIT
grep -vE '^\s*#' "$TD" > "$CODE"

has_code() { grep -qF "$1" "$CODE"; }
no_code()  { ! grep -qF "$1" "$CODE"; }
has_re()   { grep -qE "$1" "$CODE"; }

echo "== teardown 资源发现：枚举而非取首个 =="

# --- NAT / EIP：本套件的核心。这三处 [0] 每一处都是一笔静默的月度账单。 ---
check "NAT 发现使用 NatGateways[] 枚举" has_code 'NatGateways[].NatGatewayId'
check "NAT 发现不再退化为 NatGateways[0]" no_code 'NatGateways[0].NatGatewayId'
check "NAT 的 EIP 收集使用 NatGatewayAddresses[] 枚举" has_code 'NatGatewayAddresses[].AllocationId'
check "不再只取 NAT 的第一个地址" no_code 'NatGatewayAddresses[0].AllocationId'
check "按标签兜底的 EIP 不再只取 Addresses[0]" no_code "Addresses[0].AllocationId"
check "EIP 兜底带 AssociationId==null 过滤（不释放仍在使用的地址）" \
  has_code 'AssociationId==`null`'

# 配置短路：即使 [0] 修好了，`is_set $NAT ||` 也会让标签扫描永不执行。
check "NAT 发现与配置值取并集，而不是被配置值短路" has_re '^ALL_NATS=.*NAT_GATEWAY'

# --- 计划行必须在确认提示之前暴露全部待删 NAT ---
check "计划行打印 ALL_NATS（第二个 NAT 在确认前就可见）" has_re 'say info .*NAT gateway.*ALL_NATS'

# --- EC2：既有的正确实现，一并钉住防止回退 ---
check "EC2 发现使用 Reservations[].Instances[] 枚举" has_code 'Reservations[].Instances[].InstanceId'

echo
echo "== 跨区守卫：失败时必须关闭而不是放行 =="
# describe-regions 被拒时，旧代码把 AccessDenied 折叠成空列表，守卫静默失效。
check "区域枚举不再用 2>/dev/null 吞掉错误" \
  no_code "describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null"
check "探测不可判定时以非零退出（fail closed）" has_code 'REFUSING --include-shared'
check "区分'查不到'与'没有'（存在 UNKNOWN 累加）" has_code 'UNKNOWN="$UNKNOWN $r"'
check "守卫也检查 AgentCore 运行时（PUBLIC 模式区域没有 EC2 实例）" has_code 'list-agent-runtimes'

echo
echo "== 静默泄漏：既不删除也不申报的资源 =="
check "flow-log 对象在默认路径被清理" has_code 'vpc-flow-logs/'
check "AgentCore 运行时日志组被删除" has_code 'delete-log-group'
check "构件桶名在配置缺失时被推导" has_code 'source-truth-repo-${ACCOUNT}'
check "桶名无法解析时计入未完成并告知操作者" has_code 'artifact bucket name unresolved'
check "Route53 按本区域记录收敛（VPC 删除后关联已不存在）" \
  has_code 'index.${REGION}.source-truth.internal.'

echo
echo "  ran=$ran failed=$failed"
[[ $failed -eq 0 ]] || exit 1
