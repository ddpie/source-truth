"""AgentCore 代码型评估器：校验答案里的源码出处是否真的存在、是否真的说了它支持的话。

## 为什么需要一个代码型评估器

内置评估器里 `Builtin.Faithfulness` 判的是「回答中的信息是否被**提供的上下文**支撑」，也就是答案与
agent 拿到的内容是否一致。它判不了、也无法判的是**那些内容本身是否对**：如果检索环节返回了错误的
行号，答案忠实地引用了它，Faithfulness 会判 Completely Yes。这不是内置评估器的缺陷，是它的输入
决定的——LLM 评委看不到仓库。

这个评估器只补这一块，且是纯确定性判断：把出处拿回真实仓库比对。质量、相关性、工具选择等一律交给
内置评估器，不重复造。

## 判据与刻意不做的判断

span 里有 `tool.parameters`（agent 读了哪个文件的哪几行）和答案正文，但**没有工具结果**
（只有 `output.mime_type`，值不落盘）。所以：

* 能判：出处指向的文件与行号在仓库里是否存在；那一行附近是否出现答案声称的符号。
* **不判**：「这个文件 agent 没用 read_file 读过」不作为失败。`search_files` 的结果同样不在 span 里，
  一条出处完全可能来自搜索结果——把它判失败会产生大量假失败，而假失败是这个评估器最不能犯的错：
  它会让正确答案变成红灯，从而让整个评估数据失去意义。这类情况只记入 explanation 供人参考。
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

from bedrock_agentcore.evaluation.custom_code_based_evaluators import (
    EvaluatorInput,
    EvaluatorOutput,
    custom_code_based_evaluator,
)

from bridge_client import BridgeClient, BridgeError
from citation_verify import FAILING, Verdict, extract_citations, verify

BRIDGE_URL = os.environ.get("BRIDGE_URL", "")
WINDOW = int(os.environ.get("CITATION_WINDOW", "4"))
READ_LIMIT = int(os.environ.get("READ_LIMIT", "400"))
# 仓库子目录名，逗号分隔。答案里的出处常缺这一层前缀，而它是部署时才确定的
# （.local/projects.json 的 subdir），所以由 apply-evaluations.sh 注入而不是写死。
REPO_PREFIXES = [p.strip() for p in os.environ.get("REPO_PREFIXES", "").split(",") if p.strip()]

# 答案正文所在的属性键。OpenInference 把每条消息拆成 llm.output_messages.<i>.message.content.0
# （纯文本）或 .message.contents.<j>.message_content.*（多模态/reasoning）。真实形状取自线上 span，
# 不是照文档猜的。
_OUT_TEXT_RE = re.compile(r"^llm\.output_messages\.(\d+)\.message\.content(?:\.0)?$")
_OUT_ROLE_RE = re.compile(r"^llm\.output_messages\.(\d+)\.message\.role$")


def _attrs(span: dict[str, Any]) -> dict[str, Any]:
    a = span.get("attributes")
    return a if isinstance(a, dict) else {}


def assistant_text(spans: list[dict[str, Any]], target_trace: str | None) -> str:
    """把目标 trace 内所有 assistant 文本按消息序号拼起来。

    取全部而不是只取最后一条：出处常散布在推理过程的多条消息里（实测一个会话的 23 条出处分布在
    4 个不同的 output_messages 下标上），只看最后一条会漏掉大部分要校验的对象。
    """
    chunks: list[tuple[int, int, str]] = []
    for order, span in enumerate(spans):
        if target_trace and span.get("traceId") and span["traceId"] != target_trace:
            continue
        attrs = _attrs(span)
        roles = {}
        for k, v in attrs.items():
            m = _OUT_ROLE_RE.match(k)
            if m:
                roles[m.group(1)] = v
        for k, v in attrs.items():
            m = _OUT_TEXT_RE.match(k)
            if not m or not isinstance(v, str) or not v.strip():
                continue
            idx = m.group(1)
            # 只要 assistant 的话。role 缺失时也收：宁可多校验几条出处，也不要因为一个属性没落盘
            # 就整段跳过——跳过会让评估器静默地什么都没查。
            if roles.get(idx) not in (None, "assistant"):
                continue
            chunks.append((order, int(idx), v))
    chunks.sort(key=lambda t: (t[0], t[1]))
    return "\n\n".join(c[2] for c in chunks)


def files_actually_read(spans: list[dict[str, Any]]) -> dict[str, list[tuple[int, int]]]:
    """从 read_file 的 tool.parameters 里取出「读过的文件 → 行区间」。

    只作为 explanation 里的参考信息，不参与判失败（见模块开头）。
    """
    out: dict[str, list[tuple[int, int]]] = {}
    for span in spans:
        attrs = _attrs(span)
        name = attrs.get("tool.name") or ""
        if "read_file" not in name:
            continue
        raw = attrs.get("tool.parameters")
        if not isinstance(raw, str):
            continue
        try:
            params = json.loads(raw)
        except ValueError:
            continue
        path = params.get("path")
        if not isinstance(path, str):
            continue
        start = params.get("line") or params.get("offset") or 1
        limit = params.get("limit") or READ_LIMIT
        try:
            start_i, limit_i = int(start), int(limit)
        except (TypeError, ValueError):
            continue
        out.setdefault(path, []).append((start_i, start_i + max(limit_i, 1) - 1))
    return out


def _candidates(path: str) -> list[str]:
    """按 bridge 能接受的形态给出候选路径，从最具体到最宽松。

    真机首次运行时这是最大的假失败来源：答案里的出处极少写成 bridge 需要的完整形态。实测出现过三种
    写法——`daggerfall-unity/Assets/.../FormulaHelper.cs`（可直接读）、
    `Assets/Scripts/Game/LevitateMotor.cs`（缺仓库前缀）、`LevitateMotor.cs:83`（裸文件名）。
    直接把答案里的字符串当路径传，后两种一律 path_refused，于是 4 个 trace 全判 Fail，而人工核对发现
    那些出处**全部真实存在**。这不是答案的问题，是校验器没能把出处映射回仓库。

    REPO_PREFIXES 来自环境变量，因为仓库子目录名是部署时才确定的（.local/projects.json 里的 subdir），
    写死在代码里就只对某一个项目成立。
    """
    out: list[str] = [path]
    for prefix in REPO_PREFIXES:
        if not prefix or path.startswith(prefix + "/"):
            continue
        out.append(f"{prefix}/{path}")
    # 裸文件名交给 glob 解析（下面 _make_reader 里处理），这里只负责前缀补全
    seen: set[str] = set()
    uniq = []
    for c in out:
        if c not in seen:
            seen.add(c)
            uniq.append(c)
    return uniq


def _make_reader(client: BridgeClient):
    """把 bridge 的 read_file 载荷转成 verify() 需要的整文件行列表。

    bridge 返回的是 **JSON 字符串**（`{"path","content","lines","start_line","start_line_1based",
    "total_lines","truncated"}`），不是裸文本。第一版直接对它 splitlines，于是每个文件都「只有 1 行」，
    每条出处都被判 line_out_of_range —— 15 个单测全过，因为假客户端返回的是裸文本。这个缺陷只有在
    真机上调用一次才暴露出来。

    行号对齐靠 `start_line_1based`：从第 1 行开始读时它是 1，内容第 i 项就是第 i 行。文件超过读取窗口
    时用 `total_lines`（文件真实行数）做范围判断，而不是拿到手的行数——否则一条指向窗口之外的正确出处
    会被误判成越界。
    """
    cache: dict[str, dict[str, Any]] = {}

    def _fetch(candidate: str) -> dict[str, Any]:
        raw = client.read_file(candidate, line=1, limit=READ_LIMIT)
        try:
            payload = json.loads(raw)
        except ValueError as e:
            raise BridgeError(f"read_file 返回的不是 JSON: {raw[:200]}") from e
        if not isinstance(payload, dict):
            raise BridgeError(f"read_file 返回的不是对象: {raw[:200]}")
        if payload.get("error"):
            raise ValueError(str(payload["error"]))
        lines = (payload.get("content") or "").split("\n")
        start1 = payload.get("start_line_1based")
        if not isinstance(start1, int) or start1 < 1:
            start1 = 1
        lines = [""] * (start1 - 1) + lines
        total = payload.get("total_lines")
        return {"lines": lines,
                "total_lines": total if isinstance(total, int) else len(lines),
                "truncated": bool(payload.get("truncated"))}

    def _read(path: str) -> dict[str, Any]:
        if path in cache:
            return cache[path]
        last: Exception | None = None
        for candidate in _candidates(path):
            try:
                cache[path] = _fetch(candidate)
                return cache[path]
            except (BridgeError, ValueError) as e:
                last = e
                continue

        # 所有候选都不行：裸文件名（`LevitateMotor.cs`）用 glob 在仓库里找一次。这是最后一招，
        # 命中多个同名文件时放弃——猜错文件比查不了更糟，会得出一个错误的「引用不成立」。
        base = path.rsplit("/", 1)[-1]
        if base and "*" not in base:
            try:
                matches = client.glob_files(f"**/{base}")
            except BridgeError:
                matches = []
            if len(matches) == 1:
                try:
                    cache[path] = _fetch(matches[0])
                    return cache[path]
                except (BridgeError, ValueError) as e:
                    last = e

        msg = str(last) if last else f"无法把出处映射到仓库中的文件: {path}"
        low = msg.lower()
        if "withheld" in low or "not a regular file" in low:
            raise ValueError(msg)
        # 定位不到文件是**校验器**没能解析出处，不是答案引错了。抛 BridgeError 让它落在
        # READ_ERROR（不计失败），而不是 ValueError→PATH_REFUSED 或 FileNotFoundError→FILE_NOT_FOUND。
        raise BridgeError(f"未能把出处 {path!r} 映射到仓库文件（试过 {_candidates(path)}）: {msg[:200]}")

    return _read


# 错误响应用的非评分 label。
#
# 为什么必须带 label：钉住的 SDK 1.14.1 里 EvaluatorOutput.label 是必填字段，构造不出「只有 errorCode」
# 的对象（1.22.0 才放宽）。既然一个官方支持代码型评估器的 SDK 版本强制要求 label，服务端就必须把
# label + errorCode 当作错误响应处理，也就是说判别依据是 errorCode。
#
# 即便这个推断错了、服务端把带 label 的响应当成有效评分，这个取值也不会误导人：它显然不是 Pass/Fail，
# 在统计里一眼能看出是评估器自身出错，而不是答案的引用有问题。
_ERROR_LABEL = "EvaluatorError"


def _error(code: str, message: str) -> EvaluatorOutput:
    return EvaluatorOutput(label=_ERROR_LABEL, errorCode=code, errorMessage=message[:1000])


@custom_code_based_evaluator()
def lambda_handler(evaluation: EvaluatorInput, _context: Any = None) -> EvaluatorOutput:
    """官方装饰器负责把 Lambda 事件解析成 EvaluatorInput、把返回值序列化成响应契约。

    用官方装饰器而不是自己解 dict：契约由服务端定义，会演进（文档里的模块名此刻就已经和 SDK 不一致），
    自己解就等于把一份会漂移的副本钉进这个仓库。代价是 Lambda 包要带 pydantic。
    """
    if not BRIDGE_URL:
        return _error("CONFIG_MISSING", "环境变量 BRIDGE_URL 未设置，无法回查仓库")

    spans = evaluation.session_spans or []
    if not spans:
        return _error("NO_SPANS", "evaluationInput.sessionSpans 为空")

    text = assistant_text(spans, evaluation.target_trace_id)
    if not text.strip():
        return _error("NO_ANSWER_TEXT",
                      "span 里没有 assistant 文本（llm.output_messages.*），"
                      "通常说明埋点未生效或载荷被 6MB 上限截断")

    cits = extract_citations(text)
    if not cits:
        # 没有出处不等于评估器故障：澄清型或诚实否认型回答本就可能不引代码。给 label 而不是 errorCode，
        # 这样它作为一个真实结果进入统计，而不是被当成评估器坏了。
        return EvaluatorOutput(
            label="NoCitations",
            explanation=f"答案里没有 file:line 形态的出处（正文 {len(text)} 字），无可校验对象")

    try:
        client = BridgeClient(BRIDGE_URL)
        # 先握手。放在 verify 之前是因为 verify 会把每条出处的读取异常收成 READ_ERROR（这样单条坏
        # 出处不会中断整份报告），systemic 故障因此不会以异常形式冒到这里——一次 bridge 不可达曾就这样
        # 被判成 Fail。先探一次连通性，把「连不上」和「答案有问题」分开。
        client.initialize()
        report = verify(text, _make_reader(client), window=WINDOW)
    except BridgeError as e:
        # bridge 不可达是**评估器**的故障，不是答案的问题。必须报 errorCode：报成 Fail 会把一次
        # 基础设施故障永久记成「答案引用不成立」，污染评估数据。
        return _error("BRIDGE_UNREACHABLE", str(e))

    # 握手成功但读取途中失败（bridge 中途重启、某个仓库副本正在重建索引）：同样是校验没能完成，
    # 不是答案的问题。哪怕只有一条读失败，也不能拿剩下的结论去评分——那份评分是不完整的。
    if report.read_errors:
        detail = "; ".join(f"{r.citation.raw}: {r.detail}" for r in report.read_errors[:3])
        return _error("BRIDGE_READ_FAILED",
                      f"{len(report.read_errors)}/{report.total} 条出处读取失败，校验未能完成: {detail}")

    summary = report.summary()
    read_map = files_actually_read(spans)
    not_read = sorted({c.path for c in cits if c.path not in read_map})

    if report.failing:
        label, value = "Fail", 0.0
    elif summary["confirmed"] > 0:
        label = "Pass"
        # 分数 = 被确认的出处 / 可校验的出处。UNCHECKABLE 不进分母：那是查不了，不是查出问题，
        # 计入会让「出处没带行号」这种正常写法压低分数。
        checkable = summary["total"] - summary["uncheckable"]
        value = round(summary["confirmed"] / checkable, 3) if checkable else 1.0
    else:
        # 一条都没真正核对上。绝不能报 Pass —— 那会和「全部确认」产生同样的绿灯。
        label, value = "Unverified", None

    lines = [f"出处 {summary['total']} 条：确认 {summary['confirmed']}，"
             f"仅命中外层 {summary['partial']}，不成立 {summary['failing']}，"
             f"无法核对 {summary['uncheckable']}"]
    for r in report.results:
        if r.verdict in FAILING or r.verdict is Verdict.SYMBOL_PARTIAL:
            lines.append(f"  [{r.verdict.value}] {r.citation.raw} — {r.detail}")
    if not_read:
        lines.append("以下出处的文件未出现在 read_file 调用中（仅供参考，不计失败："
                     "search_files 的结果不在 span 里，出处可能来自搜索）: "
                     + ", ".join(not_read[:6]))

    return EvaluatorOutput(label=label, value=value, explanation="\n".join(lines)[:4000])
