#!/usr/bin/env python3
"""汇总一轮或多轮黄金测试集结果，生成 Markdown 报告。

两条设计取自社区共识，都不是风格问题：

**按桶算分，不看聚合。** 桶二掉分是对抗性回归，桶四掉分是旧缺陷复发，聚合数字把两者都藏起来。
所以报告先给分桶，再给总计，而且总计只作参考。

**关联靠问题原文，不靠时序。** 每轮问答有独立 traceId，runtime 日志里带 request_payload.prompt。
按时间窗猜哪条 trace 对应哪个用例，在并发或重试时必然错配，而错配的评估结果比没有结果更糟。

用法::

    python3 evaluations/golden-set/report.py --runs r1
    python3 evaluations/golden-set/report.py --runs r1,r2,r3 --out report.md
"""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
RUNS = HERE / "runs"
REGION_DEFAULT = "ap-northeast-1"
AGENT_DEFAULT = "source_truth_agent_daggerfall-Lmp8rZ7EH1"
SUPPORTED_SCOPE = "openinference.instrumentation.claude_agent_sdk"
_OUT_TEXT_RE = re.compile(r"^llm\.output_messages\.(\d+)\.message\.content(?:\.0)?$")


def fetch_events(region: str, group: str, start_ms: int, limit: int = 5000,
                 pattern: str = "") -> list[dict]:
    """分页拉日志事件，可带服务端过滤模式。

    两处都被真实数据逼出来：
      * **必须分页** —— `--limit` 是从窗口起点往后截断，一轮 36 条用例的 span 远超单次上限。
        不分页时只关联上最早的 9 条，恰好是被截断的位置。
      * **必须服务端过滤** —— 光分页也不够：一轮 25 分钟的日志量把 40 页也吃满，后段（正好是
        桶 2/3/4）依然取不到，于是报告显示这三个桶「0 条关联」，看起来像系统性故障，实际问答
        全部成功跑完（网关日志 161 次 answer_completed）。用 --filter-pattern 让服务端只回
        需要的记录，量级直接降一到两个数量级。
    如果报告把「未关联」算成失败，这两个缺陷都会变成几十条虚假的质量回归。
    """
    recs: list[dict] = []
    token: str | None = None
    pages = 0
    while True:
        cmd = ["aws", "logs", "filter-log-events", "--region", region,
               "--log-group-name", group, "--start-time", str(start_ms),
               "--limit", str(limit), "--output", "json"]
        if pattern:
            cmd += ["--filter-pattern", pattern]
        if token:
            cmd += ["--next-token", token]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if out.returncode != 0:
            break
        payload = json.loads(out.stdout or "{}")
        for e in payload.get("events", []):
            m = e.get("message", "")
            if m.lstrip().startswith("{"):
                try:
                    recs.append(json.loads(m))
                except ValueError:
                    pass
        token = payload.get("nextToken")
        pages += 1
        if not token or pages >= 60:
            break
    return recs


def prompt_to_trace(spans: list[dict]) -> dict[str, str]:
    """问题原文 → traceId。取自 InvokeAgentRuntime 记录的 body.request_payload.prompt。"""
    out: dict[str, str] = {}
    for s in spans:
        body = s.get("body")
        if not isinstance(body, dict):
            continue
        payload = body.get("request_payload")
        if not isinstance(payload, dict):
            continue
        prompt = payload.get("prompt")
        tid = s.get("trace_id") or s.get("traceId")
        if isinstance(prompt, str) and tid:
            # 同一问题若被重试，保留最后一次——那是最终生效的那轮
            out[prompt.strip()] = tid
    return out


def spans_by_session(spans: list[dict]) -> dict[str, list[dict]]:
    by: dict[str, list[dict]] = collections.defaultdict(list)
    for s in spans:
        sid = (s.get("attributes") or {}).get("session.id")
        if sid:
            by[str(sid)].append(s)
    return by


def evaluate(region: str, evaluator_id: str, session_spans: list[dict],
             trace_id: str | None) -> list[dict]:
    import boto3
    from botocore.exceptions import ClientError

    client = boto3.client("bedrock-agentcore", region_name=region)
    kw: dict = {"evaluatorId": evaluator_id, "evaluationInput": {"sessionSpans": session_spans}}
    if trace_id:
        kw["evaluationTarget"] = {"traceIds": [trace_id]}
    try:
        return client.evaluate(**kw).get("evaluationResults", [])
    except ClientError as e:
        err = e.response.get("Error", {})
        return [{"errorCode": err.get("Code"), "errorMessage": err.get("Message", "")[:200]}]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True, help="run-id 列表，逗号分隔")
    ap.add_argument("--region", default=REGION_DEFAULT)
    ap.add_argument("--agent", default=AGENT_DEFAULT)
    ap.add_argument("--citation-evaluator", default="SourceTruthCitationAccuracy-7K6WEiF49E")
    ap.add_argument("--discipline-evaluator", default="SourceTruthEvidenceDiscipline-PKTGQPD8nn")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    run_ids = [r.strip() for r in args.runs.split(",") if r.strip()]
    records: list[dict] = []
    for rid in run_ids:
        path = RUNS / f"{rid}.jsonl"
        if not path.exists():
            print(f"✗ 缺少 {path}", file=sys.stderr)
            return 1
        for ln in path.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                records.append(json.loads(ln))
    if not records:
        print("没有记录", file=sys.stderr)
        return 1

    earliest = min(r["sent_at"] for r in records)
    start_ms = (earliest - 300) * 1000
    runtime_group = f"/aws/bedrock-agentcore/runtimes/{args.agent}-DEFAULT"

    # 分两次取，各带服务端过滤，而不是把整个窗口拉下来再筛。一轮 25 分钟的原始日志量会把分页也吃满，
    # 后段用例因此完全取不到——那会让报告显示整桶「0 条关联」，而实际问答全部成功。
    #   1) 关联用：只要带 request_payload 的记录（里面有问题原文与 traceId）
    #   2) 评估用：只要带受支持 scope 的埋点 span
    link_spans = fetch_events(args.region, runtime_group, start_ms,
                              pattern='"request_payload"')
    eval_spans = fetch_events(args.region, runtime_group, start_ms,
                              pattern=f'"{SUPPORTED_SCOPE}"')
    eval_spans += fetch_events(args.region, "aws/spans", start_ms,
                               pattern=f'"{SUPPORTED_SCOPE}"')
    spans = eval_spans
    print(f"关联用记录 {len(link_spans)} 条，评估用埋点 span {len(eval_spans)} 条", file=sys.stderr)

    p2t = prompt_to_trace(link_spans)
    by_session = spans_by_session(spans)
    trace_to_session = {}
    for sid, ss in by_session.items():
        for s in ss:
            tid = s.get("traceId") or s.get("trace_id")
            if tid:
                trace_to_session[tid] = sid

    rows = []
    for rec in records:
        q = rec["question"].strip()
        tid = p2t.get(q)
        sid = trace_to_session.get(tid) if tid else None
        row = dict(rec)
        row["trace_id"] = tid
        row["session_id"] = sid
        row["matched"] = bool(tid and sid)
        if row["matched"]:
            ss = by_session[sid]
            has_scope = any((s.get("scope") or {}).get("name") == SUPPORTED_SCOPE for s in ss)
            row["instrumented"] = has_scope
            if has_scope:
                for key, ev in (("citation", args.citation_evaluator),
                                ("discipline", args.discipline_evaluator)):
                    res = evaluate(args.region, ev, ss, tid)
                    row[key] = [{"label": r.get("label"), "value": r.get("value"),
                                 "errorCode": r.get("errorCode"),
                                 "explanation": (r.get("explanation") or "")[:400]}
                                for r in res]
        rows.append(row)
        print(f"  {rec['case_id']}: matched={row['matched']}", file=sys.stderr)

    md = render(rows, run_ids)
    if args.out:
        pathlib.Path(args.out).write_text(md, encoding="utf-8")
        print(f"报告写入 {args.out}", file=sys.stderr)
    else:
        print(md)
    return 0


def render(rows: list[dict], run_ids: list[str]) -> str:
    BUCKET_NAME = {1: "生产样本", 2: "对抗", 3: "边界", 4: "缺陷回放"}
    lines = [
        "# 黄金测试集报告",
        "",
        f"- 集合版本：`{rows[0]['set_version'] if rows else '?'}`",
        f"- 轮次：{', '.join(run_ids)}",
        f"- 生成时间：{time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 用例执行数：{len(rows)}",
        "",
        "分数按**桶**给，聚合只作参考：桶二掉分是对抗性回归，桶四掉分是旧缺陷复发，",
        "聚合数字会把两者一起藏掉。",
        "",
        "## 分桶结果",
        "",
        "| 桶 | 类型 | 用例 | 已关联 | 有埋点 | citation 通过 | citation 均分 | discipline 均分 |",
        "|---|---|---|---|---|---|---|---|",
    ]

    def agg(sel: list[dict]) -> tuple[int, int, int, str, str, str]:
        matched = sum(1 for r in sel if r.get("matched"))
        instr = sum(1 for r in sel if r.get("instrumented"))
        cit_pass = cit_tot = 0
        cit_vals: list[float] = []
        dis_vals: list[float] = []
        for r in sel:
            for item in r.get("citation") or []:
                if item.get("errorCode"):
                    continue
                cit_tot += 1
                if item.get("label") == "Pass":
                    cit_pass += 1
                if item.get("value") is not None:
                    cit_vals.append(float(item["value"]))
            for item in r.get("discipline") or []:
                if item.get("errorCode"):
                    continue
                if item.get("value") is not None:
                    dis_vals.append(float(item["value"]))
        cp = f"{cit_pass}/{cit_tot}" if cit_tot else "—"
        cv = f"{sum(cit_vals) / len(cit_vals):.2f}" if cit_vals else "—"
        dv = f"{sum(dis_vals) / len(dis_vals):.2f}" if dis_vals else "—"
        return len(sel), matched, instr, cp, cv, dv

    for b in (1, 2, 3, 4):
        sel = [r for r in rows if r["bucket"] == b]
        if not sel:
            continue
        n, matched, instr, cp, cv, dv = agg(sel)
        lines.append(f"| {b} | {BUCKET_NAME[b]} | {n} | {matched} | {instr} | {cp} | {cv} | {dv} |")
    n, matched, instr, cp, cv, dv = agg(rows)
    lines.append(f"| — | **合计（仅参考）** | {n} | {matched} | {instr} | {cp} | {cv} | {dv} |")

    lines += ["", "## 未关联的用例", ""]
    unmatched = [r for r in rows if not r.get("matched")]
    if unmatched:
        lines.append("这些用例发出去了但没能在遥测里找到对应 trace。**不能当成失败**——它是关联失败，")
        lines.append("而把它算成失败会污染通过率。逐条查网关日志确认是没跑还是没关联上。")
        lines.append("")
        for r in unmatched:
            lines.append(f"- `{r['case_id']}`（桶 {r['bucket']}）：{r['question'][:60]}")
    else:
        lines.append("无。")

    lines += ["", "## 逐条明细", ""]
    for r in sorted(rows, key=lambda x: (x["bucket"], x["case_id"])):
        lines.append(f"### `{r['case_id']}`　桶 {r['bucket']}　{r['intent']}／{r['retrieval_shape']}")
        lines.append("")
        lines.append(f"**问题**：{r['question']}")
        lines.append("")
        if not r.get("matched"):
            lines.append("未关联到 trace。")
            lines.append("")
            continue
        if not r.get("instrumented"):
            lines.append("该会话没有受支持 scope 的 span，评估器无法评（埋点问题，非答案问题）。")
            lines.append("")
            continue
        for key, title in (("citation", "出处准确性"), ("discipline", "证据纪律")):
            for item in r.get(key) or []:
                if item.get("errorCode"):
                    lines.append(f"- {title}：评估器错误 `{item['errorCode']}`")
                    continue
                lines.append(f"- {title}：**{item.get('label')}** "
                             f"value={item.get('value')}")
                expl = (item.get("explanation") or "").strip()
                if expl:
                    first = expl.splitlines()[0]
                    lines.append(f"  - {first[:200]}")
        lines.append("")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    raise SystemExit(main())
