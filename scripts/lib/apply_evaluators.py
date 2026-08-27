#!/usr/bin/env python3
"""按 evaluations/evaluators.json 创建（或复用）自定义评估器。

单独写成 Python 而不是塞进 shell：CreateEvaluator 的 llmAsAJudge 配置里有多行 instructions 和嵌套的
ratingScale，在 shell 里拼这种 JSON 是本仓库已经踩过的坑（引号、CRLF、$ 展开都会安静地毁掉载荷）。

幂等做法：先按名字在 ListEvaluators 里找。CreateEvaluator 没有「已存在则复用」的语义，重复调用会
造出一堆同名评估器，而每一个都是独立 id——那会让评估数据分散在多个 id 下，看起来像数据丢了。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import boto3
from botocore.exceptions import ClientError


def existing_by_name(client) -> dict[str, str]:
    out: dict[str, str] = {}
    token = None
    while True:
        kw = {"maxResults": 50}
        if token:
            kw["nextToken"] = token
        resp = client.list_evaluators(**kw)
        for e in resp.get("evaluatorSummaries") or resp.get("evaluators") or []:
            name = e.get("evaluatorName") or e.get("name")
            eid = e.get("evaluatorId") or e.get("id")
            if name and eid:
                out[name] = eid
        token = resp.get("nextToken")
        if not token:
            return out


def build_config(spec: dict, lambda_arn: str) -> dict:
    kind = spec["kind"]
    if kind == "codeBased":
        return {"codeBased": {"lambdaConfig": {
            "lambdaArn": lambda_arn,
            "lambdaTimeoutInSeconds": int(spec.get("lambdaTimeoutInSeconds", 120)),
        }}}
    if kind == "llmAsAJudge":
        instructions = spec["instructions"]
        if isinstance(instructions, list):
            instructions = "\n".join(instructions)
        scale = spec["ratingScale"]
        # 按 API 形状归一：numerical 需要 value+label+definition，categorical 只要 label+definition。
        if "numerical" in scale:
            rating = {"numerical": [
                {"value": float(x["value"]), "label": x["label"], "definition": x["definition"]}
                for x in scale["numerical"]]}
        else:
            rating = {"categorical": [
                {"label": x["label"], "definition": x["definition"]}
                for x in scale["categorical"]]}
        return {"llmAsAJudge": {
            "instructions": instructions,
            "ratingScale": rating,
            "modelConfig": {"bedrockEvaluatorModelConfig": {"modelId": spec["modelId"]}},
        }}
    raise ValueError(f"未知的评估器类型: {kind}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", required=True)
    ap.add_argument("--defs", required=True)
    ap.add_argument("--lambda-arn", required=True)
    args = ap.parse_args()

    defs = json.loads(pathlib.Path(args.defs).read_text(encoding="utf-8"))
    specs = [s for s in defs.get("evaluators", []) if not s.get("key", "").startswith("_")]
    if not specs:
        print("evaluators.json 里没有评估器定义", file=sys.stderr)
        return 1

    client = boto3.client("bedrock-agentcore-control", region_name=args.region)
    have = existing_by_name(client)
    rc = 0

    for spec in specs:
        name = spec["evaluatorName"]
        if name in have:
            print(f"EVALUATOR_ID {spec['key']} {have[name]}   (已存在，复用)")
            continue
        try:
            cfg = build_config(spec, args.lambda_arn)
        except (KeyError, ValueError) as e:
            print(f"✗ {name}: 定义不完整/不合法: {e}", file=sys.stderr)
            rc = 1
            continue
        try:
            resp = client.create_evaluator(
                evaluatorName=name,
                description=spec.get("description", "")[:200],
                level=spec["level"],
                evaluatorConfig=cfg,
            )
        except ClientError as e:
            err = e.response.get("Error", {})
            print(f"✗ {name}: {err.get('Code')}: {err.get('Message')}", file=sys.stderr)
            rc = 1
            continue
        print(f"EVALUATOR_ID {spec['key']} {resp['evaluatorId']}   (已创建 {spec['kind']})")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
