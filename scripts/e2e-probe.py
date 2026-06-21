#!/usr/bin/env python3
"""e2e-probe.py — 对已部署的 AgentCore Runtime 跑一次真实端到端问答，校验全链路。

这是 `test.sh --full` 的 e2e 组件（此前为占位）。它走的是 **gateway 同一条 invoke 路径**
（boto3 InvokeAgentRuntime + 流式响应），并发送 **与 gateway 完全一致的 payload 形状**
`{prompt, traceId, repos}`（见 bot-gateway/src/sigv4.ts:buildInvokeRequest）——不发 agent 不读的
字段（如 projectId），以免产生“看似真实、实则不真实”的埋点。

读取（都不写死，便于客户环境复用）：
  - runtime ARN / region：`.local/deploy-config`（AGENT_RUNTIME_ARN；region 优先级
    --region > ARN 第 4 段（权威）> AWS_REGION 环境变量（仅兜底，避免开发机默认区域误覆盖））。
  - repos：`.local/projects.json`（projects.<id>.repos）。多项目时用 --project 选；单项目自动选。
    缺该文件则不发 repos（与单仓 / 零配置情形一致）。

校验（任一不满足则该探针判失败）：
  - 流式返回非空、能解出最终答案文本；
  - `permission_denials` 为空（只读边界未被突破）、`errors` / `api_error_status` 为空；
  - 答案含至少一个 `文件:行号` 或文件路径出处（“代码为唯一依据”——除非问题本身是澄清类）。

退出码：0 全通过；1 有探针失败；2 无法运行（缺依赖 / 缺配置 / 缺 ARN）——调用方（test.sh）
应把 2 视为 skip 而非 fail，保持离线/无部署环境下 `--full` 不被阻塞。

用法：
  scripts/e2e-probe.py [--region R] [--project P] [--timeout S] [--quiet]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPLOY_CONFIG = os.path.join(ROOT, ".local", "deploy-config")
PROJECTS_JSON = os.path.join(ROOT, ".local", "projects.json")

# AgentCore 要求 runtimeSessionId >= 33 字符（见 sigv4.ts MIN_SESSION_ID_LEN）。
_SESSION_PREFIX = "e2e-"

# 一个文件出处看起来像：FormulaHelper.cs:340 或 Assets/Scripts/Game/Foo.cs。
# 与 bot-gateway/src/metrics.ts countEvidenceCitations 的意图一致（路径 + 源码/配置扩展名）。
_CITATION_RE = re.compile(
    r"[\w./\\-]*[\w-]+\.(cs|json|txt|csv|cfg|xml|asset|prefab|unity|shader|md)(:\d+)?",
    re.IGNORECASE,
)

# 默认探针集：覆盖 正常取证 / 歧义澄清 / 不存在概念 三类边界。
# ambiguous / nonexistent 不强制要求出处（澄清或诚实否认本就可能不引代码）。
DEFAULT_PROBES = [
    {"kind": "evidence", "q": "角色的生命值上限是怎么计算的？", "require_citation": True},
    {"kind": "ambiguous", "q": "伤害怎么算？", "require_citation": False},
    {"kind": "nonexistent", "q": "游戏里的区块链钱包系统是怎么实现的？", "require_citation": False},
]


def _read_deploy_config() -> dict:
    cfg = {}
    if not os.path.exists(DEPLOY_CONFIG):
        return cfg
    with open(DEPLOY_CONFIG, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def _region_from_arn(arn: str) -> str:
    # arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<name>
    parts = arn.split(":")
    return parts[3] if len(parts) > 3 else ""


def resolve_region(arn: str, explicit: str | None, env_region: str | None) -> str:
    """region 优先级：--region（显式）> ARN 自带 region（权威——runtime 就在那个区域）
    > AWS_REGION 环境变量（开发机默认值，可能与目标区域不符，故仅兜底）。

    纯函数，便于单测（曾因 env > arn 的错误优先级导致跨区域 ResourceNotFound）。"""
    return explicit or _region_from_arn(arn) or (env_region or "")


def build_payload(prompt: str, trace_id: str, repos: list[str]) -> dict:
    """构造与 gateway 线上完全一致的 invoke payload（bot-gateway/src/sigv4.ts）：
    必有 prompt + traceId；repos 仅在非空时带上（与单仓 / 零配置情形线形一致）。
    不含 agent 不读的字段（如 projectId）。纯函数，便于单测契约。"""
    payload: dict = {"prompt": prompt, "traceId": trace_id}
    if repos:
        payload["repos"] = list(repos)
    return payload


def _resolve_repos(project: str | None) -> list[str]:
    if not os.path.exists(PROJECTS_JSON):
        return []
    with open(PROJECTS_JSON, encoding="utf-8") as fh:
        data = json.load(fh)
    projects = data.get("projects", {})
    if not projects:
        return []
    if project:
        entry = projects.get(project)
        if not entry:
            raise SystemExit(f"--project '{project}' 不在 projects.json（有：{list(projects)}）")
    elif len(projects) == 1:
        entry = next(iter(projects.values()))
    else:
        raise SystemExit(f"projects.json 有多个项目，请用 --project 指定：{list(projects)}")
    repos = entry.get("repos", [])
    return [r for r in repos if isinstance(r, str)]


def _extract_answer(raw: str) -> str:
    """从流式响应里取最终答案文本。响应可能是 JSON（含 result 字段）或纯文本。"""
    s = raw.strip()
    # 末行常是一个完整的 JSON 对象（含 result）。
    for cand in (s, s.splitlines()[-1] if s else ""):
        cand = cand.strip()
        if cand.startswith("{") and cand.endswith("}"):
            try:
                obj = json.loads(cand)
                if isinstance(obj, dict) and obj.get("result"):
                    return obj["result"], obj
            except json.JSONDecodeError:
                pass
    return raw, None


def run_probe(client, arn: str, repos: list[str], probe: dict, timeout: int, quiet: bool) -> dict:
    trace = f"st-e2e{uuid.uuid4().hex[:24]}"
    sess = _SESSION_PREFIX + uuid.uuid4().hex  # >= 33 字符
    # 严格匹配 gateway 线上 payload 形状：{prompt, traceId, repos}。
    payload = build_payload(probe["q"], trace, repos)
    t0 = time.time()
    result = {"kind": probe["kind"], "traceId": trace, "ok": False, "reasons": []}
    try:
        resp = client.invoke_agent_runtime(
            agentRuntimeArn=arn,
            runtimeSessionId=sess,
            payload=json.dumps(payload).encode(),
        )
        buf = b""
        for ev in resp["response"]:
            buf += ev if isinstance(ev, bytes) else str(ev).encode()
        result["totalMs"] = int((time.time() - t0) * 1000)
        raw = buf.decode("utf-8", "replace")
        answer, obj = _extract_answer(raw)
        result["bytes"] = len(buf)

        # 边界 / 错误检查（基于结构化对象，取不到则降级到原文）。
        if obj is not None:
            if obj.get("permission_denials"):
                result["reasons"].append(f"permission_denials 非空：{obj['permission_denials']}")
            if obj.get("errors"):
                result["reasons"].append(f"errors 非空：{obj['errors']}")
            if obj.get("api_error_status"):
                result["reasons"].append(f"api_error_status：{obj['api_error_status']}")
        if not answer or len(answer.strip()) < 10:
            result["reasons"].append("答案为空或过短")
        if probe.get("require_citation"):
            if not _CITATION_RE.search(answer):
                result["reasons"].append("缺少文件出处（代码为唯一依据未体现）")
            else:
                result["citations"] = len(set(m.group(0) for m in _CITATION_RE.finditer(answer)))
        result["ok"] = not result["reasons"]
    except Exception as e:  # noqa: BLE001 — 探针把任何异常都记成失败原因
        result["totalMs"] = int((time.time() - t0) * 1000)
        result["reasons"].append(f"invoke 异常：{type(e).__name__}: {e}")
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="对已部署 Runtime 跑真实 e2e 问答")
    ap.add_argument("--region", default=None, help="覆盖区域（默认从 ARN 解析）")
    ap.add_argument("--project", default=None, help="projects.json 里的 projectId（多项目时必填）")
    ap.add_argument("--timeout", type=int, default=600, help="单探针超时秒（默认 600）")
    ap.add_argument("--quiet", action="store_true", help="只打印汇总")
    args = ap.parse_args()

    cfg = _read_deploy_config()
    arn = cfg.get("AGENT_RUNTIME_ARN", "").strip()
    if not arn:
        print("SKIP: .local/deploy-config 无 AGENT_RUNTIME_ARN（未部署？）", file=sys.stderr)
        return 2
    region = resolve_region(arn, args.region, os.environ.get("AWS_REGION"))
    if not region:
        print("SKIP: 无法确定区域（--region / ARN / AWS_REGION 均无）", file=sys.stderr)
        return 2

    try:
        import boto3  # noqa: PLC0415 — 延迟导入，缺 boto3 时退 2（skip）而非崩溃
    except ImportError:
        print("SKIP: 未安装 boto3（e2e 需 AWS SDK）", file=sys.stderr)
        return 2

    try:
        repos = _resolve_repos(args.project)
    except SystemExit as e:
        print(f"SKIP: {e}", file=sys.stderr)
        return 2

    client = boto3.client("bedrock-agentcore", region_name=region)
    print(f"e2e: runtime={arn.split('/')[-1]} region={region} repos={repos or '(none)'}")

    results = []
    for probe in DEFAULT_PROBES:
        r = run_probe(client, arn, repos, probe, args.timeout, args.quiet)
        results.append(r)
        status = "PASS" if r["ok"] else "FAIL"
        extra = f" citations={r['citations']}" if r.get("citations") else ""
        print(f"  [{status}] {r['kind']:12s} {r['traceId']} {r.get('totalMs','?')}ms"
              f" {r.get('bytes','?')}B{extra}")
        for why in r["reasons"]:
            print(f"         ↳ {why}")

    failed = [r for r in results if not r["ok"]]
    passed = len(results) - len(failed)
    print(f"e2e 汇总：{passed}/{len(results)} 通过")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
