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
  run.sh                Service launcher: source the systemd-injected per-project env (/etc/bot-gateway-<project>.env) + fetch Feishu creds from Secrets Manager (never on disk) → node dist
index-service/          Standalone CodeGraph index service + MCP-over-HTTP bridge
  README.md             Resident single-writer session / CodeGraph / HTTP bridge (locate + read files) / local repo copy / bootstrap
  http_bridge.py        FastMCP HTTP bridge (package root, not src/): exposes codegraph locate + read-file tools, aligns paths to repo-relative
  codegraph_session.py  Resident codegraph-server single-writer session (worker thread + private loop, health self-heal, timeouts)
  repo_router.py        Server-side multi-repo routing + scope enforcement (multi-repo-isolation invariant 1: whitelist default-deny, out-of-scope repo arg never routes; pure decision core, unit-testable)
  repo_fanout.py        Multi-repo query result merge (when no repo is named, query each repo's session and merge; pure merge core, no I/O, unit-testable)
  file_search.py        Local-copy ripgrep/grep search tool (searches the local copy; builtin Grep disabled in favor of the local copy; content-dedups hits; MCP-exposed)
  file_read.py          Local-copy by-line/by-point file reader (read_file, paths aligned to repo-relative; MCP-exposed)
  file_table.py         Structured config-table reader (Excel/CSV/TSV/SQLite → text, read_table; read-only, DoS-bounded; MCP-exposed)
  text_decode.py        Robust text decoding (stdlib-only): Chinese game repos are often GBK/GB2312, config tables may be UTF-16; detects encoding to avoid mojibake
  glossary.py           Glossary data layer: concept-centric Entry/aggregate/incremental primitives/JSONL IO/lightweight projection
  glossary_read.py      Glossary read-only queries (glossary_index/glossary_lookup MCP tools; per-repo slice aggregation + project isolation)
  glossary_build.py     Build-time: local cc scans code → concept JSONL (prompt/tolerant parse/Chinese-alias grounding guard/incremental merge)
  glossary_gen.py       Glossary generator CLI: git-diff incremental vs full, candidate-file bounding, atomic write (called by the refresh timer)
  glossary_refresh.sh   Refresh-unit wrapper: after git_fetch, incrementally rebuild this repo's glossary slice over old..new (best-effort, never blocks the pull)
  path_align.py         Index path ↔ repo-relative lexical alignment (rejects escapes; mount_root defaults to "")
  codegraph_client.py   codegraph-server client wrapper (dormant: tests only, single-writer tripwire-guarded, never on the resident serving path)
  perf.py               Structured latency logging
  bootstrap.sh          EC2 user-data: install deps + codegraph binary + claude(cc) CLI for glossary build + gateway build + systemd templates (base host, no project bound)
  activate_project.sh   Per-project attach (invoked over SSM): write manifest / git clone (git repos) or confirm code already pushed (local repos) / build graph / start index-bridge-<projectId> + refresh timers (git repos only) / clean up repos dropped since the last manifest
  git_fetch.sh          Single-repo git clone/pull (credential + ref + fail-loud GIT_FETCH_FAILED; shared by bootstrap and the refresh timer)
  reindex_local_repo.sh Apply a local repo's staged code: normal push syncs in place onto live (--delay-updates shrinks the interrupt window), the watcher re-indexes incrementally + the glossary is refreshed incrementally from the change list (no bridge stop); first push stops the bridge for a full build; --prepare makes the staging dir
  tests/                pytest (invoked by scripts/test.sh)
infra/                  Infrastructure as code (MVP starts with agentcore toolkit / boto3, CDK-ified incrementally)
  README.md             IaC split: CDK owns the stable layer / deploy-all.sh provisions AgentCore Runtime via boto3
  monitoring/           Monitoring (CloudWatch side; scripts/boto3, not a CDK stack)
    queries/metric-filters/a-class-metrics.json  Single source of A-class metric intent (counts/percentiles/distributions → metric-filter)
    queries/metric-filters/alarm-metrics.json    Dedicated dense alarm filters (one per card_health kind, defaultValue:0)
    queries/metric-filters/by-project-metrics.json  projectId-dimensioned KPI companion filters (multi-project breakdown; the un-dimensioned rollup stays in a-class)
    queries/insights/*.logsinsights              B-class dedup/retention Insights queries (DAU etc., paired with a scheduled pre-aggregation Lambda)
    lambda/dau_preaggregate.py                   B-class DAU pre-aggregation Lambda (daily StartQuery→PutMetricData, pure stdlib+boto3)
    dashboard.product.json / dashboard.sre.json / dashboard.by-project.json  Dashboard templates (${REGION}/${NAMESPACE}/${ACCOUNT_ID} placeholders; product-usage / SRE-health (alarms on top) / by-project pages)
  (p2) lib/             runtime / codegraph(index-service) / gateway stacks
config/                 Config-driven: i18n.json (card / alarm / error copy), alarm-thresholds.json (alarm thresholds, operator-tunable), projects.example.json (project-routing schema template; the real config lives at .local/projects.json — deployment-specific, gitignored)
scripts/                Operational lifecycle
  check-invariants.sh   Fast structural lint (AGENTS / CLAUDE / structure / bilingual pairing / top-level dir existence)
  lib/                  common.sh (formatting + dep checks), env-utils.sh (.env / deploy-config shared helper), render_metric_filters.py (metric defs → put-metric-filter plan), render_dashboard.py (dashboard template render + no-type:log guard), render_alarms.py (thresholds → put-metric-alarm plan), render_manifest.py (multi-repo REPO_MANIFEST_JSON validate + per-repo records, pure & testable)
  apply-metric-filters.sh  Apply the infra/monitoring metric definitions to CloudWatch (idempotent upsert; --defs switches A-class/alarm; --dry-run)
  apply-dashboards.sh   Render dashboard templates and put-dashboard (idempotent; --dry-run; reads metric-filters' namespace as the single source)
  apply-alarms.sh       Ensure SNS topic + create CloudWatch alarms from config/alarm-thresholds.json (idempotent; subscription is manual)
  apply-dau-lambda.sh   Deploy the B-class DAU pre-aggregation Lambda + daily EventBridge schedule (role/package/trigger, idempotent; --dry-run)
  test.sh               Single tiered test entrypoint (offline default / --full)
  check-versions.sh     Pinned-version drift guard (base digest / requirements pin / Node / claude-code npm)
  get.sh                One-line bootstrap (fetch via curl/gh and run): clones the repo into ./source-truth then hands off to install.sh; re-runnable (git pull if it already exists)
  install.sh            Interactive one-click install (check deps→Feishu creds→config→confirm→deploy-all; pre-fills on re-run; add-project picks git or local repo source)
  push-local-repo.sh    Operator-side: rsync a local repo to the index host's staging dir and trigger a rebuild (local-repo refresh entry; no git)
  deploy-all.sh         Canonical one-click deploy (artifacts→IAM→network→index-service→image→Runtime→gateway; idempotent; --local single-host bootstrap)
  lib/provision_*.sh + deploy_runtime.py + wait_index_health.sh  deploy-all.sh phase implementations
  lib/deploy_project.sh + wait_base_host.sh + delete_runtime.py  Multi-project orchestration: build base / await base ready / delete per-project runtime
  lib/resolve_model.sh  Query Bedrock list-inference-profiles to pick a profile that actually exists in the region (no prefix guessing; geo profiles vary by region)
  lib/resolve_repo.sh   Multi-source repo resolver (local / git / s3); now referenced by tests only, main path branches by source: git clone or local push
  lib/activate_gateway.sh  Write /etc/bot-gateway-<project>.env + start bot-gateway@<project> via SSM (gateway co-located with the index host)
  lib/stop_gateway.sh   Stop the old instance's gateway via SSM (break-before-make on blue-green swap; prevents two gateways racing the Feishu long-connection)
  deploy.sh             Deprecated compatibility shim (delegates to deploy-all.sh)
  (p2) ops.sh           Ops toolkit (status / logs / reindex)
  teardown.sh           Ordered teardown + retained-resource list
  trace.sh              Merge-query the gateway + agent microVM log groups by traceId for a full-chain timeline (--since-hours / --raw)
  e2e-probe.py          Run a real end-to-end Q&A against the deployed Runtime; checks read-only boundary + answer provenance (invoked by test.sh --full; auto-skips if not deployed)
  tests/                shell unit tests test_*.sh (incl. test_e2e_probe.sh: pure-logic tests for e2e-probe)
docs/
  README.md             Documentation index (audience-grouped entry map)
  structure_zh.md       Authoritative tree (Chinese, bilingual pair)
  structure_en.md       This file (English counterpart)
  runbook.md            Deploy / connect-Feishu / ops / troubleshooting (neutral name, exempt from bilingual pairing)
  glossary.md           How the term bridge is built: build flow / output structure / trust basis / cost & ops (human-facing, neutral name)
  deploy/               IAM resources to pre-create for --local mode (operator runs once)
    source-truth-iam.yaml       CloudFormation: two roles (instance role + AgentCore runtime role) + instance profile
    create-iam.sh               Wrapper: pick AWS profile / region, then invoke the CFN above (interactive, no flags to type)
  design/               Design source of truth (Chinese only, not yet translated)
    README.md                   Directory notes + relation to architecture / invariants docs
    requirements_zh.md          Requirements & solution review notes (imported)
    architecture-overview_zh.md POC architecture plan (imported)
    agent-container_zh.md       agent-container component implementation contract
    multi-repo-isolation_zh.md  Multi-repo isolation design (per-repo CodeGraph + server-side scope gate + fan-out)
  agent/                AI-facing docs
    architecture.md     Mental model: how one question crosses the system
    glossary.md         Term bridge: Chinese question → English code symbol (build/query time, grounding, value boundary)
    invariants.md       source → generated map + change-X-must-change-Y couplings (9 invariants)
    playbooks.md        change playbooks (7 change scenarios)
    *-spike.md          Research notes (cardkit streaming / indexing perf / storage selection / perf comparison / template)
  assets/               Doc diagrams (hand-authored SVG: architecture / data-plane / session-isolation / glossary / glossary-build / glossary-confidence / security-defense / sequence; architecture / sequence / security-defense also have English `*.en.svg` for the English README; plus demo-qa.gif, a real Q&A screen recording)
.local/                 (gitignored) account-specific deploy state: deploy-config, projects.json (project routing)
```

Entries tagged `(p2)` are later-phase outputs; currently placeholders or not yet created. Untagged entries are all in place.
