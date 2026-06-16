[中文](structure_zh.md) | [English](structure_en.md)

# Project Structure

> Authoritative top-level directory tree. Changing any top-level directory means updating both this file and `structure_zh.md` (enforced by `scripts/check-invariants.sh`).

```
agent-container/        Claude Code Agent running inside the session microVM (Python)
  README.md             Responsibility + external contract (goal/session input, CodeGraph MCP endpoint, EFS mounts)
  prompts/              System prompt + FAQ list + answer rules (code-as-truth / flag divergence / escalate)
  (p1) Dockerfile       ARM64 base image pinned by sha256; pins Claude Agent SDK + lark-cli
  (p1) agent.py         @app.entrypoint async streaming handler that drives the agent loop
bot-gateway/            Feishu Bot long-connection event gateway + CardKit streaming (TypeScript long-running service)
  README.md             Long-connection / event dedup / session→runtimeSessionId map / card update throttling
  src/                  Event consumer entry, SigV4 call to AgentCore, session map, CardKit, audit log
index-service/          Standalone CodeGraph index service + MCP-over-HTTP bridge
  README.md             Hold clone / git pull / inotify incremental / CodeGraph / HTTP bridge / nightly full rebuild
  src/                  Webhook receiver + worktree lifecycle + mcp-proxy-style bridge
infra/                  Infrastructure as code (MVP starts with agentcore toolkit / boto3, CDK-ified incrementally)
  README.md             IaC split: CDK owns the stable layer / deploy.sh provisions AgentCore Runtime via boto3
  (p2) lib/             runtime / storage(EFS) / codegraph / gateway stacks
shared/                 Cross-package shared: structured logging (hashUserId), MCP tool schema, card protocol types
config/                 Config-driven: i18n.json (card / alarm / error copy), alarm-thresholds.json
scripts/                Operational lifecycle
  check-invariants.sh   Fast structural lint (AGENTS / CLAUDE / structure / bilingual pairing / top-level dirs)
  (p1) lib/             common.sh (formatting + dep checks), config.sh (.local config + region resolution)
  (p1) test.sh          Single tiered test entrypoint (offline default / --full)
  (p1) check-versions.sh Pinned-version drift guard
  (p1) deploy.sh        Orchestrate three-component deploy (idempotent = upgrade)
  (p2) ops.sh           Ops toolkit (status / logs / reindex / destroy)
  (p2) teardown.sh      Ordered teardown + retained-resource list
docs/
  structure_zh.md       Authoritative tree (Chinese, bilingual pair)
  structure_en.md       This file (English counterpart)
  design/               Design source of truth (Chinese)
    requirements_zh.md          Requirements & solution review notes (imported)
    architecture-overview_zh.md POC architecture plan (imported)
    agent-container_zh.md       agent-container component implementation contract
  agent/                AI-facing docs
    architecture.md     Mental model: how one question crosses the system
    invariants.md       (p1) source → generated map + change-X-must-change-Y couplings
    playbooks.md        (p1) ordered change recipes
.local/                 (gitignored) account-specific deploy state: deploy-config, deploy-output.md
```

Entries tagged `(p1)` / `(p2)` are later-phase outputs; currently placeholders or not yet created.
