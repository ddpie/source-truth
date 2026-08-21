#!/usr/bin/env bash
# teardown 的 VPC 归属闸门。
#
# 为什么必须有这条：`--local` 部署跳过 provision_network.sh，VPC 是**宿主机自己原有的** VPC、
# 没有 source-truth-vpc 标签，但 provision_index_service.sh 仍把它的 id 写进 deploy-config。
# teardown 的发现顺序是 config 优先、标签只作兜底，且原先**不做任何归属校验**——于是第 5 段会按
# vpc-id 枚举并删掉那个 VPC 里的每一个非默认安全组、每一个子网、IGW、每一个非主路由表和非默认
# NACL。那段代码的注释还写着「The VPC is ours (source-truth-vpc tag)」，而这个前提在 --local 下
# 恰好不成立。
#
# 这属于**删掉工具从未创建过的基础设施**，比漏删一个计费资源严重得多，所以判据要双保险：
# 标签是权威判据（provision_network.sh 建 VPC 时打的），config 里的 VPC_OWNED=false 是 --local
# 路径给出的第二个显式信号。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/scripts/teardown.sh"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

# 抽出归属判定块，喂不同的输入直接驱动它（不碰 AWS）。
drive() {  # drive <tag-value> <VPC_OWNED>  -> 打印 VPC_IS_OURS
  local tag="$1" owned="$2"
  {
    printf 'say() { :; }\n'
    printf 'is_set() { [[ -n "${1:-}" && "$1" != None && "$1" != null ]]; }\n'
    printf 'Q() { printf %%s "%s"; }\n' "$tag"
    printf 'VPC=vpc-test123\n'
    [[ -n "$owned" ]] && printf 'VPC_OWNED=%s\n' "$owned"
    sed -n '/^VPC_IS_OURS=false$/,/^fi$/p' "$F"
    printf 'printf "%%s\\n" "$VPC_IS_OURS"\n'
  } | bash 2>/dev/null
}

# 1) 两机模式：标签是 source-truth-vpc，config 说 owned=true -> 可以清理
[[ "$(drive 'source-truth-vpc' 'true')" == "true" ]]
check "打了 source-truth-vpc 标签且 VPC_OWNED=true -> 认定为本工具所有" $?

# 2) 标签正确、config 没写 VPC_OWNED（老 deploy-config）-> 仍认定为所有（标签即权威）
[[ "$(drive 'source-truth-vpc' '')" == "true" ]]
check "标签正确但 config 无 VPC_OWNED（旧配置）-> 标签作为权威判据仍放行" $?

# 3) --local：宿主机自有 VPC，没有我们的标签 -> 必须拒绝
[[ "$(drive 'None' 'false')" == "false" ]]
check "无标签且 VPC_OWNED=false（--local 宿主机自有 VPC）-> 拒绝进入 VPC 清理段" $?

# 4) 没有标签、config 也没写 owned（config 只留了 VPC_ID）-> 必须拒绝，fail closed
[[ "$(drive 'None' '')" == "false" ]]
check "无标签且 config 未声明归属 -> fail closed，拒绝清理" $?

# 5) 最危险的组合：运维自己的 VPC 恰好带别的 Name 标签 -> 必须拒绝
[[ "$(drive 'my-production-vpc' '')" == "false" ]]
check "VPC 带其它 Name 标签（运维自己的网络）-> 拒绝清理" $?

# 6) VPC_OWNED=false 必须能覆盖标签（显式信号优先于推断）
[[ "$(drive 'source-truth-vpc' 'false')" == "false" ]]
check "VPC_OWNED=false 可以覆盖标签（显式声明优先）" $?

# 7) 第 5 段确实被这个闸门保护，而不是只在别处打印了一句警告
grep -q 'if is_set "\$VPC" && \[\[ "\$VPC_IS_OURS" == true \]\]; then' "$F"
check "第 5 段（子网/SG/IGW/路由表/VPC 删除）由 VPC_IS_OURS 把关" $?

# 8) 归属检测块本身不得被同一个闸门挡住（我第一版就把它自己挡住了，于是判定恒为 false）
_detect_ln="$(grep -n '^VPC_IS_OURS=false$' "$F" | head -1 | cut -d: -f1)"
_detect_if="$(sed -n "$((_detect_ln + 1))p" "$F")"
[[ "$_detect_if" == 'if is_set "$VPC"; then' ]]
check "归属检测块自身未被 VPC_IS_OURS 挡住（否则判定恒 false）" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
