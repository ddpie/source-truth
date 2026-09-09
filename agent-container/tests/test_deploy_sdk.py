"""Deployment API contract: explicit SDK selection reaches the Runtime environment."""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_settings import deployment_models  # noqa: E402

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/lib/deploy_runtime.py"
spec = importlib.util.spec_from_file_location("deploy_runtime", SCRIPT)
deploy_runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy_runtime)


@pytest.mark.parametrize("sdk,model", [
    ("openai", "us.openai.gpt-6-astra"),
    ("claude", "global.anthropic.claude-opus-4-8"),
])
def test_runtime_environment_follows_selection(monkeypatch, sdk, model):
    class Client:
        config = None

        def list_agent_runtimes(self, **kwargs):
            return {"agentRuntimes": [{"agentRuntimeName": "demo", "agentRuntimeId": "demo-id"}]}

        def update_agent_runtime(self, **kwargs):
            self.config = kwargs

        def get_agent_runtime(self, **kwargs):
            return {"status": "READY", "agentRuntimeArn": "runtime-arn"}

    client = Client()
    monkeypatch.setattr(deploy_runtime.boto3, "client", lambda *a, **kw: client)
    monkeypatch.setattr(deploy_runtime.time, "sleep", lambda _: None)
    assert deploy_runtime.deploy(region="us-east-2", role_arn="role", image="image", name="demo",
                                 model=model, sdk=sdk, agent_max_turns=8,
                                 codegraph_mcp_url="http://index:8080/mcp") == ("demo-id", "runtime-arn")
    env = client.config["environmentVariables"]
    assert env["AGENT_SDK"] == sdk and env["AGENT_MODEL"] == model
    assert env["AGENT_MAX_TURNS"] == "8"
    assert env["AWS_REGION"] == env["AWS_DEFAULT_REGION"] == "us-east-2"
    assert ("ANTHROPIC_MODEL" in env) == (sdk == "claude")
    assert env["CODEGRAPH_MCP_URL"] == "http://index:8080/mcp"


@pytest.mark.parametrize("selection,expected", [(0, "openai"), (1, "claude")])
def test_installer_menu_yields_valid_sdk(selection, expected):
    source = (SCRIPT.parents[1] / "install.sh").read_text()
    picker = re.search(r"^pick_field\(\) \{.*?^\}", source, re.M | re.S).group()
    options = re.search(r"^SDK_OPTIONS=\(.*?^\)", source, re.M | re.S).group()
    script = picker + "\n" + options + r'''
ASSUME_YES=false
MANUAL_SENTINEL=manual
index_of_token() { echo "$1_INDEX"; }
pick() {
  local target="$1" choice="$2"; shift 2
  local items=("$@")
  printf -v "$target" '%s' "${items[$choice]}"
}
'''
    # Stub only the keypress selection. The production field parser and labels run.
    script = script.replace('echo "$1_INDEX"', f"echo {selection}")
    script += '\npick_field selected "SDK" openai SDK "${SDK_OPTIONS[@]}"\nprintf "%s" "$selected"\n'
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    assert result.stdout.splitlines()[-1] == expected


def test_preflight_models_follow_both_sdk_selections_and_glossary_switch():
    config = {"schemaVersion": 2, "projects": {
        "default": {},
        "second_openai": {"agent": {"sdk": "openai", "glossaryModel": "global.openai.gpt-5.6-sol"}},
        "claude": {"agent": {"sdk": "claude", "model": "jp.anthropic.claude-opus-4-8"}},
    }}
    assert deployment_models(config) == [
        "global.openai.gpt-6-astra", "jp.anthropic.claude-opus-4-8",
    ]
    assert deployment_models(config, glossary=True) == [
        "global.openai.gpt-6-astra", "global.openai.gpt-5.6-sol", "jp.anthropic.claude-opus-4-8",
    ]


def test_preflight_preserves_legacy_model_and_rejects_mismatched_provider():
    assert deployment_models({"projects": {"legacy": {}}}, legacy_model="jp.anthropic.claude-opus-4-8") == [
        "jp.anthropic.claude-opus-4-8",
    ]
    assert deployment_models({}) == []
    with pytest.raises(ValueError, match="requires a openai"):
        deployment_models({"schemaVersion": 2, "projects": {
            "bad": {"agent": {"model": "global.anthropic.claude-opus-4-8"}},
        }})
