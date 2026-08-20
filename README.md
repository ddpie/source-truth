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

## Prerequisites

- **AWS account** with permissions for EC2, Bedrock, ECR, S3, Secrets Manager, IAM
- **Bedrock AgentCore** access (Runtime API enabled in your region)
- **Feishu (Lark) bot credentials** — App ID, App Secret, Verification Token (stored in Secrets Manager)
- **codegraph-server** — the index engine binary (auto-downloaded by the deploy script if missing)
- **Node.js 20+** — for bot-gateway
- **Python 3.12+** — for agent-container and index-service

## Deployment

For the full deployment walkthrough (prerequisites, configuration, connecting your chat platform, operations, and troubleshooting), see [`docs/runbook.md`](docs/runbook.md).

### Quick start

On a machine with AWS credentials configured:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aws-samples/sample-code-qa-on-agentcore/main/scripts/get.sh)
```

This clones the repo, then launches an interactive installer that prompts for region, target repositories, model selection, and chat platform credentials.

With the repo already cloned:

```bash
./scripts/install.sh    # Interactive: region / repos / model / credentials → brings up backend + gateway
./scripts/test.sh       # Offline suite: lint + unit + typecheck (no Docker / AWS needed)
```

### Deployment topologies

- **Default (two machines)**: run the script on a deploy box; it creates and configures the index-host EC2 instance.
- **Single EC2 (`--local`)**: one machine serves as both deployer and the resident index + gateway host. Run `./scripts/launch-host.sh` to provision the infrastructure automatically.

The AgentCore Runtime is always AWS-managed regardless of topology.

## Configuration

- **Code sources**: each target repo is cloned to index-service locally; a systemd timer runs `git pull` for minute-level freshness with no redeploy.
- **Local repos** (no git remote): push snapshots via `scripts/push-local-repo.sh` over rsync.
- **Multi-repo**: a single project can span multiple repositories; one index-service host can serve several projects (separate processes and ports).
- **Credentials**: chat platform credentials go through AWS Secrets Manager — never written to disk or committed to the repository.

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
