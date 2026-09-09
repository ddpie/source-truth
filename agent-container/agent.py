#!/usr/bin/env python3
"""source-truth agent container entrypoint (thin shell).

Runs inside the AgentCore Firecracker microVM. All testable logic lives in
``engine_runner``; this module only wires it into the
``@app.entrypoint`` async streaming handler. Keep it thin.

Payload contract: ``{"prompt": <question text>, "traceId": <joins both-side logs>,
"repos": <optional project repo list>}`` (injected by bot-gateway; the
runtimeSessionId travels in the AgentCore header, not the payload). The agent
depends only on ``prompt``.
"""

from __future__ import annotations

import logging
from contextlib import aclosing

from bedrock_agentcore.runtime import BedrockAgentCoreApp

import engine_runner

# Configure logging so the agent's structured perf lines (agent_lib's
# logging.getLogger("agent") → agent_run_total / agent_first_message /
# agent_result / tool_latency, plus codegraph_warmup/codegraph_call from the
# index side when co-located) actually reach stdout → CloudWatch. WITHOUT this,
# Python's default root level is WARNING with no handler, so every INFO perf line
# was silently dropped — which is why per-tool latency never showed up in the
# logs and #2's "evaluate latency from logs" was impossible. Idempotent: force=True
# so re-import in tests doesn't stack handlers; level=INFO captures the perf lines.
logging.basicConfig(level=logging.INFO, format="%(message)s", force=True)
logging.getLogger("agent").setLevel(logging.INFO)

app = BedrockAgentCoreApp()


@app.entrypoint
async def run_main(payload):
    """Stream messages from the read-only Q&A agent loop back to the gateway."""
    async with aclosing(engine_runner.run_agent(payload)) as messages:
        async for message in messages:
            yield message


if __name__ == "__main__":
    app.run()
