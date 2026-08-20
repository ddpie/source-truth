# AWS Services Inventory

The system deploys into a single account, single region (Tokyo `ap-northeast-1` by default). This document
lists every AWS service used, with its specs, count, and purpose.

Specs are defaults and tunable at deploy time (see `scripts/install.sh` and `scripts/deploy-all.sh`). In the
**Count** column, **N = number of projects** (one Feishu bot per game project; per-project resources scale with
project count); the rest are globally shared.

## 1. Compute & AI (run the agent, produce answers)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **EC2** (index-service host) | ARM Graviton `t4g.large` (2 vCPU / 8 GiB) default; up to `m7g.2xlarge` (8 vCPU / 32 GiB) | 1 (shared by all projects) | Resident CodeGraph index + MCP-over-HTTP interface, per-project bot-gateway processes; holds the single local code copy; also runs the build-time glossary engine (a local `claude` CLI scans code offline to generate the term table, see `docs/agent/glossary.md`) |
| **Bedrock AgentCore Runtime** | Firecracker microVM; VPC mode; idle reclaim 900s, hard cap 8h (both tunable 60–28800s) | **N** (`source_truth_agent_<projectId>`, one per project) | Session-isolated agent execution environment, one microVM per session |
| **Bedrock** (model inference) | Default `global.anthropic.claude-opus-4-8` (overridable per project) | shared | (1) LLM inference for the in-microVM agent; (2) `InvokeModel` by the index-host build-time glossary engine (the index instance role carries a scoped `bedrock-invoke` policy). Both billed via `CLAUDE_CODE_USE_BEDROCK=1` |

## 2. Storage & images (code, artifacts, images)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **EBS** (root volume) | gp3, 30 GiB default; 50 / 100 / 200 GiB or manual entry | 1 | Stores code copy, `graph.db`, build artifacts |
| **S3** | artifact bucket `source-truth-repo-<account>-<region>` | 1 | Deploy artifacts: codegraph binary, index/gateway tarballs, bootstrap script |
| **ECR** | private repo `source-truth/agent`, ARM64 images | 1 | Holds the session-container image for AgentCore to pull |

## 3. Network (isolation & connectivity)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **VPC** | CIDR `10.1.0.0/16`; public subnet `10.1.0.0/24` + private subnet `10.1.1.0/24` | 1 | Network isolation; index host in the private subnet |
| **NAT Gateway** (+ Elastic IP) | in the public subnet | 1 | Private-subnet egress (pull S3 artifacts, call Bedrock) |
| **Internet Gateway** | — | 1 | Public-subnet ingress |
| **Security Group** | inbound `8080-8099` only, restricted to same-SG members | 1 (the AgentCore Runtime ENI joins this SG too) | Restricts per-project bridge ports to in-VPC reachability only |
| **Route 53** (private hosted zone) | private domain `source-truth.internal`, A record TTL 30s | 1 | Stable DNS name for the index host (the agent side never hard-codes a private IP; the index host is updated in place, never replaced, so the name always resolves to the same running host) |

## 4. Security & ops (credentials, permissions, remote management)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **Secrets Manager** | Feishu credentials (per project) + git read-only token + log-hashing salt | **N + 2** (`feishu-<projectId>` ×N, `git-credentials`, `log-hash-salt`) | Feishu app credentials, read-only private-repo pull token, `hashUserId` salt; fetched at runtime, never written to disk |
| **IAM** | 2 roles + 1 instance profile + 1 service-linked role | fixed | EC2 execution role, AgentCore Runtime role, instance profile, AgentCore's VPC-ENI managed role |
| **Systems Manager (SSM)** | Session Manager (no SSH) | — | Manage the private-subnet EC2: activate projects, refresh gateways, clean up units |

## 5. Monitoring & alerting (health, metrics)

| Service | Specs | Count | Purpose |
|---------|-------|-------|---------|
| **CloudWatch Logs** | log group `/source-truth/bot-gateway` | 1 (all project gateways feed in, separated by `projectId` dimension) | Gateway structured logs, the source for metrics |
| **CloudWatch Metric Filters** | 17 KPIs + 4 alarm-backing + 8 per-project | 29 | Extract usage / latency / health / failure-rate metrics from logs |
| **CloudWatch Dashboards** | product usage / SRE health / per-project | 3 | Dashboard visualization |
| **CloudWatch Alarms** | ToolcallLeakDetected / FinalizeFailed / AnswerFailedBurst / LogPipelineStalled | 4 | Alarms on key health events, notified via SNS |
| **SNS** | topic `source-truth-alarms` | 1 | Alarm fan-out (manually subscribe email / webhook) |
| **Lambda** | `python3.12`, 128 MB, 180s timeout | 1 | DAU pre-aggregation: a daily Logs Insights query written back as a metric |
| **EventBridge** | rule `source-truth-dau-daily`, daily cron | 1 | Triggers the DAU pre-aggregation Lambda |

## Not used (to avoid confusion)

Session mapping and event dedup are **in-process in-memory** in the gateway (MVP); no DynamoDB / Redis. Session
containers **mount no filesystem** (no EFS); all source is read through the index-service HTTP interface — no shared
mount, no copy-sync problem.
