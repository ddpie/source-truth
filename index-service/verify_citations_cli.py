#!/usr/bin/env python3
"""对真实答案跑引用校验，读的是索引主机上的真实仓库副本。

用法（在索引主机上，或任何持有仓库副本的机器上）::

    # 单条答案，从 stdin 读文本
    python3 verify_citations_cli.py --repo-root /data/repo/daggerfall-unity < answer.txt

    # 批量：每行一个 JSON 对象 {"id": ..., "answer": ..., "question": ...}
    python3 verify_citations_cli.py --repo-root /data/repo/x --jsonl < answers.jsonl

输出是一行 JSON 摘要（``--jsonl`` 下每条一行，末尾再加一行合计），便于直接汇总成评估数据。

为什么读取要走 ``to_local_path`` + ``served_paths``，而不是直接 ``open``：这个脚本接受的是**模型
写出来的路径**，也就是不可信输入。直接拼接就等于造出一个新的任意读原语，绕过 index-service 花了
一整轮才收紧的那两层（词法 + realpath 限制，以及默认拒绝名单）。校验器的价值不值得为它开一个后门。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import served_paths  # noqa: E402
from citation_verify import verify  # noqa: E402
from path_align import to_local_path  # noqa: E402


def make_reader(repo_root: str, repo: str = ""):
    """构造读取器：路径经 to_local_path 限制后才打开，行数按 splitlines 计。"""
    cache: dict[str, dict[str, Any]] = {}

    def _read(path: str, line: int | None = None) -> dict[str, Any]:
        if path in cache:
            return cache[path]
        # to_local_path 越界时抛 ValueError，被 verify 记成 PATH_REFUSED
        local = to_local_path(path, local_root=repo_root, repo=repo)
        if not os.path.isfile(local):
            raise FileNotFoundError(path)
        with open(local, "rb") as fh:
            raw = fh.read()
        # 源码可能不是 UTF-8（Unity 项目里常见 GB18030 注释）；errors="replace" 不会让一个编码
        # 问题变成「文件不存在」这种错误结论。
        text = raw.decode("utf-8", errors="replace")
        cache[path] = {"lines": text.splitlines()}
        return cache[path]

    return _read


def run_one(answer: str, reader, *, window: int) -> dict[str, Any]:
    rep = verify(answer, reader, window=window, path_filter=served_paths.withheld_reason)
    out = rep.summary()
    out["citations"] = [
        {
            "raw": r.citation.raw,
            "path": r.citation.path,
            "line": r.citation.line,
            "verdict": r.verdict.value,
            "detail": r.detail,
            "expected": list(r.citation and r.expected_symbols)[:6],
            "matched": r.matched_symbol,
            "matched_line": r.matched_line,
        }
        for r in rep.results
    ]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="校验答案里的源码出处是否成立")
    ap.add_argument("--repo-root", required=True, help="仓库副本根目录，如 /data/repo/daggerfall-unity")
    ap.add_argument("--repo", default="", help="多仓前缀（出处形如 <repo>/<rel> 时给出）")
    ap.add_argument("--window", type=int, default=4, help="符号检查的行窗口，默认 ±4")
    ap.add_argument("--jsonl", action="store_true", help="stdin 是每行一个 JSON 对象")
    args = ap.parse_args()

    if not os.path.isdir(args.repo_root):
        print(json.dumps({"error": f"repo-root 不存在: {args.repo_root}"}, ensure_ascii=False))
        return 2

    reader = make_reader(args.repo_root, args.repo)
    data = sys.stdin.read()

    if not args.jsonl:
        print(json.dumps(run_one(data, reader, window=args.window), ensure_ascii=False))
        return 0

    agg = {"answers": 0, "total": 0, "failing": 0, "confirmed": 0, "partial": 0, "uncheckable": 0}
    by_verdict: dict[str, int] = {}
    for ln in data.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            obj = json.loads(ln)
        except ValueError:
            print(json.dumps({"error": "unparseable jsonl line"}, ensure_ascii=False))
            continue
        res = run_one(obj.get("answer") or "", reader, window=args.window)
        res["id"] = obj.get("id")
        res["question"] = obj.get("question")
        print(json.dumps(res, ensure_ascii=False))
        agg["answers"] += 1
        for k in ("total", "failing", "confirmed", "partial", "uncheckable"):
            agg[k] += res.get(k, 0)
        for k, v in (res.get("by_verdict") or {}).items():
            by_verdict[k] = by_verdict.get(k, 0) + v
    agg["by_verdict"] = by_verdict
    # 没有一条出处被真正核对上时，说明这批数据无法支撑任何结论——必须说出来，而不是让
    # failing=0 看起来像成功。
    agg["verified_any"] = agg["confirmed"] > 0 or agg["partial"] > 0
    agg["aggregate"] = True
    print(json.dumps(agg, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
