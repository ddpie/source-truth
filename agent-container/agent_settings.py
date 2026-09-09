"""Deployment-owned SDK selection, shared by runtime and deployment tooling."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Mapping

DEFAULT_MODELS = {
    "openai": "global.openai.gpt-6-astra",
    "claude": "global.anthropic.claude-opus-4-8",
}


@dataclass(frozen=True)
class AgentSettings:
    sdk: str
    model: str
    glossary_model: str
    max_turns: int = 60

    def __post_init__(self) -> None:
        if self.sdk not in DEFAULT_MODELS:
            raise ValueError("agent.sdk must be openai or claude")
        for model in (self.model, self.glossary_model):
            family = "openai." if self.sdk == "openai" else "anthropic."
            if not re.fullmatch(r"[A-Za-z0-9:/._-]+", model) or family not in model:
                raise ValueError(f"{self.sdk} requires a {family} Bedrock model/profile")
        if isinstance(self.max_turns, bool) or not isinstance(self.max_turns, int) or self.max_turns < 1:
            raise ValueError("agent.maxTurns must be a positive integer")


def project_settings(project: dict, *, schema_version: int = 1, legacy_model: str = "") -> AgentSettings:
    """Absent selection in legacy files preserves Claude; v2 defaults to OpenAI."""
    agent = project.get("agent", {})
    if not isinstance(agent, dict):
        raise ValueError("project.agent must be an object")
    sdk = agent.get("sdk", "openai" if schema_version == 2 else "claude")
    if sdk not in DEFAULT_MODELS:
        raise ValueError("agent.sdk must be openai or claude")
    if agent.get("provider", "bedrock") != "bedrock" or agent.get("endpoint", "runtime") != "runtime":
        raise ValueError("this deployment supports Bedrock Runtime only")
    fallback = project.get("model") or legacy_model if sdk == "claude" else ""
    model = agent.get("model") or fallback or DEFAULT_MODELS[sdk]
    return AgentSettings(sdk, model, agent.get("glossaryModel") or model, agent.get("maxTurns", 60))


def deployment_models(config: dict, *, legacy_model: str = "", glossary: bool = False) -> list[str]:
    """Probe exactly the models selected by projects, once per distinct model."""
    models: dict[str, None] = {}
    for project in config.get("projects", {}).values():
        settings = project_settings(
            project, schema_version=config.get("schemaVersion", 1), legacy_model=legacy_model
        )
        models[settings.model] = None
        if glossary:
            models[settings.glossary_model] = None
    return list(models)


def runtime_settings(env: Mapping[str, str] | None = None) -> AgentSettings:
    env = os.environ if env is None else env
    # Old Runtime definitions explicitly carry ANTHROPIC_MODEL; keep their behavior
    # across a shared image upgrade. New deploys always write AGENT_SDK.
    sdk = env.get("AGENT_SDK") or ("claude" if env.get("ANTHROPIC_MODEL") else "openai")
    model = env.get("AGENT_MODEL") or (
        env.get("ANTHROPIC_MODEL") if sdk == "claude" else None
    ) or DEFAULT_MODELS.get(sdk, "")
    return AgentSettings(sdk, model, model, int(env.get("AGENT_MAX_TURNS", "60")))
