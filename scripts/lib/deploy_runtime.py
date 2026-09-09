#!/usr/bin/env python3
"""Idempotent AgentCore Runtime deploy for agent-container (boto3, no CDK).

Create-or-update the source-truth agent runtime from an already-built+pushed
ECR image. Idempotent: if a runtime with the same name exists, update it in
place (= upgrade); otherwise create. Waits for READY.

VPC-only, no EFS: the runtime joins the VPC to reach the in-VPC index-service
and mounts NO repo filesystem — all source is read over the index-service HTTP
bridge (read_file/glob_files/search_files/codegraph_*).

Verified against real AWS: created source_truth_agent-xC7N7O63iA (READY),
real InvokeAgentRuntime returned a real Bedrock answer.

Usage:
  python3 deploy_runtime.py --region us-east-1 --account <your-account-id> \
    --role-arn arn:...:role/SourceTruthAgentRuntimeRole \
    --image <acct>.dkr.ecr.<region>.amazonaws.com/source-truth/agent:latest \
    --sdk claude --model global.anthropic.claude-opus-4-8 [--name source_truth_agent]

Prints `AGENT_RUNTIME_ID=<id>` and `AGENT_RUNTIME_ARN=<arn>` on success.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import time

import boto3

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "agent-container"))
from agent_settings import AgentSettings  # noqa: E402


def find_existing(client, name: str) -> str | None:
    # ListAgentRuntimes is paginated (<=100/page); follow nextToken so an existing
    # same-named runtime past page 1 is still found. Missing it would wrongly take
    # the create branch and hard-fail with a name conflict, breaking the
    # update-in-place idempotency contract once an account holds >100 runtimes.
    token: str | None = None
    while True:
        kwargs = {"maxResults": 100}
        if token:
            kwargs["nextToken"] = token
        resp = client.list_agent_runtimes(**kwargs)
        for rt in resp.get("agentRuntimes", []):
            if rt.get("agentRuntimeName") == name:
                return rt["agentRuntimeId"]
        token = resp.get("nextToken")
        if not token:
            return None


def validate_options(
    sdk: str, model: str, agent_max_turns: int,
    subnets: list[str] | None, security_groups: list[str] | None,
    idle_timeout: int | None, max_lifetime: int | None,
) -> None:
    AgentSettings(sdk, model, model, agent_max_turns)
    if bool(subnets) != bool(security_groups):
        raise ValueError("--subnets and --security-groups must be provided together")
    if any(not item.strip() for item in (subnets or []) + (security_groups or [])):
        raise ValueError("subnets and security groups must not contain empty IDs")
    for flag, value in (("--idle-timeout", idle_timeout), ("--max-lifetime", max_lifetime)):
        if value is not None and (isinstance(value, bool) or not isinstance(value, int)
                                  or not 60 <= value <= 28800):
            raise ValueError(f"{flag} must be in 60..28800 seconds, got {value}")


def deploy(
    *,
    region: str,
    role_arn: str,
    image: str,
    name: str,
    model: str,
    sdk: str = "openai",
    agent_max_turns: int = 60,
    subnets: list[str] | None = None,
    security_groups: list[str] | None = None,
    codegraph_mcp_url: str | None = None,
    idle_timeout: int | None = None,
    max_lifetime: int | None = None,
) -> tuple[str, str]:
    validate_options(sdk, model, agent_max_turns, subnets, security_groups, idle_timeout, max_lifetime)
    client = boto3.client("bedrock-agentcore-control", region_name=region)
    artifact = {"containerConfiguration": {"containerUri": image}}
    # Pin the agent's Bedrock region to the DEPLOY region, overriding the image's
    # baked-in default (Dockerfile sets AWS_REGION=us-east-1). The default model is
    # a global.* inference profile (works from any regional endpoint), so this is
    # mainly correctness + lower cross-region latency — but it's REQUIRED if an
    # operator deploys with a region-pinned --model (apac.*/jp.*) where a us-east-1
    # endpoint would mismatch. Track --region so the runtime's region is never stale.
    env = {"AGENT_SDK": sdk, "AGENT_MODEL": model, "AGENT_MAX_TURNS": str(agent_max_turns),
           "AWS_REGION": region, "AWS_DEFAULT_REGION": region}
    if sdk == "claude":
        env.update(CLAUDE_CODE_USE_BEDROCK="1", ANTHROPIC_MODEL=model)
    # CodeGraph MCP endpoint (index-service). Only set when provided so a
    # PUBLIC-mode runtime without an index-service stays a plain agent.
    if codegraph_mcp_url:
        env["CODEGRAPH_MCP_URL"] = codegraph_mcp_url

    # Network: VPC mode if subnets provided (to reach the in-VPC index-service),
    # else PUBLIC. The runtime needs VPC egress to the index-service for code
    # access — there is NO EFS mount (all source is read over the HTTP bridge).
    if subnets and security_groups:
        net = {"networkMode": "VPC", "networkModeConfig": {
            "securityGroups": security_groups, "subnets": subnets,
        }}
    else:
        net = {"networkMode": "PUBLIC"}

    # Filesystem: session storage ONLY. The agent microVM mounts NO repo
    # filesystem — all code access goes over the index-service HTTP bridge
    # (read_file/glob_files/search_files/codegraph_*). EFS removed.
    fs: list[dict] = [{"sessionStorage": {"mountPath": "/mnt/workspace"}}]

    common = dict(
        roleArn=role_arn,
        networkConfiguration=net,
        agentRuntimeArtifact=artifact,
        filesystemConfigurations=fs,
        environmentVariables=env,
    )

    # Session lifecycle. We set this EXPLICITLY (rather than relying on AWS defaults)
    # so the warm-microVM idle window is a documented value the gateway's session-reuse
    # TTL is aligned to — not a guessed constant. Cost note: AgentCore bills CPU only
    # during active processing (idle CPU is free) but bills MEMORY for the whole session
    # lifetime, so a LONGER idle timeout = more idle memory cost with no CPU cost. The
    # default 900s (15min) matches AWS's own default and the gateway TTL; raise it only
    # if follow-up "stickiness" matters more than the idle-memory spend.
    #   idleRuntimeSessionTimeout: terminate a session idle this long (60..28800, default 900)
    #   maxLifetime: hard cap on a microVM's age before forced recycle (60..28800, default 28800)
    lifecycle: dict[str, int] = {}
    if idle_timeout is not None:
        lifecycle["idleRuntimeSessionTimeout"] = idle_timeout
    if max_lifetime is not None:
        lifecycle["maxLifetime"] = max_lifetime
    if lifecycle:
        common["lifecycleConfiguration"] = lifecycle

    existing = find_existing(client, name)
    if existing:
        current = client.get_agent_runtime(agentRuntimeId=existing)
        # Update replaces the environment map. Retain operational settings (for
        # example OTEL tuning), while replacing every SDK-owned key together so
        # a switch to OpenAI cannot inherit ANTHROPIC_MODEL from the old runtime.
        managed = {
            "AGENT_SDK", "AGENT_MODEL", "AGENT_MAX_TURNS", "AWS_REGION", "AWS_DEFAULT_REGION",
            "CODEGRAPH_MCP_URL", "CLAUDE_CODE_USE_BEDROCK", "ANTHROPIC_MODEL",
        }
        common["environmentVariables"] = {
            **{key: value for key, value in current.get("environmentVariables", {}).items()
               if key not in managed and not key.startswith(
                   ("ANTHROPIC_", "OPENAI_", "CLAUDE_CODE_", "CLAUDE_AGENT_")
               )},
            **env,
        }
        for key in ("description", "authorizerConfiguration", "requestHeaderConfiguration",
                    "protocolConfiguration", "metadataConfiguration", "lifecycleConfiguration"):
            if key not in common and key in current:
                common[key] = current[key]
        print(f"  updating existing runtime {existing}", file=sys.stderr)
        client.update_agent_runtime(agentRuntimeId=existing, **common)
        rid = existing
    else:
        print("  creating new runtime", file=sys.stderr)
        # IAM propagation retry on access-denied.
        for attempt in range(6):
            try:
                resp = client.create_agent_runtime(
                    agentRuntimeName=name,
                    description="source-truth code-QA agent (MVP)",
                    **common,
                )
                rid = resp["agentRuntimeId"]
                break
            except Exception as e:  # noqa: BLE001 - retry only on IAM propagation
                if "denied" in str(e).lower() and attempt < 5:
                    print(f"  IAM not propagated, retry {attempt + 1}/6", file=sys.stderr)
                    time.sleep(10)
                else:
                    raise
        else:
            raise RuntimeError("IAM never propagated")

    # Wait READY.
    for _ in range(36):
        time.sleep(10)
        s = client.get_agent_runtime(agentRuntimeId=rid)
        status = s["status"]
        print(f"  status: {status}", file=sys.stderr)
        if status == "READY":
            return rid, s["agentRuntimeArn"]
        if status in ("CREATE_FAILED", "UPDATE_FAILED", "DELETING"):
            raise RuntimeError(f"runtime {status}: {s.get('statusReason', '')}")
    raise TimeoutError("runtime did not reach READY in 6 minutes")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--region", required=True)
    p.add_argument("--account", required=True)
    p.add_argument("--role-arn", required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--name", default="source_truth_agent")
    # Required (no default): the model id is owned in ONE place — deploy-all.sh's
    # resolved MODEL — so this script can't silently deploy a different default than
    # the orchestrator intends. Callers must pass --model explicitly.
    p.add_argument("--model", required=True)
    p.add_argument("--sdk", choices=("openai", "claude"), default="openai")
    p.add_argument("--agent-max-turns", type=int, default=60)
    p.add_argument("--validate-only", action="store_true", help="validate local inputs without AWS calls")
    # VPC mode (to reach the in-VPC index-service): both must be provided together.
    p.add_argument("--subnets", help="comma-separated subnet ids (VPC mode)")
    p.add_argument("--security-groups", help="comma-separated security group ids")
    p.add_argument("--codegraph-mcp-url", help="index-service CodeGraph MCP-over-HTTP URL")
    # Session lifecycle (seconds). Omit → AWS defaults (idle 900, maxLifetime 28800).
    p.add_argument("--idle-timeout", type=int, help="idleRuntimeSessionTimeout secs (60..28800; default 900)")
    p.add_argument("--max-lifetime", type=int, help="maxLifetime secs (60..28800; default 28800)")
    args = p.parse_args()

    # Validate lifecycle bounds up front so a bad value fails with a clear message
    # here, not as an opaque ValidationException minutes into the deploy.
    subnets = args.subnets.split(",") if args.subnets else None
    security_groups = args.security_groups.split(",") if args.security_groups else None
    try:
        validate_options(args.sdk, args.model, args.agent_max_turns, subnets, security_groups,
                         args.idle_timeout, args.max_lifetime)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    if args.validate_only:
        return 0

    rid, arn = deploy(
        region=args.region,
        role_arn=args.role_arn,
        image=args.image,
        name=args.name,
        model=args.model,
        sdk=args.sdk,
        agent_max_turns=args.agent_max_turns,
        subnets=subnets,
        security_groups=security_groups,
        codegraph_mcp_url=args.codegraph_mcp_url,
        idle_timeout=args.idle_timeout,
        max_lifetime=args.max_lifetime,
    )
    print(f"AGENT_RUNTIME_ID={rid}")
    print(f"AGENT_RUNTIME_ARN={arn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
