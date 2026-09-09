#!/usr/bin/env python3
"""创建（或复用）实时评估配置。

单独写成 Python 的理由与 apply_evaluators.py 相同：嵌套 JSON 在 shell 里拼是本仓库踩过的坑。

一条硬约束值得在代码里挡住：使用 ground-truth 占位符（assertions / expected_response /
expected_tool_trajectory）的自定义评估器**不能**用于实时评估——线上流量没有 ground truth，服务端会在
创建时拒绝。本项目的两个评估器都不用它们，但把检查放在这里，是为了将来加第三个评估器时不必靠读文档
才发现这件事。
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import re
import sys
import time

import boto3
from botocore.exceptions import ClientError

GROUND_TRUTH = {"assertions", "expected_response", "expected_tool_trajectory",
                "actual_tool_trajectory"}

# 会话超时显式给出：实时评估要等会话被判定**结束**才评分，这个值直接决定「问完多久能看到分数」。
# 20 分钟略大于网关 15 分钟的空闲 TTL，避免一轮多问的会话被中途切断。
SESSION_TIMEOUT_MIN = 20
# 刚建好的执行角色对评估服务可能还不可见（IAM 最终一致）；只在角色是本次运行建的时才重试。
ROLE_RETRY_ATTEMPTS = 6
ROLE_RETRY_SLEEP_S = 10
_ROLE_ERR_RE = re.compile(r"(?:cannot|unable to|could not|not authorized to)\s+(?:be\s+)?assume"
                          r"|role.*(?:not assumable|not yet available)", re.I)


def rule_for(sampling: float) -> dict:
    return {"samplingConfig": {"samplingPercentage": float(sampling)},
            "sessionConfig": {"sessionTimeoutMinutes": SESSION_TIMEOUT_MIN}}


def data_source(runtime_name: str, runtime_id: str) -> dict:
    return {"cloudWatchLogs": {
        "logGroupNames": [f"/aws/bedrock-agentcore/runtimes/{runtime_id}-DEFAULT"],
        "serviceNames": [f"{runtime_name}.DEFAULT"],
    }}


def create_with_role_retry(ctl, kwargs: dict, *, role_just_created: bool) -> dict:
    for attempt in range(1, ROLE_RETRY_ATTEMPTS + 1):
        try:
            return ctl.create_online_evaluation_config(**kwargs)
        except ClientError as e:
            err = e.response.get("Error", {})
            blob = f"{err.get('Code')} {err.get('Message') or ''}"
            if (role_just_created and attempt < ROLE_RETRY_ATTEMPTS
                    and _ROLE_ERR_RE.search(blob)):
                print(f"  · 执行角色尚未传播，{ROLE_RETRY_SLEEP_S} s 后重试 "
                      f"({attempt}/{ROLE_RETRY_ATTEMPTS}) / role not yet assumable, retrying",
                      file=sys.stderr)
                time.sleep(ROLE_RETRY_SLEEP_S)
                continue
            raise
    raise AssertionError("unreachable")


def config_name(runtime_name: str, runtime_id: str) -> str:
    """配置名只允许 [a-zA-Z][a-zA-Z0-9_]{0,47}：不能有连字符，上限 48 字符。

    runtime 名形如 source_truth_agent_<pid>-<10 位随机后缀>，清洗后截断；截断会吃掉后缀，
    两个长 pid 只要前 31 字符相同就撞名，所以再拼一段 runtime id 的稳定哈希（6 位）区分。
    """
    safe = re.sub(r"[^a-zA-Z0-9_]", "_", runtime_name)[:31]
    digest = hashlib.sha1(runtime_id.encode("utf-8")).hexdigest()[:6]
    return f"st_online_{safe}_{digest}"


def legacy_config_name(runtime_name: str) -> str:
    """第一版的命名（无哈希）；已部署的配置沿用旧名，避免重跑时再建一份。"""
    safe = re.sub(r"[^a-zA-Z0-9_]", "_", runtime_name)[:40]
    return f"st_online_{safe}"[:48]


def existing(client) -> tuple[dict[str, str], dict[str, str]]:
    """返回 (名字→id, 名字→executionStatus)。

    状态必须一起取回：--enable 对已存在的配置只能通过 UpdateOnlineEvaluationConfig 生效，
    而判断要不要调用它需要知道当前状态，否则每次运行都会无谓地改一遍。
    """
    ids: dict[str, str] = {}
    states: dict[str, str] = {}
    for resp in client.get_paginator("list_online_evaluation_configs").paginate():
        items = (resp.get("onlineEvaluationConfigs")
                 or resp.get("onlineEvaluationConfigSummaries") or [])
        for c in items:
            name = c.get("onlineEvaluationConfigName") or c.get("name")
            cid = c.get("onlineEvaluationConfigId") or c.get("id")
            if name and cid:
                ids[name] = cid
                states[name] = c.get("executionStatus") or ""
    return ids, states


def uses_ground_truth(ctl, evaluator_id: str) -> bool:
    """自定义 LLM-as-judge 评估器的 instructions 里是否含 ground-truth 占位符。"""
    d = ctl.get_evaluator(evaluatorId=evaluator_id, includedData="ALL_DATA")
    cfg = (d.get("evaluatorConfig") or {}).get("llmAsAJudge") or {}
    instr = cfg.get("instructions") or ""
    return any("{" + p + "}" in instr for p in GROUND_TRUTH)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", required=True)
    ap.add_argument("--evaluator-ids", required=True,
                    help="key=id;key=id 形式，来自 deploy-config 的 EVALUATOR_IDS")
    ap.add_argument("--role-arn", required=True)
    ap.add_argument("--sampling", type=float, default=None,
                    help="新配置默认 100；省略时保留已有配置的采样率")
    status = ap.add_mutually_exclusive_group()
    status.add_argument("--enable", dest="enable", action="store_true", default=None)
    status.add_argument("--disable", dest="enable", action="store_false")
    ap.add_argument("--role-just-created", action="store_true",
                    help="执行角色是本次运行刚建的：对 assume/授权类错误做有限次重试")
    args = ap.parse_args()
    if args.sampling is not None and not 0 <= args.sampling <= 100:
        ap.error("--sampling must be between 0 and 100")

    # EVALUATOR_IDS 形如 "key=Id-XXXXXXXXXX;key2=Id2-YYYYYYYYYY"。第一版按 ; 和 , 一起切分并
    # 无条件取 = 右侧，于是空段和不含 = 的段都成了「id」，服务端报的是一串看不懂的正则约束错误。
    # id 的真实格式（取自被拒时服务端给出的模式）：Builtin.X | ThirdParty.A.B | <name>-<10位>。
    id_re = re.compile(r"^(Builtin\.[a-zA-Z0-9._-]+"
                       r"|ThirdParty\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+"
                       r"|[a-zA-Z][a-zA-Z0-9\-_]{0,99}-[a-zA-Z0-9]{10})$")
    ids: list[str] = []
    for part in args.evaluator_ids.replace(",", ";").split(";"):
        part = part.strip()
        if not part:
            continue
        candidate = part.split("=", 1)[1].strip() if "=" in part else part
        if not id_re.fullmatch(candidate):
            print(f"不是合法的 evaluator id，未修改配置: {candidate!r}", file=sys.stderr)
            return 1
        if candidate not in ids:
            ids.append(candidate)
    if not ids:
        print("没有可用的评估器 id", file=sys.stderr)
        return 1

    ctl = boto3.client("bedrock-agentcore-control", region_name=args.region)

    try:
        blocked = [i for i in ids if uses_ground_truth(ctl, i)]
    except ClientError as e:
        print(f"无法读取评估器定义，未修改配置: {e.response.get('Error', {}).get('Code')}",
              file=sys.stderr)
        return 1
    if blocked:
        print(f"✗ 这些评估器使用 ground-truth 占位符，不能用于实时评估: {blocked}", file=sys.stderr)
        print("  线上流量没有 ground truth；把它们留给按需评估。", file=sys.stderr)
        return 1

    # 数据源：runtime 的日志组 + service name。两者都必填，服务端据此发现会话。
    runtimes = []
    for page in ctl.get_paginator("list_agent_runtimes").paginate():
        runtimes.extend(page.get("agentRuntimes") or [])
    mine = [rt for rt in runtimes
            if (rt.get("agentRuntimeName") or "") == "source_truth_agent"
            or (rt.get("agentRuntimeName") or "").startswith("source_truth_agent_")]
    if not mine:
        print("✗ 该区域没有 source_truth_agent* runtime", file=sys.stderr)
        return 1

    have, states = existing(ctl)
    rc = 0
    created = 0

    # serviceNames 上限是 **1**，logGroupNames 上限是 5 —— 也就是说一个实时评估配置只能盯**一个**
    # runtime。多项目部署因此需要每个项目一份配置，而不是一份配置列出全部。这不是可以绕开的写法问题，
    # 是服务端的约束；第一版把六个 runtime 塞进一份配置，直接被拒。
    for rt in mine:
        rid = rt.get("agentRuntimeId") or ""
        name = rt.get("agentRuntimeName") or ""
        if not rid or not name:
            continue
        cfg_name = config_name(name, rid)
        legacy = legacy_config_name(name)
        desired_source = data_source(name, rid)
        details = None
        try:
            if cfg_name not in have and legacy in have:
                old = ctl.get_online_evaluation_config(onlineEvaluationConfigId=have[legacy])
                # A truncated legacy name can belong to a different runtime.
                # Adopt only when its actual data source matches this runtime.
                if old.get("dataSourceConfig") == desired_source:
                    cfg_name, details = legacy, old
            if cfg_name in have and details is None:
                details = ctl.get_online_evaluation_config(onlineEvaluationConfigId=have[cfg_name])
        except ClientError as e:
            print(f"✗ {cfg_name}: 无法读取已有配置，未修改: "
                  f"{e.response.get('Error', {}).get('Code')}", file=sys.stderr)
            rc = 1
            continue
        if cfg_name in have:
            cid = have[cfg_name]
            if details.get("dataSourceConfig") != desired_source:
                print(f"✗ {cfg_name}: 已有配置属于不同数据源，未修改", file=sys.stderr)
                rc = 1
                continue
            # 已存在的配置必须**收敛**到本次参数，不能只报「复用」。enableOnCreate 只在创建时起作用，
            # 所以对已存在的配置，--enable 若不落到 UpdateOnlineEvaluationConfig 上就完全没有效果——
            # 脚本会打印成功而实时评估依然是关的，正是「报告未曾达成的成功」。采样率和评估器列表同理。
            current = details.get("executionStatus", states.get(cfg_name, ""))
            rule = details.get("rule") or {}
            cur_rate = (rule.get("samplingConfig") or {}).get("samplingPercentage")
            if current not in ("ENABLED", "DISABLED") or cur_rate is None:
                print(f"{cfg_name}: 已有配置缺少执行状态或采样率，未修改", file=sys.stderr)
                rc = 1
                continue
            want = current if args.enable is None else ("ENABLED" if args.enable else "DISABLED")
            sampling = cur_rate if args.sampling is None else args.sampling
            desired_rule = copy.deepcopy(rule)
            desired_rule.setdefault("samplingConfig", {})["samplingPercentage"] = float(sampling)
            desired_rule.setdefault("sessionConfig", {}).setdefault("sessionTimeoutMinutes", SESSION_TIMEOUT_MIN)
            cur_evs = sorted(e["evaluatorId"] for e in details.get("evaluators", []) if e.get("evaluatorId"))
            drift = []
            if current != want:
                drift.append(f"executionStatus {current or '?'}→{want}")
            if cur_rate != sampling:
                drift.append(f"采样率 {cur_rate}%→{sampling:g}%")
            if cur_evs != sorted(ids):
                drift.append(f"评估器 {cur_evs}→{sorted(ids)}")
            if (rule.get("sessionConfig") or {}).get("sessionTimeoutMinutes") is None:
                drift.append(f"会话超时→{SESSION_TIMEOUT_MIN} 分钟")
            if details.get("evaluationExecutionRoleArn") != args.role_arn:
                drift.append("执行角色变更")
            if not drift:
                print(f"ONLINE_CONFIG {cid}   {cfg_name} (已存在，executionStatus={current}，"
                      f"采样 {sampling:g}%)")
                continue
            try:
                ctl.update_online_evaluation_config(
                    onlineEvaluationConfigId=cid,
                    executionStatus=want,
                    rule=desired_rule,
                    evaluators=[{"evaluatorId": i} for i in ids],
                    evaluationExecutionRoleArn=args.role_arn,
                )
            except ClientError as e:
                err = e.response.get("Error", {})
                print(f"✗ {cfg_name}: 未修改（已存在）：{'，'.join(drift)}；更新失败 "
                      f"{err.get('Code')}: {(err.get('Message') or '')[:200]}", file=sys.stderr)
                rc = 1
                continue
            print(f"ONLINE_CONFIG {cid}   {cfg_name} (已更新：{'，'.join(drift)})")
            continue
        sampling = 100.0 if args.sampling is None else args.sampling
        try:
            resp = create_with_role_retry(ctl, dict(
                onlineEvaluationConfigName=cfg_name,
                description="Score source-truth answers for citation accuracy and evidence discipline",
                rule=rule_for(sampling),
                dataSourceConfig=desired_source,
                evaluators=[{"evaluatorId": i} for i in ids],
                evaluationExecutionRoleArn=args.role_arn,
                enableOnCreate=bool(args.enable),
            ), role_just_created=args.role_just_created)
        except ClientError as e:
            err = e.response.get("Error", {})
            print(f"✗ {cfg_name}: {err.get('Code')}: {(err.get('Message') or '')[:300]}",
                  file=sys.stderr)
            rc = 1
            continue
        state = "已启用" if args.enable else "已创建但未启用"
        print(f"ONLINE_CONFIG {resp.get('onlineEvaluationConfigId')}   {cfg_name} "
              f"({state}，采样 {sampling:g}%)")
        created += 1

    if created:
        print(f"  评估器: {ids}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
