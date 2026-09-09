"""apply_evaluators.py 的评委模型区域解析——纯函数 + 一个假的 ListInferenceProfiles。

为什么放在这里而不是 scripts/tests/：那边由 test.sh 当 shell 测试跑，pytest 不会发现它；
本目录已经在 test.sh 的 Python 测试目录清单里。
"""

from __future__ import annotations

import json
import os
import sys

import pytest

pytest.importorskip("boto3", reason="apply_evaluators.py 顶层 import boto3")

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.abspath(os.path.join(HERE, "..", "..", "..", "scripts", "lib"))
if LIB not in sys.path:
    sys.path.insert(0, LIB)

import apply_evaluators as ae  # noqa: E402

HAIKU = "anthropic.claude-haiku-4-5-20251001-v1:0"


@pytest.mark.parametrize("given", [
    f"jp.{HAIKU}", f"us.{HAIKU}", f"eu.{HAIKU}", f"au.{HAIKU}", f"apac.{HAIKU}",
    f"global.{HAIKU}", HAIKU,
])
def test_basename_strips_any_geo_or_global_prefix(given):
    assert ae.judge_model_basename(given) == HAIKU


@pytest.mark.parametrize("given", [
    "amazon.nova-pro-v1:0", "meta.llama3-70b-instruct-v1:0", "mistral.mistral-large-2402-v1:0",
])
def test_basename_keeps_vendor_prefixes(given):
    # 厂商名不是地理前缀：amazon. / meta. / mistral. 必须原样保留（旧正则会剥掉任意 2–6 个字母）。
    assert ae.judge_model_basename(given) == given


def test_basename_strips_us_gov_prefix():
    assert ae.judge_model_basename(f"us-gov.{HAIKU}") == HAIKU


def test_rank_prefers_geo_over_global():
    got = ae.rank_judge_profiles(HAIKU, [f"global.{HAIKU}", f"us.{HAIKU}"])
    assert got == f"us.{HAIKU}"


def test_rank_falls_back_to_global():
    assert ae.rank_judge_profiles(HAIKU, [f"global.{HAIKU}", "us.anthropic.claude-sonnet-4-5-v1:0"]) \
        == f"global.{HAIKU}"


def test_rank_matches_only_same_model_suffix():
    # 不能跨模型匹配，也不能被更长的名字（含相同结尾之前的部分）骗到。
    assert ae.rank_judge_profiles(HAIKU, ["us.anthropic.claude-haiku-4-5-20251001-v2:0",
                                          "us.anthropic.claude-sonnet-4-5-20250929-v1:0"]) is None


class _FakeBedrock:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def get_paginator(self, operation):
        assert operation == "list_inference_profiles"
        fake = self

        class Pages:
            def paginate(self, **kwargs):
                for page in fake.pages:
                    fake.calls.append(kwargs)
                    yield {"inferenceProfileSummaries": [{"inferenceProfileId": p} for p in page]}

        return Pages()

    def list_inference_profiles(self, **kw):
        self.calls.append(kw)
        i = int(kw.get("nextToken") or 0)
        resp = {"inferenceProfileSummaries": [{"inferenceProfileId": p} for p in self.pages[i]]}
        if i + 1 < len(self.pages):
            resp["nextToken"] = str(i + 1)
        return resp


def test_resolve_paginates_and_picks_region_profile():
    fake = _FakeBedrock([
        ["global.anthropic.claude-sonnet-4-5-20250929-v1:0", f"global.{HAIKU}"],
        [f"eu.{HAIKU}", "eu.anthropic.claude-haiku-3-5-20241022-v1:0"],
    ])
    best, similar = ae.resolve_judge_model(fake, f"jp.{HAIKU}")
    assert best == f"eu.{HAIKU}"
    assert all(c["typeEquals"] == "SYSTEM_DEFINED" for c in fake.calls) and len(fake.calls) == 2
    # 报错时用的候选列表：同系列（haiku）都在，其它模型不在。
    assert f"global.{HAIKU}" in similar and "eu.anthropic.claude-haiku-3-5-20241022-v1:0" in similar
    assert not any("sonnet" in s for s in similar)


def test_resolve_returns_none_when_region_lacks_model():
    fake = _FakeBedrock([["us.anthropic.claude-haiku-3-5-20241022-v1:0"]])
    best, similar = ae.resolve_judge_model(fake, HAIKU)
    assert best is None
    assert similar == ["us.anthropic.claude-haiku-3-5-20241022-v1:0"]


def test_build_config_uses_resolved_judge_model():
    spec = {"kind": "llmAsAJudge", "level": "TRACE", "modelId": HAIKU,
            "instructions": ["{context}", "{assistant_turn}"],
            "ratingScale": {"numerical": [{"value": 1, "label": "a", "definition": "b"}]}}
    cfg = ae.build_config(spec, "arn:x", f"us.{HAIKU}")
    assert cfg["llmAsAJudge"]["modelConfig"]["bedrockEvaluatorModelConfig"]["modelId"] == f"us.{HAIKU}"


class _FakeControl:
    """bedrock-agentcore-control 的最小假实现：没有已存在的评估器，create 一律记账。"""

    def __init__(self):
        self.created = []

    def list_evaluators(self, **kw):
        return {"evaluatorSummaries": []}

    def get_paginator(self, operation):
        fake = self

        class Pages:
            def paginate(self, **kwargs):
                return iter([getattr(fake, operation)(**kwargs)])

        return Pages()

    def create_evaluator(self, **kw):
        self.created.append(kw)
        return {"evaluatorId": "ev-1"}


def test_main_reports_missing_model_id_as_incomplete_definition(tmp_path, monkeypatch, capsys):
    # llmAsAJudge 定义漏写 modelId：应走「定义不完整」出口返回 1，而不是 KeyError 栈回溯，
    # 也不得去调 ListInferenceProfiles 或 CreateEvaluator。
    defs = tmp_path / "evaluators.json"
    defs.write_text(json.dumps({"evaluators": [{
        "key": "judge", "evaluatorName": "st-judge", "kind": "llmAsAJudge", "level": "TRACE",
        "instructions": ["{context}"],
        "ratingScale": {"numerical": [{"value": 1, "label": "a", "definition": "b"}]},
    }]}), encoding="utf-8")
    control = _FakeControl()
    touched = []

    def fake_client(service, region_name=None):
        touched.append(service)
        if service == "bedrock-agentcore-control":
            return control
        raise AssertionError(f"unexpected client: {service}")

    monkeypatch.setattr(ae.boto3, "client", fake_client)
    monkeypatch.setattr(sys, "argv", ["apply_evaluators", "--region", "us-east-1",
                                      "--defs", str(defs), "--lambda-arn", "arn:x"])
    rc = ae.main()
    err = capsys.readouterr().err
    assert rc == 1
    assert "定义不完整" in err and "modelId" in err and "st-judge" in err
    assert touched == ["bedrock-agentcore-control"] and control.created == []


def test_each_judge_resolves_its_own_model_before_any_create(tmp_path, monkeypatch):
    other = "anthropic.claude-sonnet-4-5-20250929-v1:0"
    specs = [
        {"key": str(i), "evaluatorName": f"judge{i}", "kind": "llmAsAJudge", "level": "TRACE",
         "modelId": model, "instructions": "{context}",
         "ratingScale": {"numerical": [{"value": 1, "label": "yes", "definition": "valid"}]}}
        for i, model in enumerate([HAIKU, other])
    ]
    defs = tmp_path / "evaluators.json"
    defs.write_text(json.dumps({"evaluators": specs}))
    control = _FakeControl()
    bedrock = _FakeBedrock([[f"us.{HAIKU}", f"us.{other}"]])
    monkeypatch.setattr(ae.boto3, "client", lambda name, **_: control if name.endswith("control") else bedrock)
    monkeypatch.setattr(sys, "argv", ["evaluators", "--region", "us-east-1",
                                     "--defs", str(defs), "--lambda-arn", "arn:x"])
    assert ae.main() == 0
    actual = [c["evaluatorConfig"]["llmAsAJudge"]["modelConfig"]["bedrockEvaluatorModelConfig"]["modelId"]
              for c in control.created]
    assert actual == [f"us.{HAIKU}", f"us.{other}"]


def test_duplicate_names_fail_before_creating_either_evaluator(tmp_path, monkeypatch):
    defs = tmp_path / "evaluators.json"
    defs.write_text(json.dumps({"evaluators": [
        {"key": key, "evaluatorName": "same", "kind": "codeBased", "level": "TRACE"}
        for key in ["first", "second"]
    ]}))
    control = _FakeControl()
    monkeypatch.setattr(ae.boto3, "client", lambda *a, **kw: control)
    monkeypatch.setattr(sys, "argv", ["evaluators", "--region", "us-east-1",
                                     "--defs", str(defs), "--lambda-arn", "arn:x"])
    assert ae.main() == 1
    assert control.created == []


class _PaginatedControl(_FakeControl):
    def __init__(self, pages):
        super().__init__()
        self.pages = pages

    def get_paginator(self, operation):
        assert operation == "list_evaluators"
        pages = self.pages

        class Pages:
            def paginate(self):
                return iter({"evaluatorSummaries": page} for page in pages)

        return Pages()


@pytest.mark.parametrize("existing_id", [None, "ev-existing"])
def test_unrelated_existing_duplicates_do_not_block_requested_evaluator(
    tmp_path, monkeypatch, capsys, existing_id,
):
    name = "SourceTruthCitationAccuracy"
    pages = [
        [{"evaluatorName": "OtherApplicationJudge", "evaluatorId": "other-1"}],
        [{"evaluatorName": "OtherApplicationJudge", "evaluatorId": "other-2"}],
    ]
    if existing_id:
        for page in pages:
            page.append({"evaluatorName": name, "evaluatorId": existing_id})
    control = _PaginatedControl(pages)
    defs = tmp_path / "evaluators.json"
    defs.write_text(json.dumps({"evaluators": [
        {"key": "citation", "evaluatorName": name, "kind": "codeBased", "level": "TRACE"},
    ]}))

    def fake_client(service, **kwargs):
        assert service == "bedrock-agentcore-control"
        return control

    monkeypatch.setattr(ae.boto3, "client", fake_client)
    monkeypatch.setattr(sys, "argv", ["evaluators", "--region", "ap-northeast-1",
                                     "--defs", str(defs), "--lambda-arn", "arn:x"])
    assert ae.main() == 0
    assert [item["evaluatorName"] for item in control.created] == ([] if existing_id else [name])
    assert f"EVALUATOR_ID citation {existing_id or 'ev-1'}" in capsys.readouterr().out


def test_requested_existing_duplicates_still_fail_before_any_create(tmp_path, monkeypatch, capsys):
    name = "SourceTruthCitationAccuracy"
    control = _PaginatedControl([
        [{"evaluatorName": name, "evaluatorId": "citation-1"}],
        [{"evaluatorName": name, "evaluatorId": "citation-2"}],
    ])
    defs = tmp_path / "evaluators.json"
    defs.write_text(json.dumps({"evaluators": [
        {"key": "new", "evaluatorName": "SourceTruthNew", "kind": "codeBased", "level": "TRACE"},
        {"key": "citation", "evaluatorName": name, "kind": "codeBased", "level": "TRACE"},
    ]}))
    monkeypatch.setattr(ae.boto3, "client", lambda *args, **kwargs: control)
    monkeypatch.setattr(sys, "argv", ["evaluators", "--region", "ap-northeast-1",
                                     "--defs", str(defs), "--lambda-arn", "arn:x"])
    assert ae.main() == 1
    assert control.created == []
    assert name in capsys.readouterr().err
