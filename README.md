# sample-code-qa-on-agentcore

![License: MIT-0](https://img.shields.io/badge/License-MIT--0-blue.svg)
![AWS Bedrock AgentCore](https://img.shields.io/badge/AWS-Bedrock%20AgentCore-orange.svg)

> This is a sample project demonstrating how to build a production-grade code Q&A agent on [AWS Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/). It shows how to connect a chat platform (Feishu/Lark) to an AI agent that answers questions about your codebase using real source code as the single source of truth.

For Chinese documentation, see [README_zh.md](README_zh.md).

---

## Overview

Engineers and non-technical stakeholders often need answers that live deep in the codebase — "how is this value computed?", "what's the relationship between config X and behavior Y?" — but reading code directly isn't always feasible, and engineers get interrupted repeatedly.

This sample deploys an AI agent that:

- Reads your project's **real code on the latest main branch**
- Answers questions in plain business language
- Attaches verifiable `file:line` sources to every conclusion
- Runs inside session-isolated microVMs on AgentCore for security and multi-tenancy

![Screen recording of a Q&A session: a user @-mentions the bot asking a code question; the card shows live analysis progress with a timer, streams the conclusion first, lists code sources in a collapsed verification panel at the bottom, and offers a follow-up button](docs/assets/demo-qa.gif)

> The recording is at 3× speed; the timer shown in the card is real elapsed time (first question ~45s, follow-up ~1m4s).

## Architecture

A question flows through three resident components:

1. **bot-gateway** — subscribes to chat platform events over a persistent connection
2. **Session-isolated microVM** — one per conversation on AgentCore Runtime
3. **index-service** — holds a read-only clone of your code with a CodeGraph index for fast symbol lookup

![Architecture diagram across three tiers: Chat platform → EC2 host (bot-gateway + index-service) → AgentCore session microVMs](docs/assets/architecture.en.svg)

> **Session microVMs mount no filesystem**: source code is read through index-service's HTTP interface (read-only tools only). The code copy lives only on index-service's local disk — one per project, never inside a microVM.

### End-to-end sequence

![End-to-end sequence of one Q&A: Chat client, bot-gateway, AgentCore microVM, index-service, CardKit across five swimlanes](docs/assets/sequence-qa.en.svg)

> Step-by-step details: [`docs/agent/architecture.md`](docs/agent/architecture.md)

### Key design properties

- **Trustworthy and verifiable** — real code is the only source of truth; every conclusion carries a `file:line` citation; when evidence is insufficient the agent defers rather than guessing.
- **Fast on large codebases** — a resident CodeGraph index locates symbols in **1–5 ms** on a 16 GB / 75k-file project. Full Q&A round-trips are **2.7–5.1× faster** than without the index ([benchmark data](docs/agent/perf-comparison.md)).
- **Cross-language term mapping** — an offline glossary maps business terms (in any language) to the actual symbols in code, so questions phrased in natural language still hit the right code paths ([glossary details](docs/glossary.md)).
- **Interactive streaming cards** — answers stream in real-time with progress indicators, collapsible source citations, and follow-up buttons for contextual conversation.

## Scope

The system does exactly one thing: **read-only Q&A over the main branch**. It looks things up and
answers; it changes nothing. Explicitly out of scope:

- Running the game engine or simulating numbers
- Writing code back, committing, or modifying any file
- Reading design documents, working across branches or worktrees, or sharing memory between sessions
- A second reasoning engine, or a complete audit trail

Planned capabilities are tracked in [`docs/agent/architecture.md`](docs/agent/architecture.md) and the design docs.

## Components

| Directory | Responsibility | Language |
|-----------|----------------|----------|
| [`agent-container/`](agent-container/) | Claude Code Agent inside the session microVM: reasoning + orchestration + code reading | Python |
| [`bot-gateway/`](bot-gateway/) | Chat platform event gateway + CardKit streaming-card rendering | TypeScript |
| [`index-service/`](index-service/) | Resident CodeGraph index service + MCP-over-HTTP interface (locate + read files) | Python |
| [`infra/`](infra/) | IaC: AgentCore Runtime / index service / gateway | boto3 + CDK |
| [`config/`](config/) | Central config: i18n copy, alarm thresholds | JSON |
| [`scripts/`](scripts/) | Deploy / ops / test lifecycle | Bash |

Full directory tree: [`docs/structure_en.md`](docs/structure_en.md)

## AWS services used

Everything lands in a single account and a single region (Tokyo `ap-northeast-1` by default). The
core is one shared ARM EC2 instance holding the resident index, one Bedrock AgentCore Runtime per
project (session-isolated microVMs), Bedrock model inference, plus S3 and ECR. Specs, counts, and
purpose for all 23 services and resources: [`docs/aws-services_en.md`](docs/aws-services_en.md).

## Prerequisites

On the machine you deploy **from**:

- **AWS account** with permissions for EC2, Bedrock, ECR, S3, Secrets Manager, IAM
- **Bedrock AgentCore** access (Runtime API enabled in your region)
- **AWS CLI v2** — v1 is not supported
- **Session Manager plugin** — required for every verification and day-2 operation
  ([install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html));
  it does not ship with the AWS CLI
- **Docker** with a running daemon — Phase 4 builds the ARM64 agent image locally
- **git**, and **`gh`** (authenticated via `gh auth login`) if your target repository is private
- **Node.js 24** — for bot-gateway
- **Python 3.11** (agent-container, matching its container base image) / **3.12** (index-service)
- **`zip`** — optional, only for the DAU pre-aggregation Lambda

Also required:

- **Feishu (Lark) bot credentials** — App ID, App Secret, Bot Open ID. The installer creates the
  Secrets Manager entry for you; you supply the values interactively.
- **codegraph-server** — the index engine binary. See
  [`docs/runbook.md`](docs/runbook.md) for how to obtain and stage it.

## Cost

This stack runs continuously, so it costs money while it is up. The floor is set by two
always-on resources:

| Resource | Rough cost |
|----------|-----------|
| NAT Gateway (one, always on) | ~$32/month + data processing |
| Index host EC2 (`t4g.large` default) | ~$50/month on-demand |
| Bedrock model invocations | per token, scales with question volume |
| Glossary build (optional, one-off per repo) | can be **hundreds of dollars** on a large repo — see below |

The glossary build runs a model over your source tree and is **uncapped by default**. On a
14k-file repository it measured ~$372. Set `--glossary-max-files` to bound it, or leave the
glossary off entirely. Full per-service inventory: [`docs/aws-services_en.md`](docs/aws-services_en.md).

## Cleanup

Tear everything down when you are finished — nothing expires on its own:

```bash
./scripts/teardown.sh --region <r> --dry-run   # review the deletion plan first
./scripts/teardown.sh --region <r>             # delete this region's resources
./scripts/teardown.sh --region <r> --include-shared   # also the account-level IAM roles + S3 bucket
```

A default run keeps a few account-level resources on purpose (Secrets Manager entries, CloudWatch
log groups, the artifact bucket); teardown prints exactly what it retained so you can remove the
rest by hand.

## Deployment

For the full deployment walkthrough (prerequisites, configuration, connecting your chat platform, operations, and troubleshooting), see [`docs/runbook.md`](docs/runbook.md).

### Quick start

On a machine with AWS credentials configured:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aws-samples/sample-code-qa-on-agentcore/main/scripts/get.sh)
```

If your fork of this repository is private, a bare `curl` cannot reach it. Run `gh auth login` once,
then fetch the bootstrap script through the authenticated API instead:

```bash
bash <(gh api repos/aws-samples/sample-code-qa-on-agentcore/contents/scripts/get.sh --jq '.content' | base64 -d)
```

Either way the script clones into `./source-truth/` (override with `SOURCE_TRUTH_DIR`), using `gh`
credentials automatically for a private repository, then launches an interactive installer that
prompts for region, target repositories, model selection, and chat platform credentials.

With the repo already cloned:

```bash
./scripts/install.sh    # Interactive: region / repos / model / credentials → brings up backend + gateway
./scripts/test.sh       # Offline suite: lint + unit + typecheck (no Docker / AWS needed)
```

### Deployment topologies

- **Default (two machines)**: run the script on a deploy box; it creates and configures the index-host EC2 instance.
- **Single EC2 (`--local`)**: one machine serves as both deployer and the resident index + gateway
  host. Run `./scripts/launch-host.sh` locally — it creates the network and IAM, launches an ARM64
  EC2 instance in the public subnet with the instance role attached, uploads the bootstrap script,
  and prints an `ssh` command. Log in as instructed and run the printed script: it installs
  dependencies, authenticates to GitHub, clones the repo, and drops you into `./scripts/install.sh --local`.

The AgentCore Runtime is always AWS-managed regardless of topology.

## How code enters the system and stays fresh

Each target repository is cloned onto the index-service host, where a file watcher rebuilds the
index incrementally. Two kinds of source:

- **git repositories** (default): a systemd timer runs `git pull` on an interval
  (`refreshIntervalSec`, 300s by default), so a change on the main branch shows up in answers within
  minutes — no redeploy, no manual step.
- **Local repositories** (nothing to pull from): push snapshots with `scripts/push-local-repo.sh`
  over rsync. Refresh is manual — change the code, run the push command again.

A single project can span multiple repositories, and one index-service host can serve several
projects as separate processes on separate ports. The refresh mechanics, and measurements of why the
index is worth building at all, are in
[`docs/agent/architecture.md`](docs/agent/architecture.md); local-repo pushes and single-EC2
(`--local`) deployment are covered in [`docs/runbook.md`](docs/runbook.md).

## Configuration

- **Credentials**: chat platform credentials go through AWS Secrets Manager — never written to disk or committed to the repository.
- **Ports and models**: declared per project in `.local/projects.json`; the model can be overridden per project at deploy time.

## Testing

```bash
./scripts/test.sh       # Runs lint + unit tests + type checking (offline, no AWS needed)
```

For integration testing against a live deployment, see the testing section in [`docs/runbook.md`](docs/runbook.md).

## Security

Three code-enforced security boundaries (not merely prompt constraints):

| Defense | Mechanism |
|---------|-----------|
| **Anti-privilege-escalation** | The agent has no write tools registered — the server exposes only a read-only tool set |
| **Anti-leak** | All fields sent to chat are de-identified; secrets and internal topology never leave the backend; credentials use Secrets Manager |
| **Anti-injection** | Code and comments read via tools are treated as data to analyze; only the system prompt baked into the container image is trusted |

![Security design: three code-enforced defense layers shown side by side](docs/assets/security-defense.en.svg)

Per-item enforcement details, source of truth, automated checks, and violation consequences: [`docs/agent/invariants.md`](docs/agent/invariants.md)

**Known limitations**: the model can hallucinate or be influenced by adversarial content in questions (mitigated by the three defenses above); index refresh is minute-level, so a just-pushed commit takes one cycle to appear.

## Documentation

| Topic | Link |
|-------|------|
| Deploy / connect chat platform / ops / troubleshooting | [`docs/runbook.md`](docs/runbook.md) |
| How a question flows through the system | [`docs/agent/architecture.md`](docs/agent/architecture.md) |
| AI collaboration conventions | [`AGENTS.md`](AGENTS.md) |
| Requirements and architecture design | [`docs/design/`](docs/design/README.md) |
| Full docs map | [`docs/README.md`](docs/README.md) |

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
