"""Exercise deployment convergence without touching AWS."""

import copy
import sys
from pathlib import Path

import pytest
from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts/lib"))
import apply_online_eval as online  # noqa: E402

RUNTIME = {"agentRuntimeName": "source_truth_agent_demo", "agentRuntimeId": "runtime-a"}
ROLE = "arn:aws:iam::123456789012:role/evaluation"


def configured(runtime=RUNTIME):
    return {
        "executionStatus": "ENABLED", "rule": online.rule_for(20),
        "dataSourceConfig": online.data_source(runtime["agentRuntimeName"], runtime["agentRuntimeId"]),
        "evaluators": [{"evaluatorId": "Builtin.Faithfulness"}],
        "evaluationExecutionRoleArn": ROLE,
    }


class Control:
    def __init__(self, details=None, name=None):
        self.runtimes = [RUNTIME]
        self.name = name or online.config_name(*RUNTIME.values())
        self.details = configured() if details is None else details
        self.updated, self.created, self.reads = [], [], []

    def get_evaluator(self, **_):
        return {"evaluatorConfig": {}}

    def get_paginator(self, operation):
        control = self

        class Pages:
            def paginate(self, **kwargs):
                return iter([getattr(control, operation)(**kwargs)])

        return Pages()

    def list_agent_runtimes(self, **_):
        return {"agentRuntimes": self.runtimes}

    def list_online_evaluation_configs(self, **_):
        return {"onlineEvaluationConfigs": [{
            "onlineEvaluationConfigName": self.name,
            "onlineEvaluationConfigId": "existing", "executionStatus": "ENABLED",
        }]}

    def get_online_evaluation_config(self, **kwargs):
        self.reads.append(kwargs)
        if isinstance(self.details, Exception):
            raise self.details
        return copy.deepcopy(self.details)

    def update_online_evaluation_config(self, **kwargs):
        self.updated.append(kwargs)
        return {}

    def create_online_evaluation_config(self, **kwargs):
        self.created.append(kwargs)
        return {"onlineEvaluationConfigId": "created"}


def invoke(monkeypatch, control, flags=None, evaluator_ids="Builtin.Faithfulness"):
    monkeypatch.setattr(online.boto3, "client", lambda *a, **kw: control)
    monkeypatch.setattr(sys, "argv", [
        "online", "--region", "ap-northeast-1", "--evaluator-ids", evaluator_ids,
        "--role-arn", ROLE, *(["--enable", "--sampling", "20"] if flags is None else flags),
    ])
    return online.main()


@pytest.mark.parametrize("drift", ["none", "sampling", "evaluators", "session", "role"])
def test_converges_existing_config(monkeypatch, drift):
    state = configured()
    if drift == "sampling":
        state["rule"]["samplingConfig"]["samplingPercentage"] = 100
    elif drift == "evaluators":
        state["evaluators"] = []
    elif drift == "session":
        state["rule"].pop("sessionConfig")
    elif drift == "role":
        state["evaluationExecutionRoleArn"] = "previous-role"
    control = Control(state)
    assert invoke(monkeypatch, control) == 0
    assert len(control.updated) == (0 if drift == "none" else 1)
    assert not control.created and len(control.reads) == 1
    if control.updated:
        assert control.updated[0]["rule"] == online.rule_for(20)
        assert control.updated[0]["evaluators"] == [{"evaluatorId": "Builtin.Faithfulness"}]


def test_unreadable_config_does_not_report_success_or_mutate(monkeypatch):
    error = ClientError({"Error": {"Code": "AccessDeniedException"}}, "GetOnlineEvaluationConfig")
    control = Control(error)
    assert invoke(monkeypatch, control) == 1
    assert not control.created and not control.updated


def test_evaluator_read_failure_stops_before_mutating_configs(monkeypatch):
    control = Control()

    def denied(**_):
        raise ClientError({"Error": {"Code": "AccessDeniedException"}}, "GetEvaluator")

    monkeypatch.setattr(control, "get_evaluator", denied)
    assert invoke(monkeypatch, control) == 1
    assert not control.created and not control.updated and not control.reads


def test_omitted_options_preserve_existing_enabled_sampling_and_rule(monkeypatch):
    state = configured()
    state["rule"]["sessionConfig"]["sessionTimeoutMinutes"] = 45
    state["rule"]["filters"] = [{"key": "environment", "operator": "Equals", "value": "production"}]
    control = Control(state)
    assert invoke(monkeypatch, control, flags=[]) == 0
    assert not control.created and not control.updated


def test_explicit_disable_and_sampling_preserve_custom_rule(monkeypatch):
    state = configured()
    state["rule"]["filters"] = [{"key": "environment", "operator": "Equals", "value": "production"}]
    control = Control(state)
    assert invoke(monkeypatch, control, flags=["--disable", "--sampling", "5"]) == 0
    assert control.updated[0]["executionStatus"] == "DISABLED"
    assert control.updated[0]["rule"]["samplingConfig"]["samplingPercentage"] == 5
    assert control.updated[0]["rule"]["filters"] == state["rule"]["filters"]


def test_invalid_id_does_not_silently_drop_a_configured_evaluator(monkeypatch):
    control = Control()
    assert invoke(monkeypatch, control, evaluator_ids="Builtin.Faithfulness;broken") == 1
    assert not control.updated and not control.created


def test_similarly_named_foreign_runtime_is_not_selected(monkeypatch):
    control = Control()
    control.runtimes = [{"agentRuntimeName": "source_truth_agents_other", "agentRuntimeId": "other"}]
    assert invoke(monkeypatch, control) == 1
    assert not control.updated and not control.created

def test_legacy_name_collision_does_not_reuse_another_runtime(monkeypatch):
    first = {"agentRuntimeName": "source_truth_agent_" + "a" * 40 + "first", "agentRuntimeId": "first"}
    second = {"agentRuntimeName": "source_truth_agent_" + "a" * 40 + "second", "agentRuntimeId": "second"}
    legacy = online.legacy_config_name(first["agentRuntimeName"])
    assert legacy == online.legacy_config_name(second["agentRuntimeName"])
    control = Control(configured(first), legacy)
    control.runtimes = [first, second]
    assert invoke(monkeypatch, control) == 0
    assert not control.updated and len(control.created) == 1
    assert control.created[0]["dataSourceConfig"] == configured(second)["dataSourceConfig"]
    assert control.created[0]["onlineEvaluationConfigName"] == online.config_name(*second.values())


@pytest.mark.parametrize("message,created,retry", [
    ("The role cannot be assumed", True, True),
    ("The role cannot be assumed", False, False),
    ("Not authorized to perform CreateOnlineEvaluationConfig", True, False),
])
def test_only_new_role_propagation_errors_retry(monkeypatch, message, created, retry):
    calls, waits = [], []

    class Flaky:
        def create_online_evaluation_config(self, **kwargs):
            calls.append(kwargs)
            if len(calls) == 1:
                raise ClientError({"Error": {"Code": "ValidationException", "Message": message}}, "Create")
            return {"ok": True}

    monkeypatch.setattr(online.time, "sleep", waits.append)
    if retry:
        assert online.create_with_role_retry(Flaky(), {}, role_just_created=created) == {"ok": True}
        assert len(calls) == 2 and len(waits) == 1
    else:
        with pytest.raises(ClientError):
            online.create_with_role_retry(Flaky(), {}, role_just_created=created)
        assert len(calls) == 1 and not waits
