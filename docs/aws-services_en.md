[中文](aws-services_zh.md) | [English](aws-services_en.md)

# AWS Services Inventory

The system deploys into a single account, single region (Tokyo `ap-northeast-1` by default). This document
lists every AWS service used, with its specs, count, and purpose.

Specs are defaults and tunable at deploy time (see `scripts/install.sh` and `scripts/deploy-all.sh`). In the
**Count** column, **N = number of projects** (one Feishu bot per game project; per-project resources scale with
project count); the rest are globally shared.

## 1. Compute & AI (run the agent, produce answers)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **EC2** (index-service host) | ARM Graviton `t4g.large` (2 vCPU / 8 GiB) default; up to `m7g.2xlarge` (8 vCPU / 32 GiB); termination protection on and IMDSv2 required (`HttpTokens=required`, re-asserted on every deploy) | 1 (shared by all projects) | Resident CodeGraph index + MCP-over-HTTP interface, per-project bot-gateway processes; holds the single local code copy; also runs the build-time glossary engine (a local `claude` CLI scans code offline to generate the term table, see `docs/agent/glossary.md`) |
| **Bedrock AgentCore Runtime** | Firecracker microVM; VPC mode; idle reclaim 900s, hard cap 8h (both tunable 60–28800s) | **N** (`source_truth_agent_<projectId>`, one per project) | Session-isolated agent execution environment, one microVM per session |
| **Bedrock** (model inference) | Default `global.anthropic.claude-opus-4-8` (overridable per project) | shared | (1) LLM inference for the in-microVM agent; (2) `InvokeModel` by the index-host build-time glossary engine (the index instance role carries a scoped `bedrock-invoke` policy). Both billed via `CLAUDE_CODE_USE_BEDROCK=1` |

## 2. Storage & images (code, artifacts, images)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **EBS** (root volume) | gp3, 30 GiB default; 50 / 100 / 200 GiB or manual entry; `Encrypted: true` (encryption at rest, AWS-managed key) | 1 | Stores code copy, `graph.db`, build artifacts |
| **S3** | artifact bucket `source-truth-repo-<account>-<region>` | 1 | Deploy artifacts: codegraph binary, index/gateway tarballs, bootstrap script |
| **ECR** | private repo `source-truth/agent`, ARM64 images | 1 | Holds the session-container image for AgentCore to pull |

## 3. Network (isolation & connectivity)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **VPC** | CIDR `10.1.0.0/16`; public subnet `10.1.0.0/24` + private subnet `10.1.1.0/24` | 1 | Network isolation. In the default two-machine topology the index host sits in the private subnet; under `--local` (single EC2) it sits in the public subnet with a public IP, and its security group opens port 22 to the operator's egress IP only |
| **NAT Gateway** (+ Elastic IP) | in the public subnet | 1 | Private-subnet egress (pull S3 artifacts, call Bedrock) |
| **Internet Gateway** | — | 1 | Public-subnet ingress |
| **Security Group** | inbound `8080-8099` only, restricted to same-SG members | 1 (the AgentCore Runtime ENI joins this SG too) | Restricts per-project bridge ports to in-VPC reachability only |
| **Network ACL** | `source-truth-private-nacl`, associated with the private subnet (replacing the default). Inbound allow-list: `100` TCP 8080-8099 (VPC CIDR only), `110` TCP 443 (VPC CIDR only), `120/130` TCP/UDP 32768-60999 (return traffic for connections this subnet opened through the NAT), `140` ICMP type 3 code 4 (Path MTU discovery); outbound allow-all (NAT egress needs it); everything else falls to the implicit deny at 32767 | 1 | Second, subnet-level network control. Convergence is additive — desired rules are written first, stale ones removed after — so the subnet never passes through a deny-all state |
| **VPC Flow Logs** | all traffic (`ALL`), 600s aggregation interval, delivered to S3 at `s3://<artifact-bucket>/vpc-flow-logs/` | 1 | Network audit trail. A failure to create it only warns and never blocks the deploy (audit aid, not a serving dependency) |
| **Route 53** (private hosted zone) | private domain `source-truth.internal`, A record TTL 30s | 1 | Stable DNS name for the index host (the agent side never hard-codes a private IP; the index host is updated in place, never replaced, so the name always resolves to the same running host) |

## 4. Security & ops (credentials, permissions, remote management)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **Secrets Manager** | Feishu credentials (per project) + git read-only token + log-hashing salt; `--local` adds one deploy-time GitHub token | **N + 2** (`feishu-<projectId>` ×N, `git-credentials`, `log-hash-salt`); **N + 3** under `--local` (plus `deploy-github-token`) | Feishu app credentials, read-only private-repo pull token, `hashUserId` salt. The `--local` `deploy-github-token` lets a freshly launched host `gh auth login` to clone a private repo, download releases, and upgrade later. Fetched at runtime, never written to disk |
| **IAM** | 3 roles + 1 instance profile + 1 service-linked role | fixed | EC2 execution role `source-truth-index-role`, AgentCore Runtime role `SourceTruthAgentRuntimeRole`, DAU pre-aggregation Lambda role `source-truth-dau-lambda-role`, the instance profile, and AgentCore's VPC-ENI managed role. All three roles are account-level and shared across regions, so resource ARNs in their policies must wildcard the region segment — otherwise a second-region deploy overwrites the policy and silently revokes the first region's permissions. `check-invariants.sh` guards this **partially**: it greps only `scripts/lib/provision_iam.sh` and `scripts/lib/apply-dau-lambda.sh`, and only for `logs` / `bedrock` / `bedrock-agentcore` / `secretsmanager` / `s3` ARNs. `scripts/lib/create-iam.sh` — which writes inline policies onto the same account-level `source-truth-index-role` on the `--local` path — is **not scanned**, so a region-pinned ARN added there would pass CI |
| **Systems Manager (SSM)** | Session Manager (no SSH) | — | Manage the private-subnet EC2: activate projects, refresh gateways, clean up units |

## 5. Monitoring & alerting (health, metrics)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **CloudWatch Logs** | log groups `/source-truth/bot-gateway` (gateway log files) + `/source-truth/index-bridge` (bridge journald units), both with 90-day retention | 2 (all project gateways feed the first, separated by `projectId` dimension) | Gateway structured logs (the source for metrics) plus index-bridge logs; shipped by the CloudWatch agent on the host |
| **CloudWatch Metric Filters** | 17 KPIs + 4 alarm-backing + 8 per-project | 29 | Extract usage / latency / health / failure-rate metrics from logs |
| **CloudWatch Dashboards** | product usage / SRE health / per-project | 3 | Dashboard visualization |
| **CloudWatch Alarms** | ToolcallLeakDetected / FinalizeFailed / AnswerFailedBurst / LogPipelineStalled (thresholds in `config/alarm-thresholds.json`, notified via SNS) + `source-truth-index-auto-recover-<region>` (`StatusCheckFailed_System`, action `arn:aws:automate:<region>:ec2:recover`, not routed through SNS) | 5 | The first four alarm on key health events. The fifth triggers EC2 auto-recovery: after two consecutive system status-check failures (underlying hardware / hypervisor), the instance is recovered onto healthy hardware, keeping its instance id, private IP, and EBS volume |
| **SNS** | topic `source-truth-alarms` | 1 | Alarm fan-out (manually subscribe email / webhook) |
| **Lambda** | `python3.12`, 128 MB, 180s timeout | 1 | DAU pre-aggregation: a daily Logs Insights query written back as a metric |
| **EventBridge** | rule `source-truth-dau-daily`, daily cron | 1 | Triggers the DAU pre-aggregation Lambda |

## Not used (to avoid confusion)

Session mapping and event dedup are **in-process in-memory** in the gateway (MVP); no DynamoDB / Redis. Session
containers **mount no filesystem** (no EFS); all source is read through the index-service HTTP interface — no shared
mount, no copy-sync problem.
