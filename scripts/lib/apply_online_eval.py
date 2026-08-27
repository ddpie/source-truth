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
import re
import sys

import boto3
from botocore.exceptions import ClientError

GROUND_TRUTH = {"assertions", "expected_response", "expected_tool_trajectory",
                "actual_tool_trajectory"}


def existing(client) -> dict[str, str]:
    out: dict[str, str] = {}
    token = None
    while True:
        kw = {"maxResults": 50}
        if token:
            kw["nextToken"] = token
        resp = client.list_online_evaluation_configs(**kw)
        items = (resp.get("onlineEvaluationConfigs")
                 or resp.get("onlineEvaluationConfigSummaries") or [])
        for c in items:
            name = c.get("onlineEvaluationConfigName") or c.get("name")
            cid = c.get("onlineEvaluationConfigId") or c.get("id")
            if name and cid:
                out[name] = cid
        token = resp.get("nextToken")
        if not token:
            return out


def uses_ground_truth(ctl, evaluator_id: str) -> bool:
    """自定义 LLM-as-judge 评估器的 instructions 里是否含 ground-truth 占位符。"""
    try:
        d = ctl.get_evaluator(evaluatorId=evaluator_id, includedData="ALL_DATA")
    except ClientError:
        return False
    cfg = (d.get("evaluatorConfig") or {}).get("llmAsAJudge") or {}
    instr = cfg.get("instructions") or ""
    return any("{" + p + "}" in instr for p in GROUND_TRUTH)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", required=True)
    ap.add_argument("--evaluator-ids", required=True,
                    help="key=id;key=id 形式，来自 deploy-config 的 EVALUATOR_IDS")
    ap.add_argument("--log-group", default="")
    ap.add_argument("--role-arn", required=True)
    ap.add_argument("--sampling", type=float, default=100.0)
    ap.add_argument("--enable", action="store_true")
    args = ap.parse_args()

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
        if not candidate:
            continue
        if not id_re.match(candidate):
            print(f"✗ 不是合法的 evaluator id，已跳过: {candidate!r}", file=sys.stderr)
            continue
        if candidate not in ids:
            ids.append(candidate)
    if not ids:
        print("没有可用的评估器 id", file=sys.stderr)
        return 1

    ctl = boto3.client("bedrock-agentcore-control", region_name=args.region)

    blocked = [i for i in ids if uses_ground_truth(ctl, i)]
    if blocked:
        print(f"✗ 这些评估器使用 ground-truth 占位符，不能用于实时评估: {blocked}", file=sys.stderr)
        print("  线上流量没有 ground truth；把它们留给按需评估。", file=sys.stderr)
        return 1

    # 数据源：runtime 的日志组 + service name。两者都必填，服务端据此发现会话。
    agentcore = boto3.client("bedrock-agentcore-control", region_name=args.region)
    runtimes = []
    token = None
    while True:
        kw = {"maxResults": 50}
        if token:
            kw["nextToken"] = token
        r = agentcore.list_agent_runtimes(**kw)
        runtimes.extend(r.get("agentRuntimes") or [])
        token = r.get("nextToken")
        if not token:
            break
    mine = [rt for rt in runtimes
            if (rt.get("agentRuntimeName") or "").startswith("source_truth_agent")]
    if not mine:
        print("✗ 该区域没有 source_truth_agent* runtime", file=sys.stderr)
        return 1

    have = existing(ctl)
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
        # 配置名只允许 [a-zA-Z][a-zA-Z0-9_]{0,47}：不能有连字符，且上限 48 字符。
        # runtime 名形如 source_truth_agent_daggerfall-Lmp8rZ7EH1，必须清洗并截断。
        safe = re.sub(r"[^a-zA-Z0-9_]", "_", name)[:40]
        cfg_name = f"st_online_{safe}"[:48]
        if cfg_name in have:
            print(f"ONLINE_CONFIG {have[cfg_name]}   {cfg_name} (已存在，复用；改动前须先禁用)")
            continue
        try:
            resp = ctl.create_online_evaluation_config(
                onlineEvaluationConfigName=cfg_name,
                description="Score source-truth answers for citation accuracy and evidence discipline",
                rule={"samplingConfig": {"samplingPercentage": float(args.sampling)}},
                dataSourceConfig={"cloudWatchLogs": {
                    "logGroupNames": [f"/aws/bedrock-agentcore/runtimes/{rid}-DEFAULT"],
                    "serviceNames": [f"{name}.DEFAULT"],
                }},
                evaluators=[{"evaluatorId": i} for i in ids],
                evaluationExecutionRoleArn=args.role_arn,
                enableOnCreate=bool(args.enable),
            )
        except ClientError as e:
            err = e.response.get("Error", {})
            print(f"✗ {cfg_name}: {err.get('Code')}: {(err.get('Message') or '')[:300]}",
                  file=sys.stderr)
            rc = 1
            continue
        state = "已启用" if args.enable else "已创建但未启用"
        print(f"ONLINE_CONFIG {resp.get('onlineEvaluationConfigId')}   {cfg_name} "
              f"({state}，采样 {args.sampling}%)")
        created += 1

    if created:
        print(f"  评估器: {ids}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
