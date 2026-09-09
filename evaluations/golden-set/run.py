#!/usr/bin/env python3
"""对黄金测试集跑一轮真实端到端评估，并把结果落成可比对的 JSONL。

为什么走真实飞书链路而不是直接 invoke runtime：这个项目的历史反复证明，只有真机才暴露真问题——
校验器把 JSON 信封当裸文本、路径缺仓库前缀、行号超出读取窗口，三个缺陷全部是 15 个单测通过之后
在真机上才现形的。少一段链路，就少一类能被发现的缺陷。

用法::

    python3 evaluations/golden-set/run.py --region ap-northeast-1 --run-id r1
    python3 evaluations/golden-set/run.py --region ap-northeast-1 --run-id r1 --buckets 4
    python3 evaluations/golden-set/run.py --region ap-northeast-1 --run-id r2 --cases gs_prod_0001,gs_adv_0002

结果写到 evaluations/golden-set/runs/<run-id>.jsonl，一条一个用例。多轮之间可直接 diff——
社区实践里这一点是硬要求：分数差只有在集合版本固定时才可解释，所以每条结果都记 set_version。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CASES = HERE / "cases.json"
RUNS = HERE / "runs"

# 默认的普通群：所有消息共用一个 sessionId，因此**逐条串行**。
CHAT_ID = "oc_1b38d6cb6c22cdd9d2bff6b02040ead5"
# 话题群：每条新消息自成一个话题，thread_id 不同 → sessionId 不同 → 可并行。
#
# 为什么这是唯一有效的加速点：网关按 runtimeSessionId 串行化每一轮
# （`bot-gateway/src/index.ts` 的 streamingCardInvoke，注释写明「两轮不能同时跑在同一个热
# microVM 上，那会写坏它唯一的一份 SDK 会话」）。这个串行不能绕，也不该绕。真正的瓶颈是 36 条
# 用例全落在同一个 sessionId 上，于是 MAX_CONCURRENT_INVOKES（默认 8）的额度一个都用不上。
#
# 实测对照：普通群里两条相隔 3 秒发出，第二条排队；话题群里同样两条拿到
# sessionId=821951fb… 与 b0dee070…，01:09:56 与 01:09:59 各自 invoke_start，真并行。
#
# 顺带解决另一个问题：LLM-as-judge 的提示词含 `{context}` 占位符，服务端填入整个会话的历史轮次。
# 36 条挤在一个会话里会长到 720 span / 56 trace，靠后的 trace 必然 ModelContextWindowExceededError。
# 一条用例一个会话，这个问题不复存在。
TOPIC_CHAT_ID = "oc_313912a22b43d32430533dbc957ea19d"
BOT_ID = "ou_bd45b9d1fe7e95cdfc3b0e3bfe704c78"
BOT_NAME = "Daggerfall助手"


def load_cases(buckets: set[int] | None, only: set[str] | None) -> tuple[dict, list[dict]]:
    data = json.loads(CASES.read_text(encoding="utf-8"))
    cases = data["cases"]
    if buckets:
        cases = [c for c in cases if c["bucket"] in buckets]
    if only:
        cases = [c for c in cases if c["case_id"] in only]
    return data, cases


def send(question: str, chat_id: str) -> str | None:
    """把问题以「用户 @ 机器人」的形式发出去，返回 message_id。

    必须带真实 mention：纯文本 @名字 不会触发机器人，这一点踩过。
    """
    text = f'<at user_id="{BOT_ID}">{BOT_NAME}</at> {question}'
    out = subprocess.run(
        ["lark-cli", "im", "+messages-send", "--as", "user", "--chat-id", chat_id, "--text", text],
        capture_output=True, text=True, timeout=120)
    m = re.search(r"\{.*\}", out.stdout or "", re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except ValueError:
        return None
    return ((d.get("data") or {}).get("message_id")) if d.get("ok") else None



def main() -> int:
    ap = argparse.ArgumentParser(description="跑黄金测试集")
    ap.add_argument("--region", default="ap-northeast-1")
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--project", default="daggerfall")
    ap.add_argument("--instance", default="")
    ap.add_argument("--buckets", default="", help="只跑这些桶，逗号分隔")
    ap.add_argument("--cases", default="", help="只跑这些 case_id，逗号分隔")
    ap.add_argument("--parallel", action="store_true",
                    help="发到话题群：每条用例自成一个话题，拿到独立 sessionId，可并行执行。"
                         "网关按 sessionId 串行化每一轮（同一 microVM 只有一份 SDK 会话，不能并发），"
                         "所以这是唯一有效的加速点——普通群里 36 条全串在一个 sessionId 上，"
                         "MAX_CONCURRENT_INVOKES 的 8 个额度一个都用不上")
    ap.add_argument("--chat-id", default="", help="覆盖目标群（默认按 --parallel 选普通群或话题群）")
    ap.add_argument("--gap", type=int, default=45,
                    help="两条之间的间隔秒数。45 秒够网关顺序处理完上一轮（实测一轮 40-90 秒），"
                         "而结果关联**不依赖时序**：每轮问答有独立 traceId，runtime 日志里带 "
                         "request_payload.prompt，report.py 按问题原文对回用例。因此这里只需避免把"
                         "网关压垮，不需要留出整轮时间")
    args = ap.parse_args()

    chat_id = args.chat_id or (TOPIC_CHAT_ID if args.parallel else CHAT_ID)
    # 并行模式下间隔只用于别把网关一次性打满（额度 8），不需要留出整轮答题时间。
    gap = args.gap if not args.parallel or args.gap != 45 else 8
    buckets = {int(b) for b in args.buckets.split(",") if b.strip()} or None
    only = {c.strip() for c in args.cases.split(",") if c.strip()} or None
    data, cases = load_cases(buckets, only)
    if not cases:
        print("没有匹配的用例", file=sys.stderr)
        return 1

    RUNS.mkdir(parents=True, exist_ok=True)
    out_path = RUNS / f"{args.run_id}.jsonl"
    started = int(time.time())
    print(f"集合 {data['set_version']}，本轮 {len(cases)} 条，间隔 {gap}s，"
          f"{'并行（话题群）' if args.parallel else '串行（普通群）'}，群 {chat_id}")
    print(f"结果写入 {out_path}")

    with out_path.open("w", encoding="utf-8") as fh:
        for i, case in enumerate(cases, 1):
            t0 = int(time.time())
            mid = send(case["question"], chat_id)
            rec = {
                "run_id": args.run_id,
                "set_version": data["set_version"],
                "case_id": case["case_id"],
                "bucket": case["bucket"],
                "intent": case["intent"],
                "retrieval_shape": case["retrieval_shape"],
                "question": case["question"],
                "expect": case["expect"],
                "sent_at": t0,
                "message_id": mid,
                "sent_ok": bool(mid),
            }
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
            status = "已发送" if mid else "发送失败"
            print(f"[{i}/{len(cases)}] {case['case_id']} {status}")
            if i < len(cases):
                time.sleep(gap)

    print(f"\n发送完毕。用时 {(int(time.time()) - started) // 60} 分钟。")
    print("下一步：等实时评估打分（会话超时 20 分钟后触发），再跑 report.py 汇总。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
