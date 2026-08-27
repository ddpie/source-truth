#!/usr/bin/env bash
# NACL 入站规则的端口区间关系。
#
# 为什么这条值得写，而大多数静态 grep 不值得：这里发生过的回归是**同一个文件里两个常量之间的数值
# 关系**，而不是某段代码存在与否。当时 0.0.0.0/0 的临时端口区间写的是 1024-65535，它**完整包含**了
# 规则 100 的 8080-8099——于是那条「只允许 VPC CIDR 访问 bridge 端口」的限制变成死规则，bridge
# 端口实际上对 0.0.0.0/0 开放。而且失败是静默的：NACL 正常生效、安全组看起来依然收紧，部署日志里
# 什么都不会显示。
#
# 另外 1024-65535 是任何人写「临时回程端口」时都会自然写出的值，所以这个坑会被重新踩。
# 除了包含关系，还要断言**完全不重叠**：像 8090-60999 这种部分重叠会放开一半 bridge 端口，
# 只查包含关系是查不出来的。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$ROOT/scripts/lib/provision_network.sh"
_run=0; _fail=0
check() { _run=$((_run+1)); if [[ "$2" -eq 0 ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; _fail=$((_fail+1)); fi; }

# 从源码文本里取出规则号 -> (from,to,cidr)，不执行任何 AWS 调用。
rule_field() { # rule_field <rule-number> <from|to|cidr>
  local n="$1" what="$2" line
  line="$(grep -E "^nacl_rule ingress $n " "$F" | head -1)"
  case "$what" in
    from) printf '%s' "$line" | grep -oE 'From=[0-9]+' | head -1 | cut -d= -f2 ;;
    to)   printf '%s' "$line" | grep -oE 'To=[0-9]+'   | head -1 | cut -d= -f2 ;;
    cidr) printf '%s' "$line" | grep -oE -- '--cidr-block "[^"]+"' | head -1 | sed 's/.*"\(.*\)"/\1/' ;;
  esac
}

B_FROM="$(rule_field 100 from)"; B_TO="$(rule_field 100 to)"; B_CIDR="$(rule_field 100 cidr)"
E_FROM="$(rule_field 120 from)"; E_TO="$(rule_field 120 to)"; E_CIDR="$(rule_field 120 cidr)"
U_FROM="$(rule_field 130 from)"; U_TO="$(rule_field 130 to)"; U_CIDR="$(rule_field 130 cidr)"

[[ -n "$B_FROM" && -n "$B_TO" && -n "$E_FROM" && -n "$E_TO" ]]
check "能从源码解析出 bridge(100) 与临时端口(120) 两个区间" $?

# bridge 端口必须只对 VPC CIDR 开放，临时端口才是 0.0.0.0/0
[[ "$B_CIDR" == '$VPC_CIDR' ]]; check "规则 100（bridge 端口）的 cidr 是 \$VPC_CIDR，不是 0.0.0.0/0（实际 $B_CIDR）" $?
[[ "$E_CIDR" == "0.0.0.0/0" ]]; check "规则 120（TCP 临时端口）的 cidr 是 0.0.0.0/0（实际 $E_CIDR）" $?
[[ "$U_CIDR" == "0.0.0.0/0" ]]; check "规则 130（UDP 临时端口）的 cidr 是 0.0.0.0/0（实际 $U_CIDR）" $?

# 核心：0.0.0.0/0 的区间不得包含 bridge 区间 —— 这正是当年那次回归。
contains=0
(( E_FROM <= B_FROM && B_TO <= E_TO )) && contains=1
[[ "$contains" -eq 0 ]]
check "0.0.0.0/0 临时端口区间($E_FROM-$E_TO) 不包含 bridge 区间($B_FROM-$B_TO)" $?

# 更强：完全不重叠。部分重叠会放开一部分 bridge 端口，只查包含查不出来。
overlap=0
(( E_FROM <= B_TO && B_FROM <= E_TO )) && overlap=1
[[ "$overlap" -eq 0 ]]
check "两个区间完全不重叠（部分重叠会放开一部分 bridge 端口）" $?

# UDP 那条与 TCP 同区间，同样不得碰到 bridge 端口。
u_overlap=0
(( U_FROM <= B_TO && B_FROM <= U_TO )) && u_overlap=1
[[ "$u_overlap" -eq 0 ]]; check "UDP 临时端口区间($U_FROM-$U_TO) 也不重叠 bridge 区间" $?

# 临时端口区间应落在 Linux 的实际 ephemeral 范围内（net.ipv4.ip_local_port_range 默认值），
# 否则回程流量会被挡；这条防的是"为了避开 bridge 端口而把区间改得过窄"。
(( E_FROM >= 32768 && E_TO >= 60999 ))
check "临时端口区间覆盖 Linux 默认 ephemeral 范围（32768-60999 起）" $?

# 上界必须到 65535，不能只到 Linux 的 60999。
#
# 这个子网里不止有 Linux 主机：AgentCore runtime 的 ENI 也在这里，而它是 AWS 托管的 microVM，
# 用的源端口高于 60999。上界曾经就是 60999，后果是它拉 ECR 镜像时出站 SYN 被 ACCEPT、返回流量
# 被 REJECT，`docker pull` 超时、容器起不来，每次调用都返回「HTTP 424 Runtime health check
# failed」。本 VPC 自己的 flow log 上是这样一对记录：
#   10.1.1.158:64868 -> 52.193.58.182:443  ACCEPT   （请求出去了）
#   52.193.58.182:443 -> 10.1.1.158:64868  REJECT   （答案被丢了）
# 而同一子网的 EC2 主机全程正常，因为 Linux 只用 32768-60999——这正是它看起来像应用故障的原因：
# /health 绿、bridge 绿、网关长连接 connected，只有回答失败。
#
# 而且它是概率性的：源端口有相当比例会落在旧区间内，所以一次部署可能通过、下一次在什么都没改的
# 情况下失败。对一个要发布的 sample，这种间歇性错误比稳定失败更贵。
(( E_TO >= 65535 && U_TO >= 65535 ))
check "临时端口区间上界到 65535（AgentCore microVM 源端口高于 60999）" $?

# nacl_rule 的收敛方向：create 失败要回退到 replace，且不得出现 delete-then-create。
sed -n '/^nacl_rule() {/,/^}/p' "$F" | grep -q 'replace-network-acl-entry'
check "nacl_rule 在 create 失败时回退 replace-network-acl-entry" $?
create_ln="$(grep -n 'create-network-acl-entry' "$F" | head -1 | cut -d: -f1)"
delete_ln="$(grep -n 'delete-network-acl-entry' "$F" | head -1 | cut -d: -f1)"
if [[ -n "$delete_ln" ]]; then
  [[ "$delete_ln" -gt "$create_ln" ]]
  check "删除陈旧条目发生在创建之后（delete-then-create 曾造成 deny-all 窗口）" $?
fi

echo "  ran=$_run failed=$_fail"
[[ "$_fail" -eq 0 ]]
