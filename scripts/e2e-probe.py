#!/usr/bin/env python3
"""e2e-probe.py — 对已部署的 AgentCore Runtime 跑一次真实端到端问答，校验全链路。

这是 `test.sh --full` 的 e2e 组件（此前为占位）。它走的是 **gateway 同一条 invoke 路径**
（boto3 InvokeAgentRuntime + 流式响应），并发送 **与 gateway 完全一致的 payload 形状**
`{prompt, traceId, repos}`（见 bot-gateway/src/sigv4.ts:buildInvokeRequest）——不发 agent 不读的
字段（如 projectId），以免产生“看似真实、实则不真实”的埋点。

读取（都不写死，便于在不同环境复用）：
  - runtime ARN / region：`.local/deploy-config`（AGENT_RUNTIME_ARN；region 优先级
    --region > ARN 第 4 段（权威）> AWS_REGION 环境变量（仅兜底，避免开发机默认区域误覆盖））。
  - repos：`.local/projects.json`（projects.<id>.repos）。多项目时用 --project 选；单项目自动选。
    缺该文件则不发 repos（与单仓 / 零配置情形一致）。

校验（任一不满足则该探针判失败）：
  - 流式返回非空、能解出最终答案文本；
  - `permission_denials` 为空（只读边界未被突破）、`errors` / `api_error_status` 为空；
  - 答案含至少一个 `文件:行号` 或文件路径出处（“代码为唯一依据”——除非问题本身是澄清类）；
  - 部署 smoke 必须有成功的源码或配置读取工具调用，不能只信答案中的文件名。

退出码：0 全通过；1 有探针失败；2 无法运行（缺依赖 / 缺配置 / 缺 ARN）——调用方（test.sh）
应把 2 视为 skip 而非 fail，保持离线/无部署环境下 `--full` 不被阻塞。

用法：
  scripts/e2e-probe.py [--region R] [--project P] [--timeout S] [--quiet] [--smoke]
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
    r"[\w./\\-]*[\w-]+\.(cs|py|tsx?|jsx?|go|rs|c|cc|cpp|h|hpp|java|kt|swift|lua|sh|proto|"
    r"json|txt|csv|tsv|xlsx|xlsm|xltx|xltm|db|sqlite3?|cfg|xml|toml|ya?ml|"
    r"asset|prefab|unity|shader|md)\b(:\d+)?",
    re.IGNORECASE,
)

# 默认探针集：覆盖 正常取证 / 歧义澄清 / 不存在概念 三类边界。
# ambiguous / nonexistent 不强制要求出处（澄清或诚实否认本就可能不引代码）。
DEFAULT_PROBES = [
    {"kind": "evidence", "q": "角色的生命值上限是怎么计算的？", "require_citation": True},
    {"kind": "ambiguous", "q": "伤害怎么算？", "require_citation": False},
    {"kind": "nonexistent", "q": "游戏里的区块链钱包系统是怎么实现的？", "require_citation": False},
]
SMOKE_PROBES = [
    {
        "kind": "smoke",
        "q": "请在当前被索引的目标代码仓库中，检索并读取一段输入校验或数值计算的源码，"
             "简述其中一个条件判断的实际行为，并引用文件和行号。"
             "只分析目标仓库的代码逻辑，不讨论你自身的实现或部署。回答保持简短。",
        "require_citation": True,
        "require_read_tool": True,
    }
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


def _resolve_runtime_arn(cfg: dict, project: str | None) -> str:
    """从 deploy-config 解析 runtime ARN。多项目部署链写的是命名空间键
    RUNTIME_ARN_<projectId 的 - 转 _>（deploy_project.sh），不再写 AGENT_RUNTIME_ARN；
    后者只作老配置兜底。--project 指定时取该项目的键；未指定且恰好只有一个
    RUNTIME_ARN_* 键时取它；多个则返回 ""（调用方 skip 并提示 --project）。纯函数。"""
    if project:
        return cfg.get(f"RUNTIME_ARN_{project.replace('-', '_')}", "").strip()
    keys = [k for k in cfg if k.startswith("RUNTIME_ARN_")]
    if len(keys) == 1:
        return cfg[keys[0]].strip()
    if len(keys) > 1:
        return ""  # 多项目且未指定 --project → 无法确定
    return cfg.get("AGENT_RUNTIME_ARN", "").strip()  # 老单项目配置兜底


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
    # projects.json 的 repos 是对象数组（{subdir, git, ref}）；gateway 只下发 subdir 列表
    # （见 bot-gateway/src/project-routing.ts），这里保持同形。兼容早期纯字符串写法。
    out: list[str] = []
    for r in repos:
        if isinstance(r, str):
            out.append(r)
        elif isinstance(r, dict) and isinstance(r.get("subdir"), str):
            out.append(r["subdir"])
    return out


def _stream_records(raw: str) -> list[dict]:
    """Decode the JSON or SSE envelope without silently dropping broken data frames."""
    try:
        document = json.loads(raw)
    except json.JSONDecodeError:
        pass
    else:
        return [document] if isinstance(document, dict) else []
    records = []
    for line in raw.splitlines():
        line = line.strip()
        candidate = line.removeprefix("data:").strip()
        if not candidate or candidate == "[DONE]" or line.startswith((":", "event:", "id:", "retry:")):
            continue
        try:
            event = json.loads(candidate)
        except json.JSONDecodeError:
            if line.startswith("data:"):
                raise ValueError("invalid JSON in agent data frame") from None
            continue
        if not isinstance(event, dict):
            raise ValueError("agent event must be an object")
        records.append(event)
    return records


def _extract_answer(raw: str) -> tuple[str, dict | None]:
    """Validate the event stream before trusting its terminal answer."""
    records = _stream_records(raw)
    for event in records:
        if "protocol" in event and event["protocol"] != "source-truth":
            raise ValueError("unknown agent stream protocol")
        # AgentCore may report an error over HTTP 200 outside our normalized
        # envelope. It must not disappear merely because a result follows it.
        if not isinstance(event.get("content"), list) and event.get("error"):
            raise ValueError("agent transport or run error")
    normalized = [event for event in records if event.get("protocol") == "source-truth"]
    if normalized:
        if len(normalized) != len(records):
            raise ValueError("mixed agent stream protocols")
        run_id = normalized[0].get("runId")
        if not isinstance(run_id, str) or not run_id.strip():
            raise ValueError("invalid agent run ID")
        tools = set()
        seen_tools = set()
        seen_messages = set()
        current_message = None
        tool_after_text = True
        for seq, event in enumerate(normalized, 1):
            if (type(event.get("version")) is not int or event["version"] != 1
                    or type(event.get("seq")) is not int or event["seq"] != seq
                    or event.get("runId") != run_id):
                raise ValueError("invalid agent stream sequence/version")
            kind = event.get("type")
            if kind == "run_failed":
                raise ValueError("agent run failed")
            if kind == "run_completed":
                if seq != len(normalized):
                    raise ValueError("events after terminal result")
                if not isinstance(event.get("text"), str) or not event["text"].strip():
                    raise ValueError("empty agent terminal answer")
                if tools:
                    raise ValueError("agent completed with unfinished tools")
            elif kind == "text_delta":
                message_id = event.get("messageId")
                if (not isinstance(message_id, str) or not message_id
                        or not isinstance(event.get("text"), str)):
                    raise ValueError("invalid agent text delta")
                if event["text"]:
                    if message_id in seen_messages and (message_id != current_message or tool_after_text):
                        raise ValueError("agent stream message order mismatch")
                    seen_messages.add(message_id)
                    current_message = message_id
                    tool_after_text = False
            elif kind in ("tool_started", "tool_finished"):
                tool_id = event.get("toolId")
                if not isinstance(tool_id, str) or not tool_id:
                    raise ValueError("invalid agent tool ID")
                if kind == "tool_started":
                    if (tool_id in seen_tools or not isinstance(event.get("name"), str)
                            or not event["name"].strip()):
                        raise ValueError("invalid agent tool start")
                    tools.add(tool_id)
                    seen_tools.add(tool_id)
                    tool_after_text = True
                else:
                    if tool_id not in tools or type(event.get("isError")) is not bool:
                        raise ValueError("invalid agent tool result")
                    tools.remove(tool_id)
            else:
                raise ValueError("unknown agent stream event")
        last = normalized[-1]
        if last.get("type") != "run_completed":
            raise ValueError("agent stream truncated")
        return last.get("text", ""), last
    # Legacy Claude streams may contain a failed result before the last record.
    for event in records:
        if not isinstance(event.get("content"), list) and (
            event.get("is_error") or str(event.get("subtype", "")).startswith("error")
        ):
            raise ValueError("agent returned an error result")
    if records:
        last = records[-1]
        if not isinstance(last.get("result"), str) or not last["result"].strip():
            raise ValueError("agent stream has no terminal answer")
        return last["result"], last
    return raw, None


def _read_content_failed(content: object) -> bool:
    """Recognize the index bridge's JSON error envelope, not source text inside it."""
    if isinstance(content, str):
        try:
            content = json.loads(content)
        except json.JSONDecodeError:
            return False
    if isinstance(content, dict):
        return bool(content.get("error"))
    if isinstance(content, list):
        return any(_read_content_failed(block.get("text")) for block in content
                   if isinstance(block, dict) and isinstance(block.get("text"), str))
    return False


def _successful_read_tools(raw: str) -> int:
    """Require completed reads, rather than trusting a model-written citation."""
    pending: dict[str, str] = {}
    successful = 0
    for event in _stream_records(raw):
        starts = []
        results = []
        if event.get("protocol") == "source-truth":
            if event.get("type") == "tool_started":
                starts.append((event.get("toolId"), event.get("name")))
            elif event.get("type") == "tool_finished":
                results.append((event.get("toolId"), event.get("isError") is True))
        else:
            partial = event.get("event") or {}
            if isinstance(partial, dict) and partial.get("type") == "content_block_start":
                block = partial.get("content_block") or {}
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    starts.append((block.get("id"), block.get("name")))
            for block in event.get("content", []) if isinstance(event.get("content"), list) else []:
                if not isinstance(block, dict):
                    continue
                if "tool_use_id" in block:
                    results.append((block["tool_use_id"], block.get("is_error") is True
                                    or _read_content_failed(block.get("content"))))
                elif "id" in block and "name" in block:
                    starts.append((block["id"], block["name"]))
        for tool_id, name in starts:
            if isinstance(tool_id, str) and isinstance(name, str):
                pending[tool_id] = name.removeprefix("mcp__codegraph__")
        for tool_id, is_error in results:
            name = pending.pop(tool_id, "")
            if not is_error and name in ("codegraph_read_file", "codegraph_read_table"):
                successful += 1
    return successful


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
        body = resp["response"]
        chunks = []
        try:
            for ev in body:
                chunks.append(ev if isinstance(ev, bytes) else str(ev).encode())
        finally:
            close = getattr(body, "close", None)
            if close is not None:
                close()
        buf = b"".join(chunks)
        result["totalMs"] = int((time.time() - t0) * 1000)
        raw = buf.decode("utf-8", "replace")
        answer, obj = _extract_answer(raw)
        result["bytes"] = len(buf)

        # 边界 / 错误检查（基于结构化对象，取不到则降级到原文）。
        if obj is not None:
            if obj.get("is_error") or str(obj.get("subtype", "")).startswith("error"):
                result["reasons"].append("agent returned an error result")
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
        if probe.get("require_read_tool"):
            result["successfulReads"] = _successful_read_tools(raw)
            if not result["successfulReads"]:
                result["reasons"].append("未观察到成功的源码/配置读取工具调用")
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
    ap.add_argument("--smoke", action="store_true", help="部署验收：只跑一个适用任意代码仓的真实问答")
    args = ap.parse_args()

    cfg = _read_deploy_config()
    arn = _resolve_runtime_arn(cfg, args.project)
    if not arn:
        print("SKIP: .local/deploy-config 无 RUNTIME_ARN_<project>（未部署？多项目时用 --project 指定）",
              file=sys.stderr)
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

    # --timeout 实际落到 boto3 的读超时（流式响应按块计时）；此前它只传进 run_probe
    # 却无人消费——挂死的 runtime 会让 e2e 卡住而不是按 --timeout 失败。
    from botocore.config import Config  # noqa: PLC0415
    client = boto3.client(
        "bedrock-agentcore", region_name=region,
        config=Config(read_timeout=args.timeout, connect_timeout=30, retries={"max_attempts": 1}),
    )
    print(f"e2e: runtime={arn.split('/')[-1]} region={region} repos={repos or '(none)'}")

    results = []
    for probe in SMOKE_PROBES if args.smoke else DEFAULT_PROBES:
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
