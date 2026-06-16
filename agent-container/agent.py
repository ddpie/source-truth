#!/usr/bin/env python3
"""source-truth agent container entrypoint (thin shell).

Runs inside the AgentCore Firecracker microVM. All testable logic lives in
``agent_lib`` (see agent_lib.run_agent); this module only wires it into the
``@app.entrypoint`` async streaming handler. Keep it thin.

Payload contract: ``{"prompt": <question text>, "session": <opaque context>}``
(injected by bot-gateway). The agent depends only on ``prompt``.
"""

from __future__ import annotations

from bedrock_agentcore.runtime import BedrockAgentCoreApp

import agent_lib

app = BedrockAgentCoreApp()


@app.entrypoint
async def run_main(payload):
    """Stream messages from the read-only Q&A agent loop back to the gateway."""
    async for message in agent_lib.run_agent(payload):
        yield message


if __name__ == "__main__":
    app.run()
