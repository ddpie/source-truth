"""Offline runtime update safety checks; clients are substitutes, never AWS."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "lib/deploy_runtime.py"
spec = importlib.util.spec_from_file_location("deploy_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class Client:
    def __init__(self):
        self.updated = None
        self.read_error = False

    def list_agent_runtimes(self, **_kwargs):
        return {"agentRuntimes": [{"agentRuntimeName": "demo", "agentRuntimeId": "existing"}]}

    def get_agent_runtime(self, **_kwargs):
        if self.read_error:
            raise RuntimeError("cannot read current runtime")
        return {
            "status": "READY", "agentRuntimeArn": "arn:runtime",
            "environmentVariables": {
                "OTEL_BSP_EXPORT_TIMEOUT": "30000", "AGENT_SDK": "claude",
                "ANTHROPIC_MODEL": "global.anthropic.claude-opus-4-8",
                "CLAUDE_CODE_USE_BEDROCK": "1",
                "CLAUDE_CODE_USE_VERTEX": "1", "OPENAI_BASE_URL": "https://old-endpoint.invalid",
            },
        }

    def update_agent_runtime(self, **kwargs):
        self.updated = kwargs


class RuntimeSafetyTests(unittest.TestCase):
    def deploy(self, client, **kwargs):
        with patch.object(runtime.boto3, "client", return_value=client), \
                patch.object(runtime.time, "sleep"):
            return runtime.deploy(
                region="ap-northeast-1", role_arn="role", image="image", name="demo",
                model="global.openai.gpt-6-astra", **kwargs,
            )

    def test_update_preserves_operational_environment_and_removes_old_sdk_settings(self):
        client = Client()
        self.deploy(client)
        env = client.updated["environmentVariables"]
        self.assertEqual(env["OTEL_BSP_EXPORT_TIMEOUT"], "30000")
        self.assertEqual(env["AGENT_SDK"], "openai")
        self.assertNotIn("ANTHROPIC_MODEL", env)
        self.assertNotIn("CLAUDE_CODE_USE_BEDROCK", env)
        self.assertNotIn("CLAUDE_CODE_USE_VERTEX", env)
        self.assertNotIn("OPENAI_BASE_URL", env)

    def test_failed_configuration_read_must_not_update_runtime(self):
        client = Client()
        client.read_error = True
        with self.assertRaises(RuntimeError):
            self.deploy(client)
        self.assertIsNone(client.updated)

    def test_partial_vpc_and_invalid_lifecycle_fail_before_creating_client(self):
        for options in ({"subnets": ["subnet-1"]}, {"max_lifetime": 86400}, {"idle_timeout": 59}):
            with self.subTest(options=options), patch.object(runtime.boto3, "client") as factory:
                with self.assertRaises(ValueError):
                    runtime.deploy(region="ap-northeast-1", role_arn="role", image="image",
                                   name="demo", model="global.openai.gpt-6-astra", **options)
                factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
