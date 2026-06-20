[中文](structure_zh.md) | [English](structure_en.md)

# Project Structure

> Authoritative top-level directory tree. Changing any top-level directory means updating both this file and `structure_zh.md` (enforced by `scripts/check-invariants.sh`).

```
agent-container/        Claude Code Agent running inside the session microVM (Python)
  README.md             Responsibility + external contract (goal/session input, index-service MCP endpoint: locate + read files)
  prompts/              System prompt + FAQ list + answer rules (code-as-truth / flag divergence / escalate)
  Dockerfile            ARM64 base image pinned by sha256; pins Claude Agent SDK (claude-agent-sdk); @anthropic-ai/claude-code tracks @latest by operator choice (NOT pinned)
  agent.py              @app.entrypoint async streaming handler that drives the agent loop
  agent_lib.py          SDK-free read-only Q&A agent core (agent.py's testable kernel: option build / evidence loop)
  requirements.txt + requirements.lock  Pinned Python deps (lock = full-transitive pip freeze)
  tests/                pytest (invoked by scripts/test.sh)
bot-gateway/            Feishu Bot long-connection event gateway + CardKit streaming (TypeScript long-running service)
  README.md             Long-connection / event dedup / session→runtimeSessionId map / card update throttling
  src/                  Event consumer entry, SigV4 call to AgentCore, session map, CardKit render, SSE parse, redacted logging
  run.sh                Service launcher: source /etc/bot-gateway.env + fetch Feishu creds from Secrets Manager (never on disk) → node dist
index-service/          Standalone CodeGraph index service + MCP-over-HTTP bridge
  README.md             Resident single-writer session / CodeGraph / HTTP bridge (locate + read files) / local repo copy / bootstrap
  http_bridge.py        FastMCP HTTP bridge (package root, not src/): exposes codegraph locate + read-file tools, aligns paths to repo-relative
  codegraph_session.py  Resident codegraph-server single-writer session (worker thread + private loop, health self-heal, timeouts)
  file_search.py        Local-copy ripgrep/grep search tool (searches the local copy; builtin Grep disabled in favor of the local copy; content-dedups hits; MCP-exposed)
  file_read.py          Local-copy by-line/by-point file reader (read_file, paths aligned to repo-relative; MCP-exposed)
  file_table.py         Structured config-table reader (Excel/CSV/TSV/SQLite → text, read_table; read-only, DoS-bounded; MCP-exposed)
  path_align.py         Index path ↔ repo-relative lexical alignment (rejects escapes; mount_root defaults to "")
  codegraph_client.py   codegraph-server client wrapper (dormant: tests only, single-writer tripwire-guarded, never on the resident serving path)
  perf.py               Structured latency logging
  bootstrap.sh          EC2 user-data: install deps / extract repo to local /data/repo / snapshot-stamp re-extract / systemd build→bridge
  tests/                pytest (invoked by scripts/test.sh)
infra/                  Infrastructure as code (MVP starts with agentcore toolkit / boto3, CDK-ified incrementally)
  README.md             IaC split: CDK owns the stable layer / deploy-all.sh provisions AgentCore Runtime via boto3
  monitoring/           Monitoring (CloudWatch side; scripts/boto3, not a CDK stack)
    queries/metric-filters/a-class-metrics.json  Single source of A-class metric intent (counts/percentiles/distributions → metric-filter)
    queries/metric-filters/alarm-metrics.json    Dedicated dense alarm filters (one per card_health kind, defaultValue:0)
    queries/insights/*.logsinsights              B-class dedup/retention Insights queries (DAU etc., paired with a scheduled pre-aggregation Lambda)
    dashboard.product.json / dashboard.sre.json  Dashboard templates (${REGION}/${NAMESPACE} placeholders; product-usage / SRE-health pages)
  (p2) lib/             runtime / codegraph(index-service) / gateway stacks
config/                 Config-driven: i18n.json (card / alarm / error copy), alarm-thresholds.json (alarm thresholds, operator-tunable)
scripts/                Operational lifecycle
  check-invariants.sh   Fast structural lint (AGENTS / CLAUDE / structure / bilingual pairing / top-level dir existence)
  lib/                  common.sh (formatting + dep checks), env-utils.sh (.env / deploy-config shared helper), render_metric_filters.py (metric defs → put-metric-filter plan), render_dashboard.py (dashboard template render + no-type:log guard), render_alarms.py (thresholds → put-metric-alarm plan)
  apply-metric-filters.sh  Apply the infra/monitoring metric definitions to CloudWatch (idempotent upsert; --defs switches A-class/alarm; --dry-run)
  apply-dashboards.sh   Render dashboard templates and put-dashboard (idempotent; --dry-run; reads metric-filters' namespace as the single source)
  apply-alarms.sh       Ensure SNS topic + create CloudWatch alarms from config/alarm-thresholds.json (idempotent; subscription is manual)
  test.sh               Single tiered test entrypoint (offline default / --full)
  check-versions.sh     Pinned-version drift guard (base digest / requirements pin / Node / claude-code npm)
  install.sh            Interactive one-click install (check deps→Feishu creds→config→confirm→deploy-all; pre-fills on re-run)
  deploy-all.sh         Canonical one-click deploy (artifacts→IAM→network→index-service→image→Runtime→gateway; idempotent)
  lib/provision_*.sh + deploy_runtime.py + wait_index_health.sh  deploy-all.sh phase implementations
  lib/resolve_repo.sh   --repo multi-source resolver (local / git URL / s3://) → normalized local dir
  lib/activate_gateway.sh  Write /etc/bot-gateway.env + start bot-gateway.service via SSM (gateway co-located with the index host)
  lib/stop_gateway.sh   Stop the old instance's gateway via SSM (break-before-make on blue-green swap; prevents two gateways racing the Feishu long-connection)
  ⚠️ deploy.sh          Deprecated compatibility shim (delegates to deploy-all.sh)
  (p2) ops.sh           Ops toolkit (status / logs / reindex)
  teardown.sh           Ordered teardown + retained-resource list
docs/
  README.md             Documentation index (audience-grouped entry map)
  structure_zh.md       Authoritative tree (Chinese, bilingual pair)
  structure_en.md       This file (English counterpart)
  runbook.md            Deploy / connect-Feishu / ops / troubleshooting (neutral name, exempt from bilingual pairing)
  design/               Design source of truth (Chinese only, not yet translated)
    README.md                   Directory notes + relation to architecture / invariants docs
    requirements_zh.md          Requirements & solution review notes (imported)
    architecture-overview_zh.md POC architecture plan (imported)
    agent-container_zh.md       agent-container component implementation contract
  agent/                AI-facing docs
    architecture.md     Mental model: how one question crosses the system
    invariants.md       source → generated map + change-X-must-change-Y couplings (7 invariants)
    playbooks.md        ordered change recipes (7 recipes)
    *-spike.md          Research notes (cardkit streaming / indexing perf / storage selection / perf comparison / template)
.local/                 (gitignored) account-specific deploy state: deploy-config, deploy-output.md
```

Entries tagged `(p1)` / `(p2)` are later-phase outputs; currently placeholders or not yet created. Untagged entries are all in place.
