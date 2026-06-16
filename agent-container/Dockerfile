# syntax=docker/dockerfile:1
# agent-container — source-truth Claude Code Agent (ARM64-only, per AGENTS.md).
# Reference: amazon-bedrock-agentcore-samples claude-agent/claude-sdk/Dockerfile.
#
# Build (ARM64): docker build --platform linux/arm64 -t <ecr>/source-truth-agent:latest .
# The base image SHOULD be pinned by sha256 digest before production (TODO:
# resolve digest at deploy; AGENTS.md "Ask first" to bump base image version).
FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim

WORKDIR /app

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1 \
    AWS_REGION=us-east-1 \
    AWS_DEFAULT_REGION=us-east-1 \
    CLAUDE_CODE_USE_BEDROCK=1

# Python deps (exact-pinned where verified — see requirements.txt).
COPY requirements.txt requirements.txt
RUN uv pip install -r requirements.txt

# Node + claude-code CLI (claude_agent_sdk drives it as a subprocess).
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g @anthropic-ai/claude-code && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root (AgentCore runs containers as non-root).
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

# AgentCore Runtime listens on 9000 internally; local app.run() uses 8080.
EXPOSE 8080

COPY . .

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD test -f agent.py || exit 1

# Thin @app.entrypoint shell; BedrockAgentCoreApp.run() serves the runtime.
CMD ["python", "agent.py"]
