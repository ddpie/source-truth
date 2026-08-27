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

# NO AWS_REGION / AWS_DEFAULT_REGION baked in. They used to default to us-east-1, which meant any
# code path reading the region from env silently talked to us-east-1 from, say, a us-west-2 deploy.
# The region now comes from the runtime environment only: deploy_runtime.py sets AWS_REGION and
# AWS_DEFAULT_REGION on the AgentCore runtime from the deploy region (always, not conditionally),
# so the deployed path is unaffected. A local `docker run` must pass -e AWS_REGION=<region>;
# without it boto3 fails loudly with NoRegionError, which is the intended behaviour — a wrong
# region that "works" is worse than a missing one that stops.
# UV_COMPILE_BYTECODE stays on: this image cold-starts inside an AgentCore microVM where import
# time is user-visible latency, which is worth the .pyc footprint.
ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1 \
    CLAUDE_CODE_USE_BEDROCK=1

# Python deps: install from the FULL transitive lock (requirements.lock) so every build installs
# the same VERSIONS. requirements.txt is the human-readable direct-dep intent; requirements.lock
# (pip freeze from a verified ARM64 build) is what's actually installed. Regenerate the lock when
# changing requirements.txt.
# NOT byte-identical, despite what this comment used to claim: the lock carries `==` pins but NO
# hashes, so a republished or yanked-and-replaced artifact changes the build silently. The fix is
# `uv pip compile --generate-hashes` + `--require-hashes`, which needs the lock regenerated —
# tracked separately (requirements.lock is not edited here).
COPY requirements.txt requirements.lock ./
RUN uv pip install --no-cache --no-deps -r requirements.lock

# Node + claude-code CLI — REQUIRED: claude_agent_sdk spawns the `claude` CLI
# (the @anthropic-ai/claude-code npm package) as a subprocess via its
# SubprocessCLITransport. claude-code tracks @latest by OPERATOR CHOICE (set
# 2026-06-19): we always build with the newest CLI to pick up upstream fixes
# fastest. TRADEOFF: this gives up reproducible builds — the same Dockerfile can
# produce different CLI versions over time, and an upstream regression lands on
# the next build with no buffer. Pin back to an exact @<version> if a build
# regresses. Node is pinned to the major (nodistro node_24.x), NOT an exact patch on
# purpose: NodeSource prunes old patch debs from its apt repo, so `nodejs=24.16.0`
# would make the build FAIL once that patch is GC'd.
#
# The NodeSource apt repo is configured EXPLICITLY (keyring + sources.list entry) instead of
# `curl … setup_24.x | bash -`: that pipe ran a remote script as root at build time, giving the
# script author arbitrary control over the image — a supply-chain exposure the @latest CLI decision
# does not cover. apt verifies the repo signature against the pinned key file (armored keys are
# supported directly via signed-by when the file ends in .asc, so no gnupg is needed).
# The resolved toolchain versions are recorded in the image so a later regression can be bisected.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      -o /etc/apt/keyrings/nodesource.asc && \
    chmod 0644 /etc/apt/keyrings/nodesource.asc && \
    echo 'deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_24.x nodistro main' \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g @anthropic-ai/claude-code@latest && \
    npm cache clean --force && \
    { echo "node=$(node -v)"; echo "npm=$(npm -v)"; \
      echo "claude=$(claude --version 2>/dev/null || echo unknown)"; } > /app/.toolchain-versions && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root (AgentCore runs containers as non-root).
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

# PORT: BedrockAgentCoreApp.run() binds 8080 locally. The AgentCore Runtime's internal port is
# NOT verified from this repo (an earlier comment here said 9000; nothing in the codebase confirms
# either number), and EXPOSE is documentation-only, so nothing depends on getting it right — but do
# not treat this line as authoritative for the runtime.
EXPOSE 8080

COPY . .

# NO HEALTHCHECK. The previous one (`test -f agent.py`) asserted that a file baked in at build time
# still exists: it could only fail if the container filesystem were destroyed, said nothing about
# whether the app was listening or Bedrock reachable, and cost a process spawn every 30s forever —
# while displaying a reassuring `healthy` in `docker ps`. AgentCore Runtime does not honor Docker
# HEALTHCHECK at all, so it bought nothing there either. The real liveness surface is the app's HTTP
# endpoint; probe that from outside when running locally (curl the /ping path on the published port)
# rather than re-adding a check that cannot fail.

# Thin @app.entrypoint shell; BedrockAgentCoreApp.run() serves the runtime.
#
# Launched through `opentelemetry-instrument` because that is what actually turns AgentCore
# Observability on. `aws-opentelemetry-distro` had been a pinned dependency for a long time with the
# note "observability (toolkit default)", but nothing ever activated it: the package was installed
# into the image and never used, so no spans were produced, the account had no `aws/spans` log group,
# and each runtime's log group carried only platform events such as image-pull failures. Installing
# ADOT is not integrating it — the auto-instrumentation wrapper is the integration, per the AgentCore
# docs for agents HOSTED IN the runtime ("For containerized environment add the following command:
# CMD ["opentelemetry-instrument", "python", "main.py"]").
#
# Nothing else is set here on purpose. For an AgentCore-hosted agent the runtime injects the ADOT
# environment itself (which is why an escape hatch named DISABLE_ADOT_OBSERVABILITY exists); the long
# list of OTEL_* / AGENT_OBSERVABILITY_ENABLED variables in the docs applies to agents hosted OUTSIDE
# AgentCore, and setting them here would fight the platform rather than help it.
#
# The pin is >=0.18.0 (0.19.0) for a second reason: earlier versions IGNORE the span-destination
# setting and always deliver to the shared `aws/spans` log group. 0.18.0+ is what makes it possible
# to send spans to each agent's own log group, which is the isolation this project's layout wants —
# one host serving six projects, each already with its own log group. Turning that on additionally
# needs UNIFIED_TRACES_DESTINATION_ENABLED=true plus logs:PutResourcePolicy for the execution role;
# deliberately NOT done here, so this change stays reviewable on its own.
CMD ["opentelemetry-instrument", "python", "agent.py"]
