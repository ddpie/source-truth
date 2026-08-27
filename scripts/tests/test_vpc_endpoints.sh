#!/usr/bin/env bash
# VPC 端点：那些「创建成功但不载流量」的形态。
#
# 为什么这个测试值得写。加端点的目的只有一个：让拉镜像不出 VPC。但端点有好几种既存在、既计费、
# 又完全不在流量路径上的状态，而且没有任何一种会报错：
#   1. 接口端点关掉 private DNS —— 拉镜像用的是 ECR 的**公网域名**，端点能截住它完全依赖 VPC
#      resolver 把那个域名解析成端点私有 IP。DNS 一关，端点按小时计费，流量照旧走 NAT。
#   2. VPC 没开 enableDnsSupport / enableDnsHostnames —— 同上，private DNS 无从生效。
#   3. S3 网关端点没挂到私有路由表 —— 网关端点就是一条路由，不挂路由表就什么都不做。而 ECR 的
#      镜像层是 S3 对象，缺了它每次拉取的绝大部分字节仍然出 VPC，加端点这件事等于没做。
#   4. 端点处于 failed 状态但带着我们的 tag —— 只查存在性会永久认领它，部署报成功。
# 这四种都不是「代码写错了」，是「代码写对了但少收敛一步」，所以断言的是收敛动作是否存在。
#
# 另外两条是账单：接口端点按小时计费，teardown 必须删它，而且必须在删安全组/子网**之前**删——
# 端点在私有子网里持有 ENI，顺序错了 delete-security-group 会 DependencyViolation 失败。顺序是
# 两行代码之间的关系，正是静态检查唯一真正擅长的东西。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
N="$ROOT/scripts/lib/provision_network.sh"
T="$ROOT/scripts/teardown.sh"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

# --- 三个端点都得有，且类型正确 ---
grep -q 'ensure_endpoint ecr-api ecr\.api Interface' "$N"
check "创建 ecr.api 接口端点（认证与 manifest 调用）" $?
grep -q 'ensure_endpoint ecr-dkr ecr\.dkr Interface' "$N"
check "创建 ecr.dkr 接口端点（registry 协议）" $?
grep -q 'ensure_endpoint s3 s3 Gateway' "$N"
check "创建 s3 网关端点（镜像层是 S3 对象，缺了它字节仍然出 VPC）" $?

# --- 1. private DNS：创建时要开，已存在但被关掉时要收敛 ---
grep -q -- '--private-dns-enabled' "$N"
check "接口端点创建时带 --private-dns-enabled" $?
grep -q 'modify-vpc-endpoint --vpc-endpoint-id "\$id" --private-dns-enabled' "$N"
check "已存在端点若 private DNS 是关的，收敛开启（否则只计费不截流量）" $?

# --- 2. VPC 的两个 DNS 属性 ---
for attr in enableDnsSupport enableDnsHostnames; do
  grep -q "$attr" "$N"
  check "检查/开启 VPC 属性 $attr（private DNS 的前置条件）" $?
done
grep -q 'modify-vpc-attribute' "$N"
check "DNS 属性缺失时实际去开，而不是只警告" $?

# --- 3. S3 网关端点必须挂在私有路由表上 ---
grep -q 'route-table-ids "\$PRIV_RT"' "$N"
check "网关端点创建时挂到私有路由表" $?
grep -q -- '--add-route-table-ids "\$PRIV_RT"' "$N"
check "已存在网关端点若未挂私有路由表，收敛挂上" $?
# PRIV_RT 必须是真查出来的，不能是空串——空串会让 create 报错或挂错表
grep -q 'PRIV_RT="\$(by_name route-tables source-truth-private-rt' "$N"
check "PRIV_RT 由 by_name 真实查询得到" $?

# --- 4. failed 状态不得被当成「已存在」认领 ---
sed -n '/^  ensure_endpoint() {/,/^  }/p' "$N" | grep -q 'State.*failed\|"failed"'
check "ensure_endpoint 识别 failed 状态并重建（只查存在性会永久认领它）" $?

# --- 账单：teardown 必须删端点 ---
grep -q 'delete-vpc-endpoints' "$T"
check "teardown 删除 VPC 端点（接口端点按小时计费）" $?
# 枚举，不是 [0]。这个仓库已经因为 index-[0] 漏删账单资源被修过四次。
grep -q 'VpcEndpoints\[0\]' "$T" && _bad=1 || _bad=0
[[ "$_bad" -eq 0 ]]
check "teardown 不用 VpcEndpoints[0] 取单个（[0] 会漏掉其余端点）" $?
grep -q 'for _vpce in \$ALL_VPCE' "$T"
check "teardown 遍历所有发现到的端点" $?
# tag 扫描必须在 VPC 归属判断之外——端点带我们的 tag 就是我们的，VPC 是不是我们的无关
_tag_ln="$(grep -n 'TAGGED_VPCE=' "$T" | head -1 | cut -d: -f1)"
_own_ln="$(grep -n 'VPC_VPCE=""' "$T" | head -1 | cut -d: -f1)"
[[ -n "$_tag_ln" && -n "$_own_ln" && "$_tag_ln" -lt "$_own_ln" ]]
check "按 tag 删除不受 VPC 归属限制（否则借用的 VPC 里会留下计费资源）" $?

# --- 账单：顺序。端点必须先删，否则 SG/子网删除失败 ---
#
# 只匹配真正的调用行 `del "..." Q delete-...`，不匹配注释。第一版这里写的是
# `grep -n 'delete-security-group'`，结果命中的是两条**讲这件事的注释**（其中一条还是本次为解释
# 顺序而新写的），行号分别落在真正调用之前，于是基线就红了两条——同一个坑本轮已经踩过一次：
# 文本守卫分不清代码和讲代码的散文。
_call_ln() { grep -nE "^ *del \"$1[^\"]*\" Q delete-" "$T" | head -1 | cut -d: -f1; }
_vpce_ln="$(_call_ln 'vpc endpoint')"
_sg_ln="$(_call_ln 'security group')"
_sn_ln="$(_call_ln 'subnet')"
[[ -n "$_vpce_ln" && -n "$_sg_ln" && -n "$_sn_ln" ]]
check "能定位三个删除调用的真实行号（端点=$_vpce_ln SG=$_sg_ln 子网=$_sn_ln）" $?
[[ -n "$_vpce_ln" && -n "$_sg_ln" && "$_vpce_ln" -lt "$_sg_ln" ]]
check "删端点($_vpce_ln) 早于删安全组($_sg_ln)（端点 ENI 会 pin 住 SG）" $?
[[ -n "$_vpce_ln" && -n "$_sn_ln" && "$_vpce_ln" -lt "$_sn_ln" ]]
check "删端点($_vpce_ln) 早于删子网($_sn_ln)（端点 ENI 在私有子网里）" $?
grep -q 'wait_gone "vpc endpoints"' "$T"
check "删完端点后等 ENI 真正释放，而不是直接往下删" $?

# --- 端点安全组：只开 443，且只对 VPC ---
sed -n '/create-security-group --group-name source-truth-vpce/,/^  fi$/p' "$N" | grep -q 'source-truth-vpce'
check "端点使用独立安全组，不复用 index-svc（后者是给 bridge 端口自引用的）" $?
grep -q 'authorize-security-group-ingress --group-id "\$VPCE_SG" --protocol tcp \\' "$N" \
  && grep -q -- '--port 443 --cidr "\$VPC_CIDR"' "$N"
check "端点安全组只放行 VPC CIDR 的 443" $?
grep -q 'InvalidPermission.Duplicate' "$N"
check "重复授权按成功处理（幂等），其他错误则失败退出" $?

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]] || exit 1
