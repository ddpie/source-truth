# Deployment and operations runbook

How to deploy source-truth from scratch, connect it to Feishu / Lark, and run it day to day. For how
it works, see [`agent/architecture.md`](agent/architecture.md) (Chinese only); this document only covers **what to do**.

The system has two parts, both brought up by the deploy scripts: the **backend** (S3 artifacts → IAM → network → index-service EC2 → container image → AgentCore Runtime) and **bot-gateway** (the Feishu/Lark long-connection gateway, co-located with the index service, which routes messages that @-mention the bot in a group to the backend and streams answers back into a card).

There are two entry points: `install.sh` (interactive, recommended) and `deploy-all.sh` (command-line flags, suited to CI). The install can be driven remotely from a separate operator machine, or run step by step on the target host itself (`--local`). "Quick start" gives the command for each; see [section 2](#2-one-command-install-interactive-recommended) for how to choose. Every deploy is **idempotent**: re-run after an interruption and it continues from where it stopped.

**SDK selection:** new projects default to OpenAI Agents SDK. Existing projects retain their
selection during a code upgrade. `agent.sdk` controls both Q&A and glossary generation;
see [dual SDK configuration](dual-sdk_en.md) for configuration and migration steps.

**Region and deployment records:** the installer suggests Tokyo (`ap-northeast-1`); choose a region
with AgentCore Runtime and access to your selected Bedrock models. Keep account-specific resource IDs,
project inventories, release records and rollback material under the ignored `.local/` directory.
Check host logs and artifact metadata for background glossary rebuild progress; Runtime READY does
not establish that the glossary is rebuilt.

## Quick start

The shortest path to a deployment; the details are in the sections that follow. Assumes the `aws` CLI is installed and credentialed on this machine, and that the Feishu/Lark app has been created per [section 3](#3-connecting-feishu--lark) so you hold the `App ID` and `App Secret`. (The bot's `open_id` is derived automatically by the installer — the console does not display one.)

Pick one of the two — **one-command deploy** (the default: installed remotely from an operator machine) or **manual deploy** (`--local`: log into the target EC2 and run it step by step). At runtime both end up with exactly one EC2 instance running the services; the difference is only which machine drives the install. See [section 2](#2-one-command-install-interactive-recommended) for the trade-offs. Once you have chosen, follow only that one path.

### Option A · One-command deploy (default)

On the operator machine (your laptop or CI):

```bash
git clone https://github.com/ddpie/source-truth.git && cd source-truth
./scripts/install.sh          # Answer the prompts: region / repositories / Feishu credentials — backend and gateway in one pass
```
Details in [section 2](#2-one-command-install-interactive-recommended); when it finishes, verify per [section 5](#5-verification-end-to-end-smoke-test).

### Option B · Manual deploy (`--local`)

Three steps: **create the host → deploy the services → push the code**.

**Step 1 · Create the host** (run locally): creates the EC2 instance; the script prints an `ssh` command at the end for use in the next step.

```bash
git clone https://github.com/ddpie/source-truth.git && cd source-truth
./scripts/launch-host.sh
```

**Step 2 · Deploy the services** (run after logging in with the `ssh` command printed by step 1): answer `install.sh`'s prompts for repositories / model / Feishu credentials. When it finishes, all three backend components (bridge, runtime, gateway) are up.

```bash
# Run the command launch-host.sh PRINTED — it carries your own repo URL and branch.
# A bare `bash /tmp/prepare-local-host.sh` defaults to upstream main, so on a
# fork or a feature branch it silently deploys code that is not yours.
REPO_URL=<your repo URL> REPO_REF=<your branch> bash /tmp/prepare-local-host.sh
```

**Step 3 · Push the code** (run locally; only needed for local repositories): a local repository must be pushed before the bot can answer anything; after that, every code change is refreshed by pushing again.

```bash
./scripts/push-local-repo.sh --host <ssh-host> [--identity <key>] <subdir> <local-path>
```

For the details of each step (SSH private key, private-repository credentials, the index build on first push, …) see [the end of section 2, "Manual deploy: install in place on a single EC2"](#manual-deploy-install-in-place-on-a-single-ec2---local) and [the end of section 9, "Local-repository upload"](#local-repository-upload); after the first deploy completes, work through [Appendix C](#appendix-c-on-host-checklist-after-the-first-deploy) item by item.

**Contents**

0. [Quick start](#quick-start)
1. [Prerequisites (one-time)](#1-prerequisites-one-time)
2. [One-command install (interactive, recommended)](#2-one-command-install-interactive-recommended)
   - [Manual deploy: install in place on a single EC2 (`--local`)](#manual-deploy-install-in-place-on-a-single-ec2---local)
3. [Connecting Feishu / Lark](#3-connecting-feishu--lark)
4. [Where the gateway runs](#4-where-the-gateway-runs)
5. [Verification (end-to-end smoke test)](#5-verification-end-to-end-smoke-test)
6. [Day-2 operations](#6-day-2-operations)
7. [Multiple projects (several bots on one host)](#7-multiple-projects-several-bots-on-one-host)
8. [Troubleshooting (symptom → cause → action)](#8-troubleshooting-symptom--cause--action)
9. [Boundaries and security (must-know)](#9-boundaries-and-security-must-know)
- [Appendix A: deploy-all.sh by hand](#appendix-a-deploy-allsh-by-hand)
- [Appendix B: running the gateway locally (development)](#appendix-b-running-the-gateway-locally-development)
- [Appendix C: on-host checklist after the first deploy](#appendix-c-on-host-checklist-after-the-first-deploy)
- [Appendix D: refreshing monitoring by hand](#appendix-d-refreshing-monitoring-by-hand)
- [Appendix E: Observability (AgentCore spans and traces)](#appendix-e-observability-agentcore-spans-and-traces)
- [Appendix F: Evaluations (AgentCore Evaluations)](#appendix-f-evaluations-agentcore-evaluations)

---

## 1. Prerequisites (one-time)

1. **AWS account + target region**: the region must support AgentCore (for example `ap-northeast-1`, Tokyo). Configure deploy-capable AWS credentials on this machine.
2. **Deploy machine (Linux or macOS)**: the detailed requirements below expand the
   quick-start checklist in [`../README.md`](../README.md).

   - **`aws` CLI v2** — v1 is not supported.
   - **`python3`** with a **boto3 new enough to carry `bedrock-agentcore-control`** (used to configure the
     Runtime). Use a virtual environment on systems with an externally managed Python installation:
     `python3 -m venv .venv-deploy`, `source .venv-deploy/bin/activate`, then
     `python -m pip install --upgrade boto3`. Keep that environment active while deploying.
   - **Docker with a running daemon**, able to build **linux/arm64** (the agent container is ARM64-only;
     phase 4 builds the image, and installing Docker without starting it is caught by the dependency
     check, which tells you to verify with `docker info`). On an x86 host, install the emulator first:
     `docker run --privileged --rm tonistiigi/binfmt --install arm64`.
   - **GNU tar** — stock macOS ships BSD tar, which cannot produce reproducible archives. Without it the
     index host reads the artifacts as changed on every deploy and re-bootstraps in place, interrupting
     every bot on that machine. `brew install gnu-tar` provides `gtar`, which is picked up automatically.
   - **[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)** — needed for interactive host access (`aws ssm start-session`); it does not ship with the AWS CLI. Automated deployment uses SSM commands and only warns if this plugin is absent.
   - **`git`**; a private-repository deploy also needs **`gh`** with `gh auth login` already done (used to clone the repository and to fetch `codegraph-server`).
   - **An EC2 key pair plus its local `.pem`** — only for `--local` (you SSH into the host it creates).
   - **`rsync`** — only if the code arrives as a local-repository snapshot push instead of a git clone.
   - **`zip`** — optional, only to package the monitoring DAU pre-aggregation Lambda; without it Q&A and
     the rest of monitoring are unaffected, the "daily active" widget is simply empty (`--local`
     installs it automatically).

   Node.js and native build toolchains are **not** needed locally; Python 3 with boto3 is required above. The gateway is built on the index host and
   the agent runs in a container. The `codegraph-server` binary needs no manual preparation either — when
   it is absent both locally and in S3, the deploy downloads it from the engine's upstream Release and verifies its published checksum
   (this repository does not redistribute the binary; see `index-service/README.md`).
3. **Bedrock model access**: the deployer probes selected models through Converse. A denial for that identity is advisory; post-deploy smoke checks the runtime identity. Runtime/index roles need
   `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` for the selected models.
   The IAM phase configures execution roles. OpenAI Q&A and glossary builds use `ConverseStream`.
   Deployment lists system inference profiles for `--region` and resolves the same model's available
   prefix without substituting another model. Claude may resolve to `jp.…` in Tokyo; OpenAI uses the
   corresponding `global.openai.…` profile. An ACTIVE profile or successful preflight is not proof
   of a complete real invocation.
4. **Target repositories**: the code to be answered about, from two kinds of source (mixable within one project):
   - **git repository** (recommended; written as `source: "git"` in the config, which is the default): `https://github.com/org/repo.git`, `https://gitlab.com/org/repo.git`, `git@host:org/repo.git`, with an optional branch / tag / commit. index-service clones it locally and `git pull`s on a timer, so a change on the main branch shows up in answers within minutes. A private repository needs one read-only credential (stored in Secrets Manager and read by the index host).
   - **local repository** (written as `source: "local"`; for code that exists only locally and cannot be pushed to any git remote): after deploying, push it straight to the index host over rsync with `scripts/push-local-repo.sh` (see [the end of section 9, "Local-repository upload"](#local-repository-upload)). What you push is a point-in-time snapshot and does not follow later code changes — run the upload command again after every change.
5. **Feishu / Lark app** (see section 3; can be prepared in parallel with the deploy). Decide the **tenant** at the same time: Feishu, China (`open.feishu.cn`, deploy flag `--feishu-domain feishu`, the default) or international Lark (`open.larksuite.com`, `--feishu-domain lark`). This choice has to be right **at the first deploy**, and it must match the console the app was created in — when they disagree the bot authenticates successfully and then never receives an event (details in section 3).

---

## 2. One-command install (interactive, recommended)

Prepare the Feishu / Lark app first (section 3) and have the `App ID` and `App Secret` at hand. The bot's `open_id` is derived automatically; you are prompted only if that derivation fails.

The install command is in [Quick start](#quick-start); if you have not cloned the repository yet, a single command bootstraps it (clones into `./source-truth/`, then enters the interactive install):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ddpie/source-truth/main/scripts/get.sh)
```

The public repository does not require a GitHub login. For a private fork, authenticate with `gh auth login`
and set `SOURCE_TRUTH_SLUG=owner/repo`; see the bootstrap overrides in [`scripts/README.md`](../scripts/README.md).

`install.sh` is an interactive menu (arrow keys to select, Enter to confirm); its four flows are described in [section 7, Multiple projects](#7-multiple-projects-several-bots-on-one-host).
The default action is "add project"; separate environment initialization is optional. Glossary and monitoring default off for a new environment; existing environments retain their choices.
The typical order for a first deploy:

1. **Dependency check**: `aws` / `python3` / `docker` (daemon running) / `git`, optionally `gh` (needed for a private-repository deploy), and a check that the AWS credentials work;
2. **Choose "add project"** (the shared base is created first if it does not exist): enter the projectId → add repositories one by one (**git URL** + subdirectory + branch) → the index-service port (the port this project's `index-bridge-<project>` process listens on; the script suggests one) → the Agent SDK (OpenAI by default) and answer model (also used by the glossary) → the Feishu app credentials (written automatically to `source-truth/feishu-<project>`) → on the first run, one more read-only git credential (written to the global `source-truth/git-credentials` and reused by later projects);
3. Write `.local/projects.json` and deploy that project (shared base + that project's bridge + runtime + gateway).

> To stand up the AWS environment first and configure git later, choose "**initialize environment (no project)**": it brings up only the shared base. Instance types and disk sizes are in the table below.

The index host is the only EC2 instance in the whole system (it runs the codegraph index plus every project's bridge and every project's bot-gateway, all ARM).
The codegraph index is memory-hungry and grows with repository size, so pick the instance type by repository scale; the disk holds each repository's git copy plus `graph.db`, so pick the volume by total size:

| Instance type | vCPU / memory | Suited to |
|---|---|---|
| `t4g.large` (default) | 2C / 8G | Small and medium repositories; burstable is cheaper |
| `t4g.xlarge` | 4C / 16G | Medium-to-large repositories |
| `m7g.large` | 2C / 8G | Memory-optimized, steadier under sustained load |
| `m7g.xlarge` | 4C / 16G | Large repositories, steady |
| `m7g.2xlarge` | 8C / 32G | Very large repositories / many repositories |

The disk defaults to 30 GiB, with 50 / 100 / 200 GiB or a custom size available.

**Optional capabilities:** enable glossary and monitoring when adding a project, or pass `--with-glossary` / `--with-monitoring`.
An enabled glossary defaults to **400 files per repository**; only `--glossary-max-files 0` removes the cap.
Q&A and glossary share the SDK and, on first install, the answer model. Advanced configuration can override `agent.glossaryModel`.
Disabling glossary generation keeps git refresh running and leaves existing valid entries readable.

| Cap | Use |
|---|---|
| `400` (default when enabled) | Initial evaluation with bounded model calls |
| `1000` / `4000` | Broader coverage |
| `0` (explicit) | All candidate files; cost grows with repository size |

Unchanged configuration normally builds incrementally; switching SDK or model causes a full rebuild.
English-only files may still incur model charges. `--with-glossary=false` stops glossary generation.
`--with-monitoring=false` skips future monitoring deployment; existing alarms, schedules and other resources remain active.
Later runs retain the saved choice. Legacy deployments without these keys preserve their previous enabled behavior.

> Glossary builds run **asynchronously**. Q&A can retrieve code while a large first build takes
> tens of minutes. Check `glossary_gen_done` / `glossary_gen_cc_failed` in host logs; the latter
> also covers OpenAI failures. A failed rebuild preserves the old glossary; a failed first build
> leaves no glossary yet. After an SDK switch, also verify that artifact metadata matches the new
> configuration; see [glossary switching](dual-sdk_en.md#glossary-switching).

On success you should see:

- Every phase of the shared base complete; per project, an `index-bridge-<project>` health line plus `bot-gateway@<project> is active`, and `deploy-all complete` overall;
- State written to `.local/deploy-config` (including per-project `RUNTIME_ARN_<project>`, `INDEX_SERVICE_IP`, …);
- That you can go straight to section 5 to verify (each project's gateway is already resident on the index host as `bot-gateway@<project>.service`).

Use an explicit action and project for unattended redeployment:

```bash
./scripts/install.sh --yes --action redeploy --project <projectId> --region ap-northeast-1
```

First-time interactive setup collects credentials. For scripted first deployment, prepare the manifest and secrets per Appendix A, then run `deploy-all.sh`.
Each `.local/deploy-config` belongs to one region; mismatches fail early. Use a separate checkout for another region.
Deployment automatically runs one generic code question (model charges apply). Exit `3` means deployed but unverified,
including a probe that cannot run and returns `2`;
`--no-probe` skips it. Projects containing only local repositories skip until code is uploaded.
> Tenant and language can also be given as flags to skip those prompts:
> `./scripts/install.sh --feishu-domain lark --locale en` (without the former, the interactive flow asks for the tenant; without `--locale`, `lark` defaults to `en` and `feishu` to `zh`).

### Manual deploy: install in place on a single EC2 (`--local`)

`--local` mode uses a single EC2 instance that both performs the deploy and stays resident afterwards (no separate deploy box). Keep that instance around long-term: the deploy state lives in its `.local/` directory, so upgrading means logging into the same machine and re-running.

**One command to start** — [`scripts/launch-host.sh`](../scripts/launch-host.sh) does the rest:

```bash
./scripts/launch-host.sh          # --profile <name> --region <r> skip the first two questions; --dry-run previews the plan
```

It runs these in order (fully automatic, each step idempotent): pick a profile → create / reuse the IAM role → for a private repository, take the local `gh` token and store it in Secrets Manager (see "GitHub credentials" below) → **create the source-truth-dedicated network automatically** (VPC + public/private subnets + IGW + NAT, reusing what already exists in the account, with no manual VPC / subnet selection) → create the security group (opens port 22 to your current egress IP only) → pick key pair / instance type / disk → launch one ARM64 EC2 instance in the public subnet with the instance role attached.

Once the instance exists, the script **prompts for the path to the SSH private key** (inferred by default as `~/.ssh/<selected key pair>.pem`), uses it to upload the deploy script [`scripts/lib/prepare-local-host.sh`](../scripts/lib/prepare-local-host.sh) to the EC2 instance, and **prints an `ssh` login command**. Log in with that command and run the script: it installs what `install.sh` needs (`aws` / `docker` / `git` / boto3), logs in to GitHub with the credential stored in step 1, clones the repository, and finally drops into the `install.sh --local` interactive flow (repositories / model / Feishu credentials). **The script deliberately does not auto-run** — you watch it step by step, and if something stops (preflight reporting a missing dependency, say) you can look into it right there; if the connection drops, reconnect and run it again to continue from where it stopped.

> If you leave the private key blank, or it cannot connect (key mismatch, instance not finished booting), launch-host prints three commands instead (`scp` upload + `ssh` login + the command to run once logged in) so you can finish by hand — also without the token in them.

A first deploy takes roughly 10–20 minutes (bootstrap and the image build both run serially on this machine, slightly slower than the one-command deploy).

**Re-running after an interruption**: every step is idempotent, so re-run from where it stopped — no need to start over. If the script is already on the instance, SSH in and run the `REPO_URL=… REPO_REF=… bash /tmp/prepare-local-host.sh` command that `launch-host.sh` printed (a bare invocation would fall back to upstream `main`) (or `cd source-truth && ./scripts/install.sh --local`) to continue. If the instance was created before the interruption, re-running `launch-host.sh` **reuses that instance automatically** (starting it first if it was stopped), prompts for the SSH key as usual, re-uploads the script and prints the login command — it does not create a duplicate. Add `--new-host` when you really do want a fresh instance.

**Four things to note**

- **GitHub credentials (required reading for private repositories)**: this EC2 instance clones the repository itself, downloads the codegraph binary (a private Release), and `git pull`s for later upgrades, so it needs GitHub access. `launch-host.sh` takes the local `gh` login token (or, if there is none, prompts you to paste a read-only PAT that needs only the repo:read scope) and stores it in Secrets Manager; `prepare-local-host.sh`, running on the instance, retrieves it through the instance role and persists it with `gh auth login` on the instance (stored in that machine's `~/.config/gh`, mode 600). Later upgrades and Release downloads carry the credential automatically, with nothing to pass again. **Public repositories can skip this** (leave the token blank when prompted). Revoke the token promptly when you replace or retire the instance.
- **Machine spec**: must be ARM64 (aarch64) on Ubuntu 24.04 (both the image and codegraph-server are ARM; x86 is rejected); the deploying user needs passwordless sudo. launch-host already sets IMDSv2 and hop-limit 1.
- **Broad permissions — dedicate the machine**: under `--local`, AWS calls use **this machine's instance role** (not your local profile, which is no longer available once you are on the EC2 instance). It needs both resource-creation and runtime permissions, so its **scope is fairly broad and this machine should not be shared with other workloads**. The role name `source-truth-index-role` is shared with the default deploy (IAM roles are account-level, not per-region): `create-iam.sh` reuses it idempotently, only adding permissions and never recreating it. Note, though, that **if a default deploy in the same account already uses that role, adding the deploy-time permissions grants them to that machine as well** — to keep the default deploy least-privilege, run `--local` in a different account.
- **Keep NAT in the current deployment topology**: the instance sits in a public subnet (with a public IP for SSH), while AgentCore Runtime uses a private subnet and reaches Bedrock through NAT. Its network interface has no public IP, so an IGW route alone does not provide internet access. The scripts create ECR and S3 VPC endpoints for image pulls; they do not configure a Bedrock Runtime endpoint. NAT, public IPv4, and interface endpoints have region-dependent charges; see the [service inventory](aws-services_en.md). The bridge ports (8080-8099) are open only to members of the same security group.

**Upgrading**: log into **the same instance** (all deploy state lives in its `.local/`) and run `cd source-truth && git pull && ./scripts/deploy-all.sh --region <r> --local`. The deploy updates this machine in place: it re-runs bootstrap to land the new base code, rebuilds the image, updates the runtime, and restarts the gateway and index service. The instance ID, private IP and the already-built graph.db are all preserved; no new instance is created. Service is interrupted while bootstrap re-runs and the services restart (about as long as a first deploy), so prefer an off-peak window.

## 3. Connecting Feishu / Lark

**Step 0 · Pick the tenant** (it decides which console every later step opens):

| Tenant | Open platform | Deploy flag | Default card language |
|---|---|---|---|
| Feishu · China (default) | <https://open.feishu.cn> | `--feishu-domain feishu` | `--locale zh` |
| Lark · international | <https://open.larksuite.com> | `--feishu-domain lark` | `--locale en` |

This choice has to be right **at the first deploy** (`install.sh` asks, and you can also pass it as a flag),
and it **must match the console you created the app in**: China-version and international apps are not
interchangeable. With the wrong tenant, the long connection and the REST calls target different tenants,
and the result is a bot that **authenticates successfully yet never receives a single event** — @-mentioning
it in a group does nothing at all, and no message-received event appears in the logs.
`--locale` sets the language of cards and prompts (`zh` / `en`); when it is not given, `--feishu-domain lark`
defaults to `en` and `feishu` defaults to `zh`.

Below, `<open-platform>` stands for your side's address (`open.feishu.cn` for China, `open.larksuite.com` for international).

Configure the app on `<open-platform>` ([Feishu](https://open.feishu.cn) / [Lark](https://open.larksuite.com))
in this order (later steps depend on earlier ones: the bot capability must be enabled before the
message-sending permission takes effect, and permissions / events / bot must all be configured before you
publish a version to make them live):

1. **Create a custom app for your organisation**: "Developer console" → "Create app" → "Custom app". Once created, note the `App ID` (`cli_...`) and `App Secret` on the "Credentials & basic info" page.
2. **Enable the bot**: turn on the bot capability on the "Bot" page. You do NOT need to copy an `open_id` from this page — it shows the app identity, not an `ou_`-prefixed open_id, so there is nothing there to copy. `install.sh` derives `FEISHU_BOT_OPEN_ID` automatically from `/open-apis/bot/v3/info` using the credentials it has just validated, and prompts only if that call fails. The value decides whether the account @-mentioned in a group is this bot; left blank, ANY @-mention triggers the bot. **Enable the bot first, or the message-sending permission below cannot take effect.**
3. **Permissions (scopes)**: grant the following under "Permissions" (a missing one makes the corresponding feature fail silently):
   - `im:message`, `im:message.group_at_msg`: read messages that @-mention the bot in a group;
   - `im:message:send_as_bot`: send / reply / add the "processing" reaction as the bot (calls `im/v1/messages` and its `reactions` sub-endpoint — reactions are covered by the messaging permission and need no separate resource scope);
   - **CardKit cards**: grant `cardkit:card:write` ("Create and update cards" / 创建及更新卡片).
     The gateway calls `POST /open-apis/cardkit/v1/cards` plus the `settings` and `elements`
     PATCH endpoints. Without this scope the deploy still reaches READY and events still
     arrive, but every card creation returns 403 — the bot looks silently dead. If the console
     shows a different name for it, search "card" under "Permissions" and grant the create/update
     card scope.
4. **Event subscription**: choose **long connection** mode (not webhook — this system holds a resident subscription and exposes no public callback), and subscribe to two events:
   - `im.message.receive_v1`: a group message was received;
   - `card.action.trigger`: a card button was clicked (stop / follow-up / clarify).
5. **Create a version and publish it**: changes from steps 2–4 only take effect once published (internal approval is usually self-service). A draft that is saved but not published leaves the bot unresponsive.

After publishing, two more things remain (unrelated to the Feishu console, in either order):

- **Add the bot to the target group.** (Nothing asks you for the group's `chat_id` — it arrives on the inbound event.)
- **Hand the credentials to the installer**: the `App Secret` is sensitive and **never goes into the repository**. The "add project" flow of `install.sh` in section 2 asks for the `App ID` and `App Secret` (deriving the bot `open_id` itself) and writes all three into **Secrets Manager** for you (one secret per project, named `source-truth/feishu-<projectId>`); at gateway start `run.sh` fetches them and injects them into the process environment, never to disk. Just paste when prompted — no need to create the secret by hand.

  > Managing it manually (without install.sh): create a Secrets Manager secret whose value is the JSON
  > `{"app_id":"...","app_secret":"...","bot_open_id":"..."}`, with a name starting with `source-truth/`
  > (IAM is granted on that prefix), then put the name in the project's `feishuSecretId` in
  > `.local/projects.json` (or set `FEISHU_SECRET_ID=<secret name>` at deploy time).

---

## 4. Where the gateway runs

After deploying through `install.sh` (or the gateway phase of `deploy-all.sh`), every project's gateway runs
resident on the index-service EC2 instance as **`bot-gateway@<project>.service`** (a systemd template unit,
e.g. `bot-gateway@mangos.service`) — there is no separate process to start.
Common operations (replace `<project>` with the real projectId):

```bash
# Gateway status / logs (into the instance over SSM):
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
#   sudo systemctl status 'bot-gateway@*'              # every project's gateway
#   sudo tail -f /var/log/bot-gateway-<project>.log     # expected: sdk_wsclient_started → sdk_wsclient_connected
#   (the unit uses StandardOutput=append: to write the file directly, so journalctl -u only holds
#    start/stop records and not the application log; the CloudWatch agent also ships this file to
#    /source-truth/bot-gateway)
#   curl -s 127.0.0.1:$(grep HEALTH_PORT /etc/bot-gateway-<project>.env | cut -d\' -f2)/ready
#     # readiness probe: 200 = long connection established; 503 = starting / reconnecting / shutting down gracefully (see section 5)
```

> **Only one gateway instance may connect for a given Feishu app**: the Feishu long connection is a cluster
> mode where each event is delivered to exactly one client, so running two gateways for the same app (for
> example an extra local one) makes them fight over events and behave erratically. When debugging locally,
> stop the corresponding service on the instance first.

For running the gateway locally (development), see [Appendix B](#appendix-b-running-the-gateway-locally-development).

**Retire a gateway in an old region**: on the old host run
`sudo systemctl disable --now bot-gateway@<project>.service`, then inspect
`sudo systemctl show bot-gateway@<project>.service -p ActiveState -p UnitFileState -p MainPID`.
Require inactive, disabled and MainPID=0. EC2 and Runtime resources remain. Do not run a subsequent
deployment that enables or restarts the retired project.

---

## 5. Verification (end-to-end smoke test)

Run the machine-checkable step (1) first, then the two health endpoints from inside the instance (2, 3), and only then confirm by hand in a group (4).

1. **Offline suite + real end-to-end probe** (on the deploy machine; no need to enter the instance):

   ```bash
   ./scripts/test.sh --full        # offline suite (lint + unit + typecheck) + the e2e probe
   ```

   `--full` invokes `scripts/e2e-probe.py`. You can also run it on its own — the exit code is the verdict:

   ```bash
   python3 scripts/e2e-probe.py   # 0 = all probes passed; 1 = a probe failed; 2 = cannot run (missing dependency / not deployed / no projects.json)
   ```

   The probe takes **exactly the same invoke path as the gateway** (boto3 `InvokeAgentRuntime` with an
   identically shaped payload) and checks: the stream is non-empty and an answer can be parsed out,
   `permission_denials` is empty (the read-only boundary was not breached), and the answer carries a
   `file:line` citation. Deployment `--smoke` also requires a successful `codegraph_read_file` /
   `codegraph_read_table` completion event; refusal or a filename alone is insufficient. Unknown/mixed
   normalized streams, missing terminal events and reported errors fail. Treat `2` as a skip rather than a failure — `--full` is not blocked by it on an
   offline or not-yet-deployed machine.

2. **Backend health** (checked from inside the index-service instance; `8080` is the first project's port, other projects use their `port` from `projects.json`):

   ```bash
   aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
   # once logged in:
   curl -s -w '%{http_code}\n' http://127.0.0.1:8080/health   # expect 200 + healthy:true
   ```

   > **Do not add `-f` here**: on a non-2xx response `-f` prints no body and exits 22 — and the status code
   > is exactly what you came to read.
   > `/health` binds **`127.0.0.1` only** (by design); it is unreachable from outside the VPC and even from
   > other machines in the same VPC, so you have to be on the instance.

   > A local-repository project needs Quick Start step 3 (push the code) first; until then `/health` is not 200 and the bot answers "not found" — that is the normal pre-push state, not a fault.

3. **Gateway health** (same instance; the port is that project's bridge port + 10000, so `18080` for the first project. `activate_gateway.sh` writes the value per project into `HEALTH_PORT` in `/etc/bot-gateway-<project>.env`; when unsure, `grep HEALTH_PORT` that file first):

   ```bash
   curl -s 127.0.0.1:18080/health   # liveness: 200 whenever the process is alive; read wsState in the body
   curl -s -w '\n%{http_code}\n' 127.0.0.1:18080/ready   # readiness: expect 200 + "wsState":"connected"
   ```

   `/ready` returns 200 only when the Feishu long connection is established and the process is not shutting
   down gracefully; otherwise 503 — this is the fastest way to tell whether the long connection actually
   works, more direct than reading logs. `/health` stays 200 during a reconnect (deliberately: an SDK
   reconnect takes two seconds and is no reason to restart).
   Both routes likewise bind `127.0.0.1` only and are unreachable from outside the VPC.

4. **@-mention the bot in a group** and ask something (e.g. "how is equipment durability calculated?"). Expected:
   - a card appears within seconds, its title carrying a live timer (thinking → analysing → done);
   - the conclusion comes first, in business language, with a collapsed "for engineering review" section at the bottom listing `file:line` sources;
   - a successful answer grounded in code ends with a follow-up heading and 2–3 question buttons, including short answers. A reply-only hint does not pass this check. Clicking a question or replying to the card should carry the previous context into the next answer.
   - the first cold start (a new microVM) is slower (it includes MCP registration); that is normal.

> The only mechanical gate in this repository is CI: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
> (on push to main / every PR / manual dispatch) installs the dependencies, runs `scripts/test.sh`, and fails
> if any sub-suite was skipped. There is **no** pre-commit / pre-push hook (and no gitleaks hook) — running
> the suite locally is on you; the gate is CI.

---

## 6. Day-2 operations

> The aggregated ops command `ops.sh status` is not implemented yet (planned, p2); use the manual commands below for now.

**Code changed — refresh the index**: **nothing to do by hand.** Each repository is `git pull`ed by a systemd
timer on its `refreshIntervalSec` (300 seconds by default), and the resident codegraph file-watcher rebuilds
that repository's in-memory graph incrementally within seconds — no restart, no interruption. To change the
frequency, edit `refreshIntervalSec` for that repository/project in `.local/projects.json` and "redeploy that
project". Multi-project deploys are covered in section 7.

**Upgrading the index service's own code** (bridge / gateway and their dependencies, unrelated to the target
code): `git pull` on the deploy machine, then re-run `deploy-all.sh --region <r>`. The index host is
**updated in place** — when the deploy sees that the base-code artifacts in S3 changed, it re-runs
`bootstrap.sh` on the same instance over SSM. The instance ID, private IP, EBS volume and the already-built
graph.db are all preserved; no new instance, no DNS switch. The bridge and gateway restart during the re-run,
so there is a brief interruption; when the artifacts have not changed, the deploy reuses them and does
nothing extra. Changing the instance type is out of the deploy's scope (it never replaces the instance): do
it yourself with `stop` → `modify-instance-attribute --instance-type` → `start`. Re-deploying with
`--instance-type` only warns when the type does not match.

**Changing the glossary switch or cap:** use `install.sh --action redeploy --project <project> --with-glossary --glossary-max-files <n>`.
Both settings participate in the deployment signature, so they reach the host even without source changes, and other projects on that host receive the updated configuration.
The installer persists unsuccessful project updates in `DEPLOY_GLOSSARY_PENDING_PROJECTS` inside
`.local/deploy-config` and retries them on the next run. A project returning `3` after its configuration
was applied is not redeployed solely because its Q&A probe failed.
Applied values are persisted only after success, so a failed run remains retryable. The current implementation re-runs bootstrap in place, causing a few minutes of gateway downtime while preserving the instance, repositories and index.
There is no need to edit `/etc/index-service.env` manually.

**Redeploying only the runtime** (after changing the agent image / system prompt): re-run `deploy-all.sh` (the image and runtime phases are idempotent).
Existing microVMs retain their image until reclaimed. The gateway restart clears cached session IDs,
so subsequent questions start new sessions with the updated Runtime; a running request may still use the previous image.

**Tuning microVM lifetime (follow-up hit rate vs cost)**: `deploy-all.sh --idle-timeout <seconds>` (default 900,
i.e. 15 minutes; range 60–28800). The flag sets both AgentCore's `idleRuntimeSessionTimeout` and the gateway's
session-reuse TTL, keeping the two aligned automatically.
AgentCore charges no CPU while idle but still charges memory. A larger value keeps microVMs alive longer and
raises the chance a follow-up lands on a live instance, at the cost of paying for that idle memory.
Most sessions end after a single question, hence the 15-minute default; raise it for follow-up-heavy usage
(support-desk style, high frequency) and lower it when cost matters more.
See "Runtime tuning and cost trade-offs" in [`agent/architecture.md`](agent/architecture.md) (Chinese only).

**Reading the gateway log** (one `bot-gateway@<project>.service` per project; structured JSON logs go to `/var/log/bot-gateway-<project>.log`):

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# on the instance: sudo tail -f /var/log/bot-gateway-<project>.log   # the application log is in the file, not journald
#                 sudo systemctl status bot-gateway@<project>        # use this only for unit status
```

Key events (gateway side): `invoke_start` (runtime invocation began), `card_sent` (card sent),
`card_closed` (one Q&A finished), `reply_context_replayed` (a follow-up carried prior context),
`followup_suggestions` (`count` is the extracted question count; `markerPresent` distinguishes a missing heading from extraction failure, without logging question text),
`card_write_dropped` / `finalize_error` (card write failed), `invoke_http_error` (non-200 from the backend).
Key events (agent microVM side, same traceId): `agent_run_start` (run began; records promptChars / repos / model),
`tool_call` (a tool call started), `tool_latency` (duration of each tool call).

**Following one traceId across the whole chain (gateway + agent microVM, merged timeline)**: a single Q&A spans
two log groups (the gateway's `/source-truth/bot-gateway` and the agent's
`/aws/bedrock-agentcore/runtimes/<runtime>-DEFAULT`), correlated by the same `traceId`. One command queries
both sides and merges them — all you supply is the traceId (region, both log groups, time range, query and
ordering are handled for you):

```bash
./scripts/trace.sh st-0123456789abcdef0123456789abcdef   # example value — replace it with the real traceId from the card footer or an answer_* log line
#   --since-hours N (default 6) widens the look-back window; --raw skips the merge and prints both sides as-is
#   --runtime <id> names the AgentCore runtime id (by default derived from RUNTIME_ARN_* in .local/deploy-config;
#     with several projects it takes the first and says so, so pass this flag to query another one)
```

Output is merged by time, tagged `GW`/`AGT` by source, with key fields extracted automatically (status /
detail / error / reason / tool / latencyMs / ttfbMs / numToolCalls / toolErrors / turnCount /
evidenceCitationCount / num_turns / cache_read). For "the card failed but I cannot tell which leg broke"
problems such as a backend 403 or timeout, this pins it to the gateway, the invoke, or the agent side.

**Reading the index-service log** (same instance):

```bash
aws ssm start-session --region <r> --target <INDEX_SERVICE_INSTANCE>
# on the instance: journalctl -u index-bridge-<project> -f   (index-build logs live in the index-build@<repo> unit)
```

**Restarting the gateway** (on the instance): `sudo systemctl restart bot-gateway@<project>`. After changing the
Feishu credentials, re-running `install.sh` (or the deploy's gateway phase) rewrites
`/etc/bot-gateway-<project>.env` and restarts the service.

**Monitoring: metrics / dashboards / alarms** — when `--with-monitoring` is enabled, phase 7 of `deploy-all.sh` deploys the whole set
(CloudWatch metric filters, a three-page dashboard, alarms + SNS, the DAU pre-aggregation Lambda), and
**normally needs no manual intervention**. The exception is the **first deploy**: while the gateway has not
written a log yet and the log group does not exist, the metric filters and alarms cannot be created (the
deploy only WARNs, it does not fail) — ask one question in a group, then re-run the deploy (or the commands in
[Appendix D](#appendix-d-refreshing-monitoring-by-hand)) to fill them in. Beyond that, run it by hand only to
refresh a dashboard/threshold on its own, or to catch up after deploying with `--skip monitoring`. The alarm
SNS subscription must be confirmed once by hand (click the link in the email).

Key alarms: `ToolcallLeakDetected` (tool-call instruction text leaked into a card), `FinalizeFailed` (a card
never closed properly and is stuck at "analysing"), `AnswerFailedBurst` (answer failure rate spiking),
`LogPipelineStalled` (the gateway emits a `gateway_heartbeat` log line every 60 seconds and the alarm only
fires when the heartbeat stops — a broken log pipeline or a sick gateway; the heartbeat continues through idle
nights, so it does not false-alarm).

**Removing deployment resources**: when you are done trialling, or a deploy failed midway and left
billable resources behind (NAT, public IPv4, EC2, and the two ECR interface endpoints), one command cleans up in reverse-dependency order:

```bash
./scripts/teardown.sh --region <r> --dry-run     # review what would be deleted; touches nothing
./scripts/teardown.sh --region <r>               # delete after interactive confirmation (type yes)
./scripts/teardown.sh --region <r> --include-shared   # also delete the IAM roles + S3 bucket (account-shared)
```

Resources are read from `.local/deploy-config`, falling back to discovery by the `source-truth-*` tags (which
is why leftovers from a failed run can be cleaned up too). When it finishes it prints a command to confirm no
billable NAT was left behind. Destructive and irreversible.

---

## 7. Multiple projects (several bots on one host)

One index host can carry several mutually isolated projects: bot (its own Feishu app) ⟷ project is
one-to-one, project ⟷ repository is one-to-many.
Projects are logically isolated (separate processes + ports + a server-side scope, tier A), which is enough
for mutually trusting projects in one team; projects that do not trust each other should still use separate machines.

**The single place they are declared** is `.local/projects.json` (never committed). One entry per project:
`port` (that project's bridge port, unique on the host), `feishuSecretId` (generated by "add project" —
**do not fill it in by hand**), `repos` (per repository `{subdir, source?, git, ref?, refreshIntervalSec?}`,
where `source` defaults to `git` and a local repository uses `local`). The top-level `refreshIntervalSec` is
the global default refresh interval. The project's `agent` object selects the SDK, answer model
and glossary model; see [SDK configuration and migration](dual-sdk_en.md). Before redeploying a
shared host, reconcile the complete project inventory with `/etc/source-truth-projects.json`.

Everything is driven from the arrow-key menu of `./scripts/install.sh`:

- **Initialize environment (no project)**: brings up only the shared base (VPC/NAT/EC2/image) with no project attached. Good for standing up the AWS environment first and attaching projects later with a git URL and credentials (i.e. "deploy the environment first, configure git afterwards").
- **Add project**: interactively enter the projectId → add repositories one by one (per repository choose git or local: a git repository takes a URL + branch; for a local repository choose local and push with push-local-repo.sh) → the index-service port (the next unused value is suggested)
  → the Feishu app credentials (written automatically to `source-truth/feishu-<project>`) → on the first run it also takes a **read-only git credential** and writes it to the global `source-truth/git-credentials` (reused by later projects). It then writes the manifest and deploys that project (others are untouched).
- **Redeploy an existing project**: after changing a project's repository set / port / refresh interval, select it and redeploy (idempotent).
- **Delete project** (destructive; requires typing the project name to confirm): stops and deletes that project's bridge/gateway/runtime, every repository's code copy (including a local repository's `.incoming` staging directory) and its glossary, then removes it from the manifest.
  The Feishu secret is kept by default (you are asked separately whether to delete it), and **the global git credential is never deleted**; other projects are unaffected.

**Code sources**: git repositories and local repositories ([prerequisite 4](#1-prerequisites-one-time),
[Local-repository upload](#local-repository-upload)); S3 is not supported. A private git repository needs that
one read-only credential (a GitHub/GitLab PAT or a deploy key, shared by all repositories). The index host
clones/pulls from its private subnet through NAT.

Troubleshooting a specific project: on the host every unit name carries the project/repository —
`index-bridge-<project>.service`, `bot-gateway@<project>.service`, `index-refresh-<repo>.timer`,
`index-build@<repo>.service`; logs via `journalctl -u <unit>`. Each project's bridge is on its own port
(`curl 127.0.0.1:<port>/health`).

> Using `deploy-all.sh` directly (without install.sh): it brings up the shared base and then walks
> `.local/projects.json` deploying each project; `--skip-projects` brings up only the base. But **the Feishu /
> git credentials must already exist in Secrets Manager** — only install.sh's "add project" creates those
> interactively, so always go through install.sh the first time for a new project.

---

## 8. Troubleshooting (symptom → cause → action)

| Symptom | Likely cause | Action |
|------|----------|------|
| The deploy reports success, but every question comes back with no content (empty answer / "not found") | **The runtime-to-bridge leg may be blocked** — check the deployment smoke result; `--no-probe` or a skipped local-repository probe leaves this path unverified | Check these three in order: ① does the security group the runtime uses allow **8080-8099** to the index host; ② does a route from the private subnet to **NAT** exist (the Runtime's ENI is AWS-managed with no public IP, so it must go through NAT); ③ does the private domain resolve — run `dig +short index.<r>.source-truth.internal` on the instance; an empty answer points at the private hosted zone / VPC DNS attributes (see [Appendix C](#appendix-c-on-host-checklist-after-the-first-deploy)) |
| The card stays at "analysing…" and never finishes | The backend stream was interrupted / finalize threw | Look for `finalize_error` / `card_closed failed:true` in the gateway log; if occasional, ask again, and if persistent check runtime / index health |
| Stray `<invoke>` code markers appear in the card | On that cold-start question the underlying code-retrieval tools were not ready yet and the agent answered too early | The gateway retries once automatically and it stops happening once warm. Check `num_turns`/`cache_read` in the log to confirm it was a cold start |
| The bot is **completely unresponsive** in the group | Gateway not started / the bot was not actually @-mentioned / two gateways for the same app fighting over events / **wrong tenant** (the app lives in international Lark but was deployed as China Feishu, or vice versa) | On the instance start with `curl -s -w '%{http_code}\n' 127.0.0.1:<HEALTH_PORT>/ready` (the port is in `/etc/bot-gateway-<project>.env`): 503 means the long connection is not up; then `systemctl status 'bot-gateway@*'` to confirm active plus `sdk_wsclient_connected` in the log; confirm the account @-mentioned is `FEISHU_BOT_OPEN_ID`; stop the extra gateways and keep exactly one. If authentication succeeded (a token was obtained) yet no message event ever arrives, check the tenant: `grep -E 'FEISHU_API_BASE\|LOCALE' /etc/bot-gateway-<project>.env`, compare with the console the app was created in, and redeploy with the correct `--feishu-domain` if they disagree (see [section 3](#3-connecting-feishu--lark)) |
| The gateway did not start, reporting `condition failed` | `/etc/bot-gateway-<project>.env` has not been written yet (runtime not ready / the gateway phase was skipped) | Re-run `install.sh` or `deploy-all.sh` (without skipping gateway); confirm `FEISHU_SECRET_ID` is set |
| The card answers "query failed" / the log shows `AccessDenied` | The calling Runtime/index role lacks model access, or the profile is unavailable in this region | Identify the failing role and grant the selected profile/model invocation permissions; deployer access does not prove Runtime access. See prerequisite 3 and [SDK configuration](dual-sdk_en.md) |
| The deploy times out in the index-service phase | NAT routing has not converged in a brand-new account / the instance is still cold-starting and building the index | Wait one more round (bootstrap retries network operations); check `/var/log/` and `journalctl -u 'index-build@*'` |
| `/health` is non-200 for a long time | Corrupted index / empty graph.db / a worker restarting repeatedly | On the instance read the index-bridge-<project> log; if the base code is behind, re-run `deploy-all.sh` (it re-runs bootstrap in place, leaving the instance and graph.db alone); if the graph really is corrupted, run `sudo systemctl start index-build@<repo-subdir>` on the instance to rebuild that repository's graph in full. Note: before its first `push-local-repo.sh`, a local repository legitimately has an empty graph and a non-200 `/health` — normal, and resolved once the code is pushed |
| Every question returns `HTTP 424 Runtime health check failed`, failing in about 3 seconds, while `/health`, the bridge and the gateway's long-lived connection are all green | **The container never started** — the image pull failed. This looks more like an application fault than anything else, but no layer of the application ran. Two causes have been seen: (1) the NACL's ephemeral return range topped out too low (the AgentCore microVM picks source ports above 60999); (2) the NAT-to-internet path to ECR timing out intermittently | Read the runtime's own log group first — a pull failure is stated explicitly there: look for `Failed to pull image` and `i/o timeout` in `aws logs filter-log-events --log-group-name /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT --start-time <ms>`. Then check the VPC endpoints are all present and available: `aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=source-truth-vpce-* --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,State,PrivateDnsEnabled]'` — all three must exist, and `PrivateDnsEnabled` must be `true` on the interface ones (otherwise the endpoint bills without intercepting anything). Re-running the deploy's network phase converges it. From inside the subnet you can confirm resolution lands on the endpoint's private IP: `getent hosts api.ecr.<region>.amazonaws.com` should return `10.1.1.x` |
| Behaviour is still the old version after redeploying | microVMs still alive keep using the old image (about 15 minutes) / the gateway was not restarted | Wait for that microVM to be reclaimed; restart the gateway to be sure it runs the new code |
| Chinese questions do not pick up project-specific naming / the glossary looks empty | The background glossary build has not finished or failed (selected SDK dependencies missing / Bedrock unreachable or unauthorized) | On the instance read `journalctl` and `/var/log/glossary-build-*`, looking for `glossary_gen_done` (success) / `glossary_gen_cc_failed` (build failed); Q&A is unaffected and falls back to ordinary retrieval |

> Exclusive-write constraint: only one process may write index-service's graph.db at a time; concurrent writes
> corrupt it down to 0 nodes. The service layer guards this with flock + an in-process lock + an orphan reaper;
> **do not** start another codegraph-server by hand on the instance against the same graph.

---

## 9. Boundaries and security (must-know)

- **Read-only**: throughout the MVP nothing writes code, commits, or runs the engine; answers are based only on the real code of the latest main branch, cross-checked against CodeGraph.
- **Secrets**: the Feishu `App Secret`, `App ID` and the like never enter the repository; they travel through environment variables / Secrets Manager / SSM.
  The mechanical check lives in **CI** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)): it installs
  the dependencies, runs `scripts/test.sh` (which includes `scripts/check-invariants.sh` and its structural and
  publication-content checks), and fails if any sub-suite was skipped.
  There is **no** pre-commit / pre-push hook in this repository, and no gitleaks hook — whether you run the
  suite locally before committing is up to you; the gate is CI.
- **Out-of-scope capabilities are deferred**: multiple branches, reading design documents, writing back, a second engine and so on are all post-MVP; see "Scope" in [`../README.md`](../README.md) and the design source of truth in [`design/`](design/).

### Local-repository upload

Code that cannot be pushed to a git remote is declared as a local repository (`{subdir, source:"local"}` in
`projects.json`; choose "local repository" when adding the project in `install.sh`). It does not sync
automatically — **push once per change**; the push *is* the refresh. On **your own machine**:

```bash
./scripts/push-local-repo.sh --host <ec2-ssh-host> [--identity <key>] <subdir> <local-repo-path>
```

**How to confirm success**: the command prints `REINDEX_LAUNCHED`, meaning the code is uploaded and the rebuild
has moved to the background (it does not block the command, and an ssh disconnect does not affect it). The
rebuild is finished when `REINDEX_DONE` appears in the background log:

```bash
sudo journalctl -u reindex-<subdir> -f          # or sudo tail -f /var/log/reindex-<subdir>.log
```

- **An ordinary push does not interrupt service**: the code syncs incrementally in place, the watcher updates the index within seconds, and the gateway stays online throughout (the same flow as a git repository's `git pull`). **The first push is the exception**: no index exists yet (a local repository's index build is deferred during a `--local` deploy), so the gateway is stopped, one complete index build runs, and then it starts again; the index build and the glossary build run in parallel. That project is briefly offline in the meantime and starts serving once the index build completes.
- **An interrupted push is recoverable**: an interruption only leaves the staging directory `/data/repo/<subdir>.incoming` behind and does not affect the code currently in use. If `sudo ls -d` still shows that directory, the last push did not finish — push again to recover. `sudo cat /data/repo/<subdir>/.snapshot-time` is the timestamp of the last successful push.
- **The glossary** (Chinese term → code symbol) refreshes incrementally in the background with each push; the log is `/var/log/glossary-build-<projectId>-<subdir>.log` (`glossary_gen_done` means success, `glossary_gen_cc_failed` means `cc` failed without affecting Q&A). When the host has no Bedrock access the glossary is skipped and only the index is updated.
- **Safety constraints**: `rsync --delete` keeps the host copy identical to your local one (files you deleted locally are deleted on the host too); `.git` is excluded; symlinks are refused (`--safe-links --no-links`); only `--identity <key>` is accepted, with no arbitrary `--ssh-opts` (to prevent command injection). The first connection trusts the host key with `accept-new`; verify the fingerprint out of band beforehand (for example against the system log in the AWS console) so a spoofed host cannot capture your source code.

**Minimal sudoers** — allow this one script only (creating the staging directory, swapping it in, and the
rebuild all happen inside the script; arguments are first validated against `^[a-z0-9][a-z0-9-]*$` and the
systemd unit names are hard-coded):

```
# /etc/sudoers.d/source-truth-push  (push user only)
<pushuser> ALL=(root) NOPASSWD: /bin/bash /opt/idx/app/reindex_local_repo.sh *
```

Here `/bin/bash <fixed script path> *` narrows the executable surface to that one script, with `*` opening up
only its arguments. **Do not** write a bare `/bin/bash *` (equivalent to allowing any command), and do not add
general-purpose commands such as `systemctl`/`mkdir`/`chown` to NOPASSWD — their wildcards can be worked around
with things like `-R` and `..`, escalating to root.

---

## Appendix A: deploy-all.sh by hand

`install.sh` is the interactive front end for `deploy-all.sh`. Repositories **no longer go on the command
line** — they are declared in `.local/projects.json` (per repository, either a git or a local source), and
deploy-all brings up the shared base and then walks them. Calling it directly:

```bash
# Shared base + every project in .local/projects.json. Idempotent, repeatable, works on a new account.
./scripts/deploy-all.sh --region ap-northeast-1 [--instance-type t4g.large] [--root-volume-gb 30] [--model <default id>] \
  [--feishu-domain <feishu|lark>] [--locale <zh|en>]

# Shared base only, no projects (init-env):
./scripts/deploy-all.sh --region <r> --skip-projects

# Print the plan only, touch nothing:
./scripts/deploy-all.sh --region <r> --dry-run

# Skip a phase (repeatable): artifacts|iam|network|index-svc|image|projects|monitoring
# (runtime and gateway are folded into the projects phase — --skip projects skips them together)
./scripts/deploy-all.sh --region <r> --skip monitoring

# Deploy/redeploy a single project (the shared base must already be up):
./scripts/lib/deploy_project.sh <r> <projectId>
```

The remaining flags (all combinable with the above):

| Flag | Default | Effect |
|------|------|------|
| `--feishu-domain <feishu\|lark>` | `feishu` | Feishu tenant: `feishu` = China (`open.feishu.cn`), `lark` = international (`open.larksuite.com`). **Must match the console the app was created in**; it drives both the event long connection and the REST base URL, and getting only one of them right yields a bot that authenticates and then never receives events. Get it right at the first deploy (see [section 3](#3-connecting-feishu--lark)) |
| `--locale <zh\|en>` | Follows the tenant: `en` with `--feishu-domain lark`, otherwise `zh` | Language of cards and prompts. Written as `LOCALE` in `/etc/bot-gateway-<project>.env` |
| `--max-files <n>` | 10000 | Cap on files codegraph indexes per repository |
| `--with-glossary[=true\|false]` | Off for new environments | Enable or disable background glossary generation; legacy choices are preserved |
| `--glossary-max-files <n>` | `400` | Per-repository cap when glossary is enabled; `0` is unlimited. Changes are automatically applied |
| `--with-monitoring[=true\|false]` | Off for new environments | Enable monitoring deployment; disabling does not delete existing resources |
| `--no-probe` | Not skipped | Skip the real post-deployment code question |
| `--idle-timeout <seconds>` | 900 | microVM idle-reclaim time (60–28800); also aligns the gateway's session-reuse TTL |
| `--max-lifetime <seconds>` | 28800 (8h) | Hard ceiling before a microVM is force-reclaimed (60–28800); semantics in [`agent/architecture.md`](agent/architecture.md) (Chinese only) |
| `--force` | off | Skip phase 0's hard-blocking preflight (an insufficient vCPU quota, say), treating the operator as having confirmed. Use only when the increase is already granted, or you know the check result is stale |

**Precondition**: the Feishu secret named by each project's `feishuSecretId` in `.local/projects.json`, plus the
global `source-truth/git-credentials` (the read-only credential for private repositories), **must already exist
in Secrets Manager**. Only `install.sh`'s "add project" creates those interactively, so **always go through
install.sh the first time for a new project**; deploy-all only consumes them.

## Appendix B: running the gateway locally (development)

In a normal deployment the gateway runs on the index host (see section 4). For local debugging you can run the
TypeScript directly:

```bash
cd bot-gateway
npm install
export AWS_REGION=ap-northeast-1
# The deploy writes RUNTIME_ARN_<project> (with - in the project name replaced by _) into .local/deploy-config; take the one you want to debug:
export RUNTIME_ARN="$(grep '^RUNTIME_ARN_<project>=' ../.local/deploy-config | cut -d= -f2-)"
export FEISHU_APP_ID=cli_xxx
export FEISHU_APP_SECRET=xxx            # never commit this
export FEISHU_BOT_OPEN_ID=ou_xxx
# Optional: LOG_HASH_SALT, MAX_CONCURRENT_INVOKES (default 8), LOCALE (zh|en; in a real deployment
#   written by activate_gateway.sh from --locale / the tenant)
# Optional: HEALTH_PORT — the health endpoint port (binds 127.0.0.1 only). When unset it is derived as
#   bridge port + 10000 (8080 → 18080); in a real deployment activate_gateway.sh writes it per project
#   into /etc/bot-gateway-<project>.env, and the systemd unit's start-up probe reads the same value.
#   Endpoint semantics (/health = liveness, /ready = readiness) are in section 5
node_modules/.bin/ts-node --transpile-only src/index.ts
```

> Note: only one gateway may connect for a given Feishu app. Before starting one locally, stop the
> corresponding project's service on the index host (`sudo systemctl stop bot-gateway@<project>`), or the two
> gateways will fight over the same events.

## Appendix C: on-host checklist after the first deploy

The smoke test in section 5 (`test.sh --full` / `e2e-probe.py` + `/health` + asking one question in a group)
confirms the main path works. This checklist is finer-grained and is meant for going through item by item
**after a first deploy in a new account or a new region** — it focuses on the few links that no static check or
offline test can cover and that have to be verified on a real machine, some of which may not actually work even
though the deploy reported success (a manual `--local` deploy especially). Repeat deploys do not need it every
time. In the commands, `<r>` = region and `<I>` = the index host's instance id (from `INDEX_SERVICE_INSTANCE`
in `.local/deploy-config`).

**Must verify (before handover)**

| Item | How to confirm | What failure looks like, and what to do |
|---|---|---|
| **You can SSH into the newly created machine** (`--local`) | `ssh ubuntu@<public-ip>` connects | Refused/timeout → the source the security group opened port 22 to is not your real egress IP (`launch-host` obtains it with `curl checkip`, which can be wrong behind NAT or a proxy). Add a rule for your current IP on port 22 to that security group in the console |
| **The Runtime reaches Bedrock and connects to the bridge** | Ask a question in the group; the card answers with `file:line` sources | Stuck at "query failed" or timing out → the route from the private subnet to NAT is broken, or the security group the runtime uses does not allow 8080-8099. An empty answer (while the deploy reported success) → see section 8, "The deploy reports success, but every question comes back with no content", and work through SG 8080-8099 / the NAT route / private-domain resolution in that order |
| **The deploying identity has enough permissions** (after `--local` reuses the role) | `deploy-all --local` reaches the runtime's `InvokeAgentRuntime` without AccessDenied | Stuck in the runtime phase with AccessDenied or a refused PassRole → the role lacks `bedrock-agentcore:*` or `iam:PassRole` for `SourceTruthAgentRuntimeRole` (see prerequisite 3 and the `--local` permission notes) |
| **The private domain resolves** (**only** for a hand-built VPC, or when `modify-vpc-attribute` was denied during the deploy) | Enter the instance (`aws ssm start-session ... --target <I>`) and run `dig +short index.<r>.source-truth.internal`; it should return a private IP | On both topologies the deploy explicitly runs `modify-vpc-attribute --enable-dns-support` and `--enable-dns-hostnames` on that VPC (during the network phase for the default topology, and when reusing the local VPC under `--local`), so this item usually no longer needs a manual check. Verify that both attributes are true only when you built the VPC by hand, or the deploy log shows a permission error on either of those two `modify-vpc-attribute` calls |

**Verify when onboarding the first new repository**

| Item | How to confirm | Notes |
|---|---|---|
| **First push of a local repository** (bridge stopped, full index build) | Run `push-local-repo.sh` and see `REINDEX_LAUNCHED`; then check the background log `sudo journalctl -u reindex-<subdir>` (or `/var/log/reindex-<subdir>.log`) for `REINDEX_DONE ... mode=initial-build`, that `graph.db` is at least 64KiB, and that the bridge started | The index build and the glossary build run in parallel in the background; GBK encoding problems in a Chinese repository also surface for the first time at this step |
| **Incremental push of a local repository** (bridge not stopped) | Change a few files and push again; the background log shows `mode=incremental` and Q&A picks up the new code seconds later | The gateway is never interrupted; the glossary refreshes incrementally in the background (check `/var/log/glossary-build-*`) |
| **Recovery after an interruption** | Break the network or Ctrl-C during a push; the `.incoming` staging directory is still there, and one more push restores the complete state | Details in the interruption notes of section 9, "Local-repository upload" |
| **The codegraph binary works** | `codegraph-server --version` passes in the bootstrap log | An architecture or glibc mismatch fails loudly and exits (verified in Tokyo; low risk) |

**Good to know (does not block handover)**

- **The first question after a cold start**: a new microVM answers the first question a bit slower, and very occasionally emits a raw marker such as `<invoke>` — the gateway retries once automatically and it is fine once warm (see the troubleshooting table in section 8).
- **Reuse and cleanup**: when `launch-host` reuses a stopped machine it starts it first; once a local repository is removed from a project, the next deploy clears its code copy and `.incoming` (after adjusting the repository set and redeploying, `sudo ls /data/repo/` is enough to confirm nothing is left).

> **The two things most likely to bite on a real machine — confirm both yourself before handover**: first,
> "the deploy reported success but questions come back with no content" — the cause is almost always the
> runtime-to-bridge leg (security group not allowing 8080-8099 / no route from the private subnet to NAT /
> private-domain resolution failing). The default Runtime smoke tests this path; skipped probes leave it unverified; second, the wrong egress IP allowed on port 22, which locks you out of the machine you just created.

---

## Appendix D: refreshing monitoring by hand

With `--with-monitoring` enabled, phase 7 of `deploy-all.sh` deploys the whole monitoring set; the commands here also support enabling it explicitly or refreshing
a dashboard/threshold on its own, or catching up after deploying with `--skip monitoring`. The deploy-time
identity needs `logs:PutMetricFilter`, `cloudwatch:PutDashboard`, `cloudwatch:PutMetricAlarm` and
`sns:CreateTopic` (not the runtime role). Idempotent and repeatable; change `--region` for another region.

```bash
# Everything: dashboards → metric filters → alarms + SNS → DAU pre-aggregation Lambda, in that built-in order
./scripts/apply-monitoring.sh --region <r>          # add --dry-run to see the plan first

# Refresh one part only: --only dashboards|filters|alarms|dau
./scripts/apply-monitoring.sh --region <r> --only alarms
```

- Alarm thresholds live in `config/alarm-thresholds.json` and can be adjusted; re-run `--only alarms` after editing.
- The SNS subscription must be confirmed once by hand: `aws sns subscribe --region <r> --topic-arn <the ARN the script printed> --protocol email --notification-endpoint you@example.com` (then click the link in the email).
- Skipping the dau phase leaves the dashboard's "daily active" widget permanently empty; the other widgets are unaffected.

## Appendix E: Observability (AgentCore spans and traces)

The agent is launched through `opentelemetry-instrument` (see the `CMD` note in
`agent-container/Dockerfile`), so it emits OpenTelemetry spans. That wrapper *is* the
integration: `aws-opentelemetry-distro` had been a pinned dependency for a long time
without it, which produced no telemetry at all while every check stayed green.

Emitting spans and being able to query them are different things, and the second needs
**two** pieces of AWS-side setup, not one:

1. **CloudWatch Transaction Search** — account and Region level. Points trace segments at
   CloudWatch Logs and lets X-Ray write into the `aws/spans` log group.
2. **Per-runtime delivery** — each agent runtime needs a delivery source and destination
   for `TRACES` and for `APPLICATION_LOGS`. This one is easy to miss: the AWS docs describe
   it under console instructions, and without it the account-level switch looks broken.
   Before it was configured here, every runtime log stream was empty and no span reached
   `aws/spans` — the application's own output was not arriving either.

Both are applied by one idempotent stage:

```bash
./scripts/apply-monitoring.sh --region <region> --only observability
```

It also runs as part of `deploy-all.sh` Phase 7 when monitoring is enabled. Every step reads its result back rather
than trusting an exit code, because all the failure modes here look identical from the
outside: everything configured, no data.

**Verifying it, without fooling yourself.** Do not judge by `storedBytes` in
`describe-log-streams` — it is updated periodically and reads 0 long after events have
arrived, which is exactly how this looks like a failure when it is working. Query events:

```bash
aws logs filter-log-events --region <region> --log-group-name aws/spans \
  --start-time $(( ($(date +%s) - 1800) * 1000 )) --limit 20
```

Inspect the configured trace destination. The SDK-specific `scope.name` is
`openinference.instrumentation.openai_agents` for OpenAI or
`openinference.instrumentation.claude_agent_sdk` for Claude. Transport and runtime spans
may also appear; Claude subprocess spans are not expected from an OpenAI project.

**Session correlation works and is worth checking after any change.** A span's
`attributes.session.id` matches the `sessionId` the gateway logs on `invoke_start`, so a
session can be followed from the Feishu card through to the agent's tool calls. This is
also the property AgentCore Evaluations depends on, since it selects spans by session.

**Where spans land.** By default the shared `aws/spans` log group. Agents can instead
deliver to their own `/aws/bedrock-agentcore/runtimes/<id>-<endpoint>` group, which suits
this layout — one host, several projects, each already with its own group, so access
control and encryption scope per project. That needs ADOT >= 0.18.0 (pinned at 0.19.0, so
satisfied), `UNIFIED_TRACES_DESTINATION_ENABLED=true` on the runtime, and
`logs:PutResourcePolicy` for the execution role. The scripts do not enable this Runtime
environment variable; inspect the deployed environment before choosing the log group.

**Cost and one caveat.** Transaction Search indexes spans and is billed for that; sample
below 100% with `aws xray update-indexing-rule` if that matters. And ADOT's
auto-instrumentation adds startup work — a cold start measured 142s to first token after
this was enabled, against an AgentCore runtime initialisation limit of 120s. First token
is not initialisation, so this did not trip it, but the margin is smaller than before. If
cold-start `HTTP 424 Runtime health check failed` ever appears, look here first.

---

## Appendix F: Evaluations (AgentCore Evaluations)

Evaluations are **optional** and deliberately not on the deploy path: the bot does not need them to
answer questions, and they cost a different kind of money (Lambda invocations and execution time, plus model tokens per
LLM-as-judge verdict). They also only mean anything once real traffic has produced telemetry — creating
them during a first deploy buys you nothing but an empty run.

### Prerequisite: instrumentation

Evaluations accepts spans only from a fixed allow-list of instrumentation scopes and refuses anything
else outright:

```
ValidationException: Provided input has no spans with supported scope.
```

The selected SDK determines the scope. Claude uses automatically discovered
`openinference-instrumentation-claude-agent-sdk`; OpenAI explicitly installs the exclusive processor
in `openai_backend.instrument()` from `openinference-instrumentation-openai-agents`. Both export
through ADOT. Check the configured span destination (`aws/spans` by default; a Runtime log group
when unified trace destinations are enabled):

```bash
aws logs filter-log-events --region <r> \
  --log-group-name aws/spans \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --limit 500 \
  | grep -Ec 'openinference.instrumentation.(claude_agent_sdk|openai_agents)'
```

If no matching span appears, verify the time window, span destination and instrumentation for the
selected SDK before configuring evaluation. A zero count in the wrong log group is not proof that
instrumentation failed.

### Use the built-in evaluators first

`aws bedrock-agentcore-control list-evaluators` lists every built-in evaluator, including the DeepEval and
AutoEval third-party ones. Quality, relevance, conciseness, instruction following, tool selection and
parameters, trajectory matching and safety all have built-ins — **do not hand-roll those**. The one closest
to this project's purpose is `Builtin.Faithfulness`: whether the response is supported by the provided
context.

### The two custom evaluators, and why they exist

`evaluations/evaluators.json` holds exactly two, and each states why no built-in covers it:

| Evaluator | Kind | Why a built-in is not enough |
|---|---|---|
| `SourceTruthCitationAccuracy` | code-based (Lambda) | `Builtin.Faithfulness` judges whether the answer agrees with what the agent **was given**. It cannot judge whether that content was right: if retrieval returned a wrong line number and the answer faithfully cites it, Faithfulness scores Completely Yes. That is not a flaw in it — an LLM judge cannot open the repository |
| `SourceTruthEvidenceDiscipline` | LLM-as-judge | `Builtin.Refusal` scores evasion or refusal as negative. For this bot the opposite holds: when the repository genuinely does not contain what was asked, saying so is the CORRECT answer. That inversion cannot be configured away |

### Deploy

```bash
./scripts/apply-evaluations.sh --region <r>              # all stages
./scripts/apply-evaluations.sh --region <r> --dry-run    # print the plan only
./scripts/apply-evaluations.sh --region <r> --only evaluators
./scripts/apply-evaluations.sh --region <r> --project <pid> --only lambda
```

Stages run `package` → `iam` → `lambda` → `evaluators` → `online`, each idempotent. `--dry-run` makes no AWS calls.
Lambda updates preserve additional environment variables.
New online configurations start disabled with 100% sampling; `--enable --sampling 20` enables the requested rate.
Existing status and sampling remain unchanged when omitted; `--disable` explicitly disables evaluation.
Reruns reconcile execution status, sampling, evaluators, session timeout and execution role.
Failure to read an existing configuration fails the operation. Judge models are resolved for the current
region, or overridden with `EVAL_JUDGE_MODEL=<full inference profile ID>`; this choice is independent of
the Q&A/glossary SDK. Newly created role propagation errors have bounded retries; permission errors still
fail. The region must match the local deployment configuration.

**The code-based evaluator currently reads one project's bridge.** `--project` selects it. A new Lambda defaults to
the first configured project; an update retains the project mapped to its existing bridge, failing
if it cannot be identified uniquely. Repository prefixes come from that project and are passed as JSON.
The `online` stage still creates configurations for each regional Runtime, so scores produced by this
same code-based evaluator for other projects are not valid. Automatic routing across projects is not implemented.

Three things worth knowing:

- **Packaging must happen in a container.** `pydantic` carries the `pydantic-core` binary wheel, so a
  package built with the local pip may simply fail to import on Lambda — and that failure only surfaces
  during a real evaluation, where it appears as an evaluator fault in your evaluation data. The script
  builds and checks imports inside the official Lambda base image with `linux/arm64`. An x86 deployment
  machine must support ARM64 emulation.
- **The Lambda sits in the private subnet and joins `source-truth-index-svc`.** That is not an extra hole:
  the bridge's inbound rule is "8080-8099 from members of the same security group", so the evaluator is
  bound by the same boundary as the runtime.
- **The verification logic has exactly one copy**, in `index-service/citation_verify.py`, copied into the
  Lambda at package time. Not one copy per place — the day they drift, the evaluator and the live service
  quietly disagree about what counts as a valid citation.

### Run an evaluation

```bash
# Fetch a session's spans (Evaluate consumes spans, not answer text)
aws logs filter-log-events --region <r> \
  --log-group-name /aws/bedrock-agentcore/runtimes/<runtime-id>-DEFAULT \
  --start-time <ms> --limit 3000 --output json > /tmp/events.json

aws bedrock-agentcore evaluate --region <r> \
  --evaluator-id <id> --evaluation-input file://spans.json
```

Evaluator ids are printed by `apply-evaluations.sh` and stored in `.local/deploy-config` as
`EVALUATOR_IDS`. For bulk runs use `StartBatchEvaluation`, which discovers sessions straight from a
CloudWatch log group — no data-collection pipeline of your own required.

### One thing to know when reading results

The code-based evaluator keeps "the evaluator failed" strictly separate from "the answer is wrong". A
bridge that is unreachable, or a read that fails mid-run, returns an `errorCode`
(`BRIDGE_UNREACHABLE` / `BRIDGE_READ_FAILED`) plus a non-scoring label `EvaluatorError` — never `Fail`.
The reason is that an infrastructure outage recorded as `Fail` leaves a permanent, wrong "this citation
does not hold" in your evaluation data. Likewise `Unverified` means not one citation could actually be
checked (for example none carried a line number); it is not the same as `Pass`.

The explanation may say some cited files never appeared in a `read_file` call. That is **informational
and never a failure**: `search_files` results are not in the spans, so a citation may legitimately come
from a search result rather than a read, and failing those would manufacture false failures at scale.

### Cost and teardown

The two custom evaluators carry no standing charge themselves, but the Lambda bills for requests and
duration once it exists, and each LLM-as-judge verdict spends model tokens. `./scripts/teardown.sh`
removes them in order: online evaluation configs first (an enabled config **locks** its evaluators, so
they cannot be deleted until it is gone) → the two custom evaluators → the Lambda, then waits for its VPC
ENI to be released, because otherwise the security-group delete later fails with `DependencyViolation`.
