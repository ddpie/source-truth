[中文](structure_zh.md) | [English](structure_en.md)

# Project Structure

> Authoritative top-level directory tree. Changing any top-level directory means updating both this file and `structure_zh.md` (enforced by `scripts/check-invariants.sh`).

```
agent-container/        Claude Code Agent running inside the session microVM (Python)
  README.md             Responsibility + external contract (goal/session input, index-service MCP endpoint: locate + read files)
  prompts/              A single file, system.md: system prompt + FAQ list + answer rules (code-as-truth / flag divergence / escalate)
  Dockerfile            ARM64 base image pinned by sha256; pins Claude Agent SDK (claude-agent-sdk); @anthropic-ai/claude-code tracks @latest by operator choice (NOT pinned)
  agent.py              @app.entrypoint async streaming handler that drives the agent loop
  agent_lib.py          SDK-free read-only Q&A agent core (agent.py's testable kernel: option build / evidence loop)
  requirements.txt + requirements.lock  Pinned Python deps (lock = full-transitive pip freeze)
  tests/                pytest (invoked by scripts/test.sh)
bot-gateway/            Feishu Bot long-connection event gateway + CardKit streaming (TypeScript long-running service)
  README.md             Long-connection / event dedup / session→runtimeSessionId map / card update throttling
  src/                  Event consumer entry, SigV4 call to AgentCore, session map, CardKit render, SSE parse, redacted logging
  src/health.ts         Health endpoints on a separate 127.0.0.1 port (bridge port + 10000 by default, `HEALTH_PORT` overrides): `/health` liveness, `/ready` readiness (200 only while the long connection is up and the process is not draining)
  run.sh                Service launcher: source the systemd-injected per-project env (/etc/bot-gateway-<project>.env) + fetch Feishu creds from Secrets Manager (never on disk) → node dist
  tests/                jest unit tests (invoked by scripts/test.sh)
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
  path_align.py         Index path ↔ repo-relative lexical alignment (rejects escapes)
  perf.py               Structured latency logging
  bootstrap.sh          EC2 user-data: install deps + codegraph binary + claude(cc) CLI for glossary build + gateway build + systemd templates (base host, no project bound)
  activate_project.sh   Per-project attach (invoked over SSM): write manifest / git repos clone then build graph; a local repo with no code yet DEFERS its graph build to the first push (bridge still starts, empty/unhealthy until then) / start index-bridge-<projectId> + refresh timers (git repos only) / clean up repos dropped since the last manifest
  git_fetch.sh          Single-repo git clone/pull (credential + ref + fail-loud GIT_FETCH_FAILED; shared by bootstrap and the refresh timer)
  reindex_local_repo.sh Apply a local repo's staged code: normal push syncs in place onto live (--delay-updates shrinks the interrupt window), the watcher re-indexes incrementally + the glossary is refreshed incrementally from the change list (no bridge stop); first push stops the bridge for a full build, with the graph build and glossary running in parallel; the heavy work runs in a background systemd unit so an ssh disconnect doesn't interrupt it; --prepare makes the staging dir
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
  check-invariants.sh   Fast structural lint (AGENTS.md + architecture.md present and cross-referenced / bilingual pairing / top-level dirs ↔ structure doc two-way diff / design docs present / global IAM role policies do not pin ${REGION} / GitHub slug defaults are aws-samples / docs carry no real personnel or competitor names)
  lib/                  common.sh (formatting + dep checks), env-utils.sh (.env / deploy-config shared helper), render_metric_filters.py (metric defs → put-metric-filter plan), render_dashboard.py (dashboard template render + no-type:log guard), render_alarms.py (thresholds → put-metric-alarm plan), render_manifest.py (multi-repo REPO_MANIFEST_JSON validate + per-repo records, pure & testable)
  apply-monitoring.sh   Single entry for the monitoring stack (dashboards→metric filters→alarms→DAU Lambda in order, idempotent; --only picks one stage; --dry-run; implementations in lib/apply-*.sh)
  test.sh               Single tiered test entrypoint (offline default / --full)
  check-versions.sh     Pinned-version drift guard (base digest / requirements pin / Node / claude-code npm)
  get.sh                One-line bootstrap (fetch via curl/gh and run): clones the repo into ./source-truth then hands off to install.sh; re-runnable (git pull if it already exists)
  install.sh            Interactive one-click install (check deps→Feishu creds→config→confirm→deploy-all; pre-fills on re-run; add-project picks git or local repo source)
  push-local-repo.sh    Operator-side: rsync a local repo to the index host's staging dir and trigger a rebuild (local-repo refresh entry; no git)
  deploy-all.sh         Canonical one-click deploy (artifacts→IAM→network→index-service→image→Runtime→gateway; idempotent; --local single-host bootstrap)
  launch-host.sh        --local (single-EC2) mode entry (run on your machine): pick profile → create IAM → auto-build the network (VPC/public+private subnets/IGW/NAT, reuses provision_network.sh) + a host SG (SSH 22 from the operator only) → launch a public-subnet ARM64 EC2 with the instance role attached → print next steps
  lib/create-iam.sh     Create or reuse the --local instance role + profile and add the deploy-time policies (idempotent; called by launch-host.sh)
  lib/prepare-local-host.sh  First-run script for the --local EC2 (scp'd up + run by launch-host): install aws/docker/git + gh login + clone + hand off to install.sh
  lib/provision_*.sh + deploy_runtime.py  deploy-all.sh phase implementations
  lib/deploy_project.sh + wait_base_host.sh + delete_runtime.py  Multi-project orchestration: build base / await base ready / delete per-project runtime
  lib/resolve_model.sh  Query Bedrock list-inference-profiles to pick a profile that actually exists in the region (no prefix guessing; geo profiles vary by region)
  lib/activate_gateway.sh  Write /etc/bot-gateway-<project>.env + start bot-gateway@<project> via SSM (gateway co-located with the index host)
  lib/stop_gateway.sh   Stop the instance's bot-gateway@* via SSM (break-before-make: the Feishu long-connection is a global singleton, so the running gateway must exit before a new one starts)
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
  aws-services_zh.md    AWS services in use: what for / billing points (bilingual pair aws-services_en.md)
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
    *-spike.md          Research notes (cardkit streaming / indexing perf / template)
    perf-comparison.md  Latency comparison against native Claude Code
  assets/               Doc diagrams (hand-authored SVG: architecture / data-plane / session-isolation / glossary / glossary-build / glossary-confidence / security-defense / sequence; architecture / sequence / security-defense also have English `*.en.svg` for the English README; plus demo-qa.gif, a real Q&A screen recording)
.local/                 (gitignored) account-specific deploy state: deploy-config, projects.json (project routing)
```

Entries tagged `(p2)` are later-phase outputs; currently placeholders or not yet created. Untagged entries are all in place.
