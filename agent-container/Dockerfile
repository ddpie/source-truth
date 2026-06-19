# syntax=docker/dockerfile:1
# agent-container — source-truth Claude Code Agent (ARM64-only, per AGENTS.md).
# Reference: amazon-bedrock-agentcore-samples claude-agent/claude-sdk/Dockerfile.
#
# Build (ARM64): docker build --platform linux/arm64 -t <ecr>/source-truth-agent:latest .
# Base image pinned by sha256 digest for reproducibility (resolved from the
# python3.11-bookworm-slim tag at the time of a verified ARM64 build). Bumping
# the digest is "Ask first" per AGENTS.md — re-resolve via `docker inspect`.
FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim@sha256:4f5d923c9dcea037f57bda425dd209f3ec643da2f0b74227f68d09dab0b3bb36

WORKDIR /app

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1 \
    AWS_REGION=us-east-1 \
    AWS_DEFAULT_REGION=us-east-1 \
    CLAUDE_CODE_USE_BEDROCK=1

# Python deps: install from the FULL transitive lock (requirements.lock) so every
# build is byte-identical. requirements.txt is the human-readable direct-dep
# intent; requirements.lock (pip freeze from a verified ARM64 build) is what's
# actually installed. Regenerate the lock when changing requirements.txt.
COPY requirements.txt requirements.lock ./
RUN uv pip install --no-deps -r requirements.lock

# Node + claude-code CLI — REQUIRED: claude_agent_sdk spawns the `claude` CLI
# (the @anthropic-ai/claude-code npm package) as a subprocess via its
# SubprocessCLITransport. claude-code tracks @latest by OPERATOR CHOICE (set
# 2026-06-19): we always build with the newest CLI to pick up upstream fixes
# fastest. TRADEOFF: this gives up reproducible builds — the same Dockerfile can
# produce different CLI versions over time, and an upstream regression lands on
# the next build with no buffer. Pin back to an exact @<version> if a build
# regresses. Node is pinned to the major (setup_24.x), NOT an exact patch on
# purpose: NodeSource prunes old patch debs from its apt repo, so `nodejs=24.16.0`
# would make the build FAIL once that patch is GC'd.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g @anthropic-ai/claude-code@latest && \
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
