#!/usr/bin/env python3
"""按 evaluations/evaluators.json 创建（或复用）自定义评估器。

单独写成 Python 而不是塞进 shell：CreateEvaluator 的 llmAsAJudge 配置里有多行 instructions 和嵌套的
ratingScale，在 shell 里拼这种 JSON 是本仓库已经踩过的坑（引号、CRLF、$ 展开都会安静地毁掉载荷）。

幂等做法：先按名字在 ListEvaluators 里找。CreateEvaluator 没有「已存在则复用」的语义，重复调用会
造出一堆同名评估器，而每一个都是独立 id——那会让评估数据分散在多个 id 下，看起来像数据丢了。

评委模型 id 按区域解析：evaluators.json 里只写不带地理前缀的基名（anthropic.claude-haiku-...），
这里在**创建任何东西之前**用 ListInferenceProfiles 选出该区域真实存在的推理档（规则同
scripts/lib/resolve_model.sh：地理档 us./eu./jp./au. 优先，其次 global.）。第一版把 jp. 前缀写死在
定义里，换个区域第二个评估器就被拒，而第一个已经建好——半套资源、EVALUATOR_IDS 也没写回。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

import boto3
from botocore.exceptions import ClientError


def existing_by_name(client, wanted_names: set[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for resp in client.get_paginator("list_evaluators").paginate():
        for e in resp.get("evaluatorSummaries") or resp.get("evaluators") or []:
            name = e.get("evaluatorName") or e.get("name")
            eid = e.get("evaluatorId") or e.get("id")
            # Other applications may have duplicate names in this account. Only
            # ambiguity in this deployment's requested identities blocks reuse.
            if name in wanted_names and eid:
                if name in out and out[name] != eid:
                    raise ValueError(f"多个已有评估器同名 {name!r}，无法安全选择")
                out[name] = eid
    return out


# LLM-as-judge 的 instructions 必须含至少一个占位符，服务端会把它替换成真实的 trace 信息。
# 每个评估级别只接受固定的一组，缺失时 CreateEvaluator 直接拒绝：
#   ValidationException: Instructions must contain at least one of the allowed placeholders ...
# 在本地先查，是因为这个错误只在真正调 API 时才出现，而那时可能已经创建了另一半资源。
_PLACEHOLDERS: dict[str, set[str]] = {
    "SESSION": {"context", "available_tools", "actual_tool_trajectory",
                "expected_tool_trajectory", "assertions"},
    "TRACE": {"context", "assistant_turn", "expected_response"},
    "TOOL_CALL": {"context", "available_tools", "tool_turn",
                  "invoked_skill", "skill_content", "available_skills", "user_message"},
}


def check_placeholders(spec: dict, instructions: str) -> str | None:
    """返回错误说明，合规时返回 None。"""
    level = spec.get("level", "")
    allowed = _PLACEHOLDERS.get(level)
    if allowed is None:
        return f"未知的 level: {level!r}"
    used = set(re.findall(r"\{([a-z_]+)\}", instructions))
    if not used & allowed:
        return (f"{level} 级的 instructions 必须含至少一个占位符 "
                f"{sorted(allowed)}，当前用到的是 {sorted(used) or '（无）'}")
    unknown = used - allowed
    if unknown:
        # 未知占位符不会被替换，会原样送给评委模型，看起来像提示词写坏了。
        return f"instructions 里有 {level} 级不支持的占位符 {sorted(unknown)}，它们不会被替换"
    return None


# ---- 评委模型的区域解析（纯函数部分不做 I/O，便于单测） ----
# 只认已知的推理档前缀：任意 2–6 个字母会把 amazon. / meta. 这类厂商名也当成地理前缀剥掉。
_GEO_PREFIX_RE = re.compile(r"^(global|us|eu|jp|au|apac|us-gov)\.")


def judge_model_basename(model_id: str) -> str:
    """去掉地理/global 前缀：jp.anthropic.claude-haiku-4-5-... -> anthropic.claude-haiku-4-5-..."""
    return _GEO_PREFIX_RE.sub("", model_id.strip(), count=1)


def rank_judge_profiles(basename: str, profile_ids: list[str]) -> str | None:
    """在候选推理档里选与 basename 同一模型的最佳档：地理档优先于 global.，都没有返回 None。"""
    geo = glob = None
    for pid in profile_ids:
        if judge_model_basename(pid) != basename:
            continue
        if pid.startswith("global."):
            glob = glob or pid
        elif geo is None:
            geo = pid
    return geo or glob


def list_system_profiles(bedrock) -> list[str]:
    ids: list[str] = []
    for resp in bedrock.get_paginator("list_inference_profiles").paginate(typeEquals="SYSTEM_DEFINED"):
        ids.extend(x.get("inferenceProfileId", "") for x in resp.get("inferenceProfileSummaries") or [])
    return [i for i in ids if i]


def resolve_judge_model(bedrock, model_id: str) -> tuple[str | None, list[str]]:
    """返回 (区域内可用的推理档 id 或 None, 同系列候选列表——用于报错时给出可选项)。"""
    base = judge_model_basename(model_id)
    profiles = list_system_profiles(bedrock)
    best = rank_judge_profiles(base, profiles)
    # 报错时列出同一模型家族（如所有 haiku 档），比只说「找不到」更能直接告诉操作者该填什么。
    family = re.sub(r"-\d.*$", "", base.rsplit(".", 1)[-1])   # claude-haiku
    similar = sorted(p for p in profiles if family in p)
    return best, similar


def build_config(spec: dict, lambda_arn: str, judge_model: str | None = None) -> dict:
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
        problem = check_placeholders(spec, instructions)
        if problem:
            raise ValueError(problem)
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
            "modelConfig": {"bedrockEvaluatorModelConfig": {"modelId": judge_model or spec["modelId"]}},
        }}
    raise ValueError(f"未知的评估器类型: {kind}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", required=True)
    ap.add_argument("--defs", required=True)
    ap.add_argument("--lambda-arn", required=True)
    ap.add_argument("--judge-model", default="",
                    help="评委模型的完整推理档 id；留空则按区域从 ListInferenceProfiles 解析")
    args = ap.parse_args()

    defs = json.loads(pathlib.Path(args.defs).read_text(encoding="utf-8"))
    specs = [s for s in defs.get("evaluators", []) if not s.get("key", "").startswith("_")]
    if not specs:
        print("evaluators.json 里没有评估器定义", file=sys.stderr)
        return 1

    # Names/keys are deployment identities. Ambiguity must fail before the first
    # create, not produce duplicate evaluators whose IDs change on each rerun.
    for field in ("key", "evaluatorName"):
        values = [s.get(field) for s in specs]
        if any(not isinstance(v, str) or not v.strip() for v in values) or len(set(values)) != len(values):
            print(f"定义不完整/不合法: {field} 必须非空且唯一", file=sys.stderr)
            return 1
    client = boto3.client("bedrock-agentcore-control", region_name=args.region)
    try:
        have = existing_by_name(client, {s["evaluatorName"] for s in specs})
    except (ClientError, ValueError) as e:
        print(f"无法读取唯一的已有评估器，未创建任何资源: {e}", file=sys.stderr)
        return 1
    todo = [s for s in specs if s["evaluatorName"] not in have]

    # 评委模型：只在确实要新建 LLM-as-judge 评估器时解析，且在任何 CreateEvaluator 之前。
    override = args.judge_model.strip() or None
    profiles = None

    # 先把全部定义构造完再创建：任一定义不合法就整体不动，避免建出半套。
    configs: list[tuple[dict, dict]] = []
    for spec in todo:
        try:
            judge_model = override
            if spec.get("kind") == "llmAsAJudge" and judge_model is None:
                wanted = spec.get("modelId")
                if not isinstance(wanted, str) or not wanted.strip():
                    raise ValueError("llmAsAJudge 缺少 modelId")
                if profiles is None:
                    bedrock = boto3.client("bedrock", region_name=args.region)
                    profiles = list_system_profiles(bedrock)
                judge_model = rank_judge_profiles(judge_model_basename(wanted), profiles)
                if judge_model is None:
                    raise ValueError(f"{args.region} 没有 {wanted} 的推理档；"
                                     "用 --judge-model / EVAL_JUDGE_MODEL 指定")
                print(f"评委模型 {spec['evaluatorName']}: {judge_model}")
            if spec.get("level") not in _PLACEHOLDERS:
                raise ValueError(f"未知的 level: {spec.get('level')!r}")
            configs.append((spec, build_config(spec, args.lambda_arn, judge_model)))
        except (KeyError, ValueError, TypeError, ClientError) as e:
            print(f"{spec.get('evaluatorName')}: 定义不完整/不合法: {e}", file=sys.stderr)
            return 1

    rc = 0
    for spec in specs:
        name = spec["evaluatorName"]
        if name in have:
            # 重跑时按名复用，所以上一轮建成一半也不会重复建第一个。
            print(f"EVALUATOR_ID {spec['key']} {have[name]}   (已存在，复用)")
    for spec, cfg in configs:
        name = spec["evaluatorName"]
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
