#!/usr/bin/env python3
"""delete_runtime.py --region <r> (--arn <arn> | --id <id>)

Delete ONE AgentCore runtime, by ARN or id. Used by install.sh's "remove a project" flow to tear
down that project's runtime. Idempotent: a not-found runtime is treated as already-deleted (exit 0).
The agentRuntimeId is the LAST path segment of the ARN (…:runtime/<id>)."""
import argparse
import sys

import boto3
from botocore.exceptions import ClientError


def runtime_id_from_arn(arn: str) -> str:
    # arn:aws:bedrock-agentcore:<region>:<acct>:runtime/<id>
    tail = arn.rsplit("/", 1)[-1]
    if not tail or tail == arn:
        raise ValueError(f"cannot parse agentRuntimeId from ARN: {arn!r}")
    return tail


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--region", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--arn", help="full runtime ARN (…:runtime/<id>)")
    g.add_argument("--id", help="agentRuntimeId")
    args = p.parse_args()

    rid = args.id or runtime_id_from_arn(args.arn)
    client = boto3.client("bedrock-agentcore-control", region_name=args.region)
    try:
        client.delete_agent_runtime(agentRuntimeId=rid)
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in ("ResourceNotFoundException", "ValidationException"):
            # already gone (or never existed) — idempotent success
            sys.stderr.write(f"delete_runtime: {rid} not found ({code}) — treating as deleted\n")
            return 0
        sys.stderr.write(f"delete_runtime: failed to delete {rid}: {e}\n")
        return 1
    print(f"deleted agent runtime {rid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
