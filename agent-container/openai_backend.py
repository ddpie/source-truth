"""Bedrock Converse transport. No API key or OpenAI-hosted trace export."""

from __future__ import annotations


def create_model(model: str, region: str):
    from bedrock_converse import BedrockConverseModel

    return BedrockConverseModel(model, region)


def model_settings():
    from agents import ModelSettings

    return ModelSettings(parallel_tool_calls=False)


def instrument() -> None:
    from openinference.instrumentation.openai_agents import OpenAIAgentsInstrumentor

    # Replaces the SDK's default exporter while retaining AgentCore evaluation spans.
    instrumentor = OpenAIAgentsInstrumentor()
    if not instrumentor.is_instrumented_by_opentelemetry:
        instrumentor.instrument(exclusive_processor=True)
