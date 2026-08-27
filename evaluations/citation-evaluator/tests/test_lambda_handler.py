"""代码型评估器 handler 的测试。

span 的**形状**取自线上真实遥测（属性键名、tool.parameters 的 JSON 结构、答案落在
llm.output_messages.<i>.message.content.0），但所有标识符都是合成的：session id 全零、trace id 带
序号、路径用中性名。本仓库已经因为把真实飞书 open_id/chat_id 当测试 fixture 提交过一次而被指出，
那与项目自身的脱敏规则直接矛盾。

测试重点仍然是「这个评估器不会在查不到东西时报成功」，以及「基础设施故障不能被记成答案的问题」——
后者尤其重要：一次 bridge 不可达若被判成 Fail，就会在评估数据里留下一条永久的、错误的「引用不成立」。
"""

from __future__ import annotations

import importlib
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
CANON = os.path.abspath(os.path.join(PKG, "..", "..", "index-service"))
for p in (PKG, CANON):
    if p not in sys.path:
        sys.path.insert(0, p)

pytest.importorskip(
    "bedrock_agentcore.evaluation.custom_code_based_evaluators",
    reason="需要 bedrock-agentcore SDK（见 evaluations/citation-evaluator/requirements.txt）",
)

SESSION = "00000000-0000-0000-0000-000000000000"
TRACE = "0000000000000000000000000000ab01"

SRC_LINES = [
    "using System;",                                     # 1
    "",                                                  # 2
    "namespace Game",                                    # 3
    "{",                                                 # 4
    "    public static class FormulaHelper",              # 5
    "    {",                                              # 6
    "        public static int MaxEncumbrance(int str)",   # 7
    "        {",                                          # 8
    "            return str * 4;",                        # 9
    "        }",                                          # 10
    "    }",                                              # 11
    "}",                                                  # 12
]


def make_llm_span(texts: list[str], trace: str = TRACE) -> dict:
    attrs: dict[str, object] = {
        "session.id": SESSION,
        "openinference.span.kind": "AGENT",
        "llm.model_name": "test-model",
    }
    for i, t in enumerate(texts):
        attrs[f"llm.output_messages.{i}.message.role"] = "assistant"
        attrs[f"llm.output_messages.{i}.message.content.0"] = t
    return {"name": "ClaudeAgentSDK.query", "traceId": trace,
            "scope": {"name": "openinference.instrumentation.claude_agent_sdk"},
            "attributes": attrs}


def make_tool_span(path: str, line: int, limit: int, trace: str = TRACE) -> dict:
    return {"name": "mcp__codegraph__codegraph_read_file", "traceId": trace,
            "scope": {"name": "openinference.instrumentation.claude_agent_sdk"},
            "attributes": {
                "session.id": SESSION,
                "openinference.span.kind": "TOOL",
                "tool.name": "mcp__codegraph__codegraph_read_file",
                "tool.parameters": json.dumps({"path": path, "line": line, "limit": limit}),
            }}


def event(spans: list[dict], trace: str | None = TRACE) -> dict:
    ev: dict = {"schemaVersion": "1.0", "evaluatorId": "test-eval",
                "evaluatorName": "Test", "evaluationLevel": "TRACE",
                "evaluationInput": {"sessionSpans": spans},
                "evaluationReferenceInputs": []}
    if trace:
        ev["evaluationTarget"] = {"traceIds": [trace]}
    return ev


@pytest.fixture()
def mod(monkeypatch):
    """导入 handler 并把 bridge 换成内存里的假读取器。"""
    monkeypatch.setenv("BRIDGE_URL", "http://bridge.invalid:8080/mcp")
    import lambda_function as lf

    importlib.reload(lf)
    return lf


def stub_bridge(mod, monkeypatch, files: dict[str, list[str]], *, fail: str | None = None):
    class FakeClient:
        def __init__(self, url, **kw):
            self.url = url

        def initialize(self):
            # 真实 handler 会先握手再校验；不建模这一步的假客户端会让「连不上」这条路径测不到。
            if fail:
                raise mod.BridgeError(fail)

        def read_file(self, path, **kw):
            if fail:
                raise mod.BridgeError(fail)
            if path not in files:
                raise mod.BridgeError(f"no such file: {path}")
            return "\n".join(files[path])

    monkeypatch.setattr(mod, "BridgeClient", FakeClient)


# --------------------------------------------------------------------- 抽取
def test_assistant_text_joins_all_messages(mod):
    """出处常散布在多条消息里（实测一个会话的 23 条出处分布在 4 个下标上），只取最后一条会漏掉大半。"""
    span = make_llm_span(["先定位符号。", "见 Game/Formulas.cs:7 的实现。"])
    text = mod.assistant_text([span], TRACE)
    assert "先定位符号" in text and "Game/Formulas.cs:7" in text


def test_assistant_text_respects_trace_target(mod):
    keep = make_llm_span(["本 trace: a/keep.cs:1"], trace=TRACE)
    other = make_llm_span(["别的 trace: a/other.cs:1"], trace="0000000000000000000000000000ff99")
    text = mod.assistant_text([keep, other], TRACE)
    assert "keep.cs" in text and "other.cs" not in text


def test_files_actually_read_parses_windows(mod):
    spans = [make_tool_span("repo/Game/Formulas.cs", 75, 20)]
    got = mod.files_actually_read(spans)
    assert got["repo/Game/Formulas.cs"] == [(75, 94)]


# --------------------------------------------------------------------- 判决
def test_pass_when_citation_confirmed(mod, monkeypatch):
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["`MaxEncumbrance` 在 Game/Formulas.cs:7 计算负重上限。"]),
             make_tool_span("Game/Formulas.cs", 1, 200)]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Pass"
    assert out["value"] == 1.0


def test_fail_when_line_out_of_range(mod, monkeypatch):
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["`MaxEncumbrance` 在 Game/Formulas.cs:999。"])]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Fail"
    assert out["value"] == 0.0
    assert "line_out_of_range" in out["explanation"]


def test_fail_when_symbol_absent_at_cited_line(mod, monkeypatch):
    """文件在、行号在，但那一行跟结论无关——这是本评估器存在的主要理由。"""
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["`MaxEncumbrance` 在 Game/Formulas.cs:1。"])]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Fail"
    assert "symbol_mismatch" in out["explanation"]


def test_no_citations_is_a_label_not_an_error(mod, monkeypatch):
    """澄清型/诚实否认型回答本就可能不引代码。判 label 才会进统计；判 errorCode 会被当成评估器坏了。"""
    stub_bridge(mod, monkeypatch, {})
    spans = [make_llm_span(["仓库里没有与「跳跃高度」对应的实现，我没有找到相关代码。"])]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "NoCitations"
    assert not out.get("errorCode")


# --------------------------------------------------------------------- 不得空洞通过
def test_unverified_when_nothing_could_be_checked(mod, monkeypatch):
    """出处都没带行号：没有查出问题，但也一条都没核对上。绝不能报 Pass。"""
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["实现在 Game/Formulas.cs 里。"])]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Unverified"
    assert out["value"] is None


def test_bridge_failure_is_error_not_fail(mod, monkeypatch):
    """一次基础设施故障若被判成 Fail，就会在评估数据里留下一条永久且错误的「引用不成立」。

    这条测试抓到过真实缺陷：READ_ERROR 原本属于 FAILING，于是 bridge 不可达时每条出处都变成
    READ_ERROR、整份报告判 Fail。判据原则是 FAILING 只放**对答案下判断**的判决。
    """
    stub_bridge(mod, monkeypatch, {}, fail="无法连接 bridge http://bridge.invalid:8080/mcp: timed out")
    spans = [make_llm_span(["`MaxEncumbrance` 见 Game/Formulas.cs:7。"])]
    out = mod.lambda_handler(event(spans))
    assert out.get("errorCode") == "BRIDGE_UNREACHABLE"
    assert out.get("label") != "Fail"
    # 钉住的 SDK 1.14.1 里 label 必填，所以错误响应也带 label；取值必须是明确的非评分值，
    # 这样即使服务端把它当成有效结果，统计里也一眼看得出是评估器出错而非答案有问题。
    assert out.get("label") == "EvaluatorError"


def test_mid_run_read_failure_is_error_not_fail(mod, monkeypatch):
    """握手成功、读取途中失败（bridge 重启 / 某个仓库正在重建索引）：校验没能完成，
    不能拿剩下的结论去评分，那份评分是不完整的。"""

    class FlakyClient:
        def __init__(self, url, **kw):
            pass

        def initialize(self):
            return None

        def read_file(self, path, **kw):
            raise mod.BridgeError("connection reset by peer")

    monkeypatch.setattr(mod, "BridgeClient", FlakyClient)
    spans = [make_llm_span(["`MaxEncumbrance` 见 Game/Formulas.cs:7。"])]
    out = mod.lambda_handler(event(spans))
    assert out["errorCode"] == "BRIDGE_READ_FAILED"
    assert out["label"] != "Fail"


def test_missing_bridge_url_is_config_error(monkeypatch):
    monkeypatch.delenv("BRIDGE_URL", raising=False)
    import lambda_function as lf

    importlib.reload(lf)
    out = lf.lambda_handler(event([make_llm_span(["见 a/b.cs:1"])]))
    assert out["errorCode"] == "CONFIG_MISSING"
    assert out["label"] == "EvaluatorError"


def test_no_answer_text_is_error(mod, monkeypatch):
    """埋点没生效或载荷被 6MB 截断时 span 里没有 assistant 文本。这是评估器拿不到输入，
    不是答案的问题——必须报 errorCode，否则会被统计成一次真实的评估结果。"""
    stub_bridge(mod, monkeypatch, {})
    tool_only = [make_tool_span("Game/Formulas.cs", 1, 20)]
    out = mod.lambda_handler(event(tool_only))
    assert out["errorCode"] == "NO_ANSWER_TEXT"
    assert out["label"] == "EvaluatorError"


def test_empty_spans_is_error(mod):
    out = mod.lambda_handler(event([]))
    assert out["errorCode"] == "NO_SPANS"
    assert out["label"] == "EvaluatorError"


# --------------------------------------------------------------------- 不得误报
def test_file_never_read_is_not_a_failure(mod, monkeypatch):
    """search_files 的结果不在 span 里，所以出处完全可能来自搜索而非 read_file。
    把「没被 read_file 读过」判成失败会制造大量假失败，让整批评估数据失去意义。"""
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["`MaxEncumbrance` 见 Game/Formulas.cs:7。"])]  # 没有任何 read_file span
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Pass"
    assert "未出现在 read_file 调用中" in out["explanation"], "应作为参考信息写进 explanation"


def test_dotted_symbol_does_not_become_a_missing_file(mod, monkeypatch):
    """`FormulaHelper.CalculateMaxEncumbrance` 曾被当成文件 `FormulaHelper.C`。
    C#/Java 回答里「命名空间.类名」极常见，这个假阳性会把正常答案判成 Fail。"""
    stub_bridge(mod, monkeypatch, {"Game/Formulas.cs": SRC_LINES})
    spans = [make_llm_span(["`FormulaHelper.MaxEncumbrance` 见 Game/Formulas.cs:7。"])]
    out = mod.lambda_handler(event(spans))
    assert out["label"] == "Pass", out.get("explanation")
