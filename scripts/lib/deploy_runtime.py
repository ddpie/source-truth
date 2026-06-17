#!/usr/bin/env python3
"""Idempotent AgentCore Runtime deploy for agent-container (boto3, no CDK).

Create-or-update the source-truth agent runtime from an already-built+pushed
ECR image. Idempotent: if a runtime with the same name exists, update it in
place (= upgrade); otherwise create. Waits for READY.

Verified against real AWS: created source_truth_agent-xC7N7O63iA (READY),
real InvokeAgentRuntime returned a real Bedrock answer.

Usage:
  python3 deploy_runtime.py --region us-east-1 --account 557690613480 \
    --role-arn arn:...:role/SourceTruthAgentRuntimeRole \
    --image <acct>.dkr.ecr.<region>.amazonaws.com/source-truth/agent:latest \
    [--name source_truth_agent] [--model global.anthropic.claude-sonnet-4-6]

Prints `AGENT_RUNTIME_ID=<id>` and `AGENT_RUNTIME_ARN=<arn>` on success.
"""

from __future__ import annotations

import argparse
import sys
import time

import boto3


def find_existing(client, name: str) -> str | None:
    for rt in client.list_agent_runtimes(maxResults=100).get("agentRuntimes", []):
        if rt.get("agentRuntimeName") == name:
            return rt["agentRuntimeId"]
    return None


def deploy(
    *, region: str, role_arn: str, image: str, name: str, model: str
) -> tuple[str, str]:
    client = boto3.client("bedrock-agentcore-control", region_name=region)
    artifact = {"containerConfiguration": {"containerUri": image}}
    net = {"networkMode": "PUBLIC"}
    env = {"CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_MODEL": model}

    existing = find_existing(client, name)
    if existing:
        print(f"  updating existing runtime {existing}", file=sys.stderr)
        client.update_agent_runtime(
            agentRuntimeId=existing,
            roleArn=role_arn,
            networkConfiguration=net,
            agentRuntimeArtifact=artifact,
            environmentVariables=env,
        )
        rid = existing
    else:
        print("  creating new runtime", file=sys.stderr)
        # IAM propagation retry on access-denied.
        for attempt in range(6):
            try:
                resp = client.create_agent_runtime(
                    agentRuntimeName=name,
                    description="source-truth code-QA agent (MVP)",
                    roleArn=role_arn,
                    networkConfiguration=net,
                    agentRuntimeArtifact=artifact,
                    environmentVariables=env,
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
    p.add_argument("--model", default="global.anthropic.claude-sonnet-4-6")
    args = p.parse_args()

    rid, arn = deploy(
        region=args.region,
        role_arn=args.role_arn,
        image=args.image,
        name=args.name,
        model=args.model,
    )
    print(f"AGENT_RUNTIME_ID={rid}")
    print(f"AGENT_RUNTIME_ARN={arn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
