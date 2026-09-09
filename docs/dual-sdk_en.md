# Select an Agent SDK at deployment

Each project selects **OpenAI Agents SDK** or **Claude Agent SDK**. New projects default to
OpenAI. Q&A and the offline glossary share `agent.sdk`, with independently configurable models.
Both paths use Amazon Bedrock Runtime with AWS role credentials; no OpenAI API key is required.
OpenAI Agents SDK is distinct from Codex SDK, which remains outside this project's scope.

The topology remains chat → AgentCore microVM → index-service HTTP MCP. Only the index host
holds repository copies.

## Configuration

`scripts/install.sh` defaults to adding a project and asks for the SDK (OpenAI by default) and answer model.
The glossary reuses that model; advanced deployments can set `glossaryModel` separately.
New environments enable glossary with `--with-glossary`, with a 400-file per-repository cap; existing choices are preserved.
Alternatively, set these fields inside the project in `.local/projects.json`:

```json
{
  "agent": {
    "sdk": "openai",
    "provider": "bedrock",
    "endpoint": "runtime",
    "model": "global.openai.gpt-6-astra",
    "glossaryModel": "global.openai.gpt-6-astra",
    "maxTurns": 60
  }
}
```

This is a project fragment. See [`config/projects.example.json`](../config/projects.example.json)
for a complete file. For Claude, choose `sdk: "claude"` and Anthropic models such as
`global.anthropic.claude-opus-4-8` for both fields. `glossaryModel` defaults to the answer model.

Deployment discovers system inference profiles in the selected region and resolves the same
model's regional prefix. It never substitutes a different model. A default ID is not a guarantee
of regional availability; failed discovery produces a warning and invocation still needs
post-deployment verification. Deployment currently uses system inference profiles.
AWS Converse also supports application inference profiles, but this project does not create or
resolve them yet. This implementation supports `bedrock/runtime`.

**Legacy compatibility:** files without `schemaVersion: 2` retain Claude when `agent.sdk` is
absent, including the old `model` / `DEPLOY_MODEL` fallback. Existing Runtime environments with
only `ANTHROPIC_MODEL` also retain Claude. The installer writes an explicit SDK for new projects
without changing neighboring legacy projects. Before adding schemaVersion 2 to an existing file,
give every legacy project an explicit SDK.

Request payloads cannot override the SDK, model or MCP endpoint.

## Execution

| Stage | OpenAI | Claude |
|---|---|---|
| Q&A | `Runner.run_streamed` from `openai-agents` | Existing `claude_agent_sdk.query` and cold-start retries |
| Transport | Custom `Model` adapter → Bedrock `ConverseStream`, AWS SDK SigV4 | `CLAUDE_CODE_USE_BEDROCK=1` |
| Evidence | SDK-owned HTTP MCP, closed read-only tool list | Same list through Claude MCP configuration |
| Glossary | Agents SDK with paginated reads restricted to the exact batch | Existing restricted local Claude CLI builder |
| Observability | OpenInference OpenAI Agents scope → ADOT | Existing Claude OpenInference scope → ADOT |

Both OpenAI Q&A and glossary builds call `ConverseStream` through `bedrock_converse.py`,
without calling `/openai/v1/responses`. OpenAI Agents SDK still owns the tool loop.
The adapter converts messages, function calls and tool results and preserves reasoning signatures
and encrypted content across turns. It sends the full local history, without a server-side
conversation or `previous_response_id`. Only text and local function/MCP tools are supported;
hosted tools are not enabled. Duplicate OpenAI auto-instrumentation is disabled;
explicit OpenInference instrumentation replaces the default OpenAI trace exporter.
Glossary SDK tracing is disabled. AWS logging remains governed by account configuration.

The gateway receives versioned `text_delta`, `tool_started`, `tool_finished`, `run_completed`
and `run_failed` events with `version/runId/seq`. Success is emitted only after the complete
agent loop and resource cleanup. The SDK's internal `response.completed` is not run completion
and does not indicate a Responses HTTP call. Missing Converse stop/usage events, truncated
output and provider blocks fail the run.
Missing terminal events, sequence gaps, turn limits and interrupted runs cannot render as
successful answers. Legacy Claude parsing remains available for staged upgrades.

## Upgrade and switching order

1. **Use the target host's complete project inventory**: reconcile `/etc/source-truth-projects.json`,
   `/etc/index-projects/` and local `.local/projects.json`; back up project configuration,
   Runtime versions and image digests. Gateway deployment replaces the shared routing file,
   so a local file containing one project must not overwrite a host serving several projects.
2. **Upgrade shared capabilities first**: publish the dual SDK image, index build code and
   dependencies, grant both model families access, and upgrade the gateway parser for both
   protocols. Skip this step when the deployed release already supports both SDKs.
3. **Deploy the project selection**: set `agent.sdk`, `agent.model` and `agent.glossaryModel`,
   then use the installer's redeploy-project flow. `--model` is only a legacy Claude fallback.
4. **Verify a new session**: wait for Runtime and DEFAULT to become READY, then confirm the
   gateway restarted and `/ready` returns 200. Restarting clears cached Runtime session IDs,
   preventing reuse of an old SDK microVM. Ask a question relevant to the project and verify
   tool calls, citations and `run_completed`; check glossary status separately below.

To identify the SDK used by a particular request, query its Runtime with the card's `traceId`:
`./scripts/trace.sh <traceId> --region <r> --runtime <runtime-id>`.
Use that invocation's `model` / `sdk` / `api` fields and stream events. New OpenAI releases
record `api: "ConverseStream"`. Current configuration does not change a past request's SDK or API.

## Glossary switching

Initial builds, git refresh timers and local repository uploads use the same project selection.
The host persists it in `/etc/index-project-<id>.env`. OpenAI worker dependencies live in
`/opt/idx/glossary-envs/<lock-hash>`, isolated from the resident index bridge environment.

Each `<repo>.jsonl.meta` records a fingerprint of SDK, model, region, API and prompt plus the
artifact digest. This contract applies once `GLOSSARY_CONFIG_FILE` is enabled. Legacy Claude
artifacts may have no metadata and can retain their incremental path during a code-only upgrade;
an explicit SDK switch enables fingerprint validation and a full rebuild.
The `GLOSSARY_MAX_FILES` cap contributes to the format 2 fingerprint. Existing artifacts rebuild
once on the next enabled refresh; a code upgrade with glossary disabled does not invoke the model.
A mismatch forces a full rebuild even with unchanged code,
so switching configuration or changing the cap incurs full-build model cost.
Migrating the previous Responses integration to Converse also triggers
an OpenAI glossary rebuild. The previous glossary remains readable while the build runs. A failed
build retains previous entries and does not update the fingerprint; a subsequent refresh retries.
Local repositories without timers require another deployment or push to retry.
When incremental changes exceed the file cap, remaining paths are retained for later refreshes.
Git metadata records `pending_files` / `pending_revision` and advances `source_revision` only
after all pending paths are processed. Local repositories retain unfinished changes in
`<repo>.jsonl.pending`, processed by the incremental refresh triggered by the next push. An explicit local source takes
precedence over a leftover `.git` directory.
Configuration publication and artifact replacement share a lock so stale workers cannot publish.
Queued `glossary_worker.sh` jobs reload the current configuration and interpreter after acquiring
the repository lock, rather than using the SDK selected before they queued.

OpenAI batches contain at most 20 files, leaving turns for individual reads, pagination and
final output. Claude CLI retains 300-file batches. `GLOSSARY_BUILD_CONCURRENCY` controls
concurrency within a build and stacks with cross-repository concurrency; limit simultaneous
repository rebuilds on a shared host. `GLOSSARY_MAX_FILES` caps files per build: full builds
scan only the capped candidate set, while excess incremental changes remain pending.
OpenAI reads continue long lines with `start_line` / `start_column`. Candidate selection and
grounding share `glossary_source.py`, which withholds credential/index-internal paths and
out-of-repository symlinks, and prevents path replacement during file opening.

Glossary builds run in the background. Runtime READY or deployment success does **not** mean
the glossary rebuild succeeded. On the index host, check:

```bash
sudo journalctl -u 'glossary-build-<project>-<repo>.service' -n 80
sudo tail -n 30 /var/log/glossary-build-<project>-<repo>.log
sudo cat /data/glossary/<project>/<repo>.jsonl.meta
```

The `glossary_gen_done` event and metadata matching the current configuration confirm that
build succeeded. To confirm incremental updates have caught up, Git `pending_files` must be
empty and `source_revision` must match the current commit; local repositories must have no
`.pending` file. The `glossary_gen_cc_failed` or `glossary_config_rebuild_empty` events indicate failure.
Rollback restores the project's previous `agent` configuration and redeploys both paths;
the restored SDK also rebuilds its glossary.

Run this read-only check on the index host after replacing the project/repository names;
it makes no model call:

```bash
cd /opt/idx/app
sudo python3 - <<'PY'
from pathlib import Path
import shlex
import glossary_config
project, repo = "<project>", "<repo>"
cfg = dict(line.split("=", 1) for line in Path(f"/etc/index-project-{project}.env").read_text().splitlines() if "=" in line)
if cfg.get("GLOSSARY_ENABLED", "true") == "false":
    raise SystemExit("glossary disabled")
expected = glossary_config.fingerprint(
    *(shlex.split(cfg[key])[0] for key in ("AGENT_SDK", "MODEL", "REGION")),
    max_files=int(shlex.split(cfg["GLOSSARY_MAX_FILES"])[0]),
)
print(glossary_config.matches(f"/data/glossary/{project}/{repo}.jsonl", expected))
PY
```

`True` confirms the artifact matches the current build configuration. The `cc` in legacy
event names does not identify which SDK ran.

Shared Runtime/index roles retain both model families so deploying one project cannot revoke
another's access. Converse uses `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream`;
there is no separate IAM action named `bedrock:Converse`. Existing `project/default`
permissions retain compatibility with older Responses deployments. The new path does not depend
on that interface. No Mantle permission or new network endpoint is required; existing NAT
egress serves model requests.

## Dependencies and verification

The original Claude SDK and base image pins remain unchanged. Added pins are OpenAI Agents SDK
0.22.1, OpenAI SDK 3.10.0 and OpenInference 2.2.0. uv generates the complete ARM64 lock;
the separate glossary lock is a subset. Regenerate the license table by running
`scripts/generate-python-licenses.py` in an environment synced to the complete agent lock.
CI installs that lock on Python 3.11, tests the separate index and glossary environments on
Python 3.12, and verifies license metadata with `generate-python-licenses.py --check`.
Only the two integration modules requiring the absent ARM64 CodeGraph binary may skip;
the source and reason are checked, and all other skips fail CI.

`./scripts/test.sh` covers both stream formats, legacy defaults, a real SDK loop with local HTTP
MCP and signed requests with simulated Bedrock binary event streams, reasoning continuation,
forbidden tools, turn limits, truncation, cancellation, glossary switching,
grounding and failure retention. These offline tests do not prove deployment IAM permissions,
model availability, or production answer quality and cost. The deployment's `e2e-probe.py --smoke` requires a
successful `codegraph_read_file` or `codegraph_read_table` completion event and a source citation;
a model merely writing a filename is insufficient. After deployment, `./scripts/test.sh --full` invokes the
real Runtime and incurs model charges.

Official references, checked 2026-09-09:

- [Agents SDK](https://developers.openai.com/api/docs/guides/agents-sdk)
- [Models and providers](https://developers.openai.com/api/docs/guides/agents/models)
- [AWS GPT-6 Astra API and regional availability](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-astra.html)
- [Converse messages and reasoning context](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)
- [AgentCore OpenAI Agents support](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/supported-frameworks-openai-agents.html)
