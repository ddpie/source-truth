/**
 * Project routing — the single trusted source mapping a project to its repo set and the
 * index-service endpoint serving them (multi-repo-isolation plan, stage 1).
 *
 * `config/projects.json` shape (JSON, not YAML — matches the existing config/i18n.json
 * convention and avoids a new yaml dependency; the plan's schema is what's load-bearing,
 * not the file extension):
 *   {
 *     "projects": {
 *       "<projectId>": { "endpoint": "http://host:port/mcp", "repos": ["repoA", "repoB"] }
 *     }
 *   }
 *
 * WHICH project a gateway serves is bound by the PROJECT_ID env var, NOT by a bot_id map in
 * this file — the bot identity (Feishu app_id) is env-only (FEISHU_APP_ID), never committed,
 * so it must not appear in a git-tracked config. Everything in projects.json is therefore
 * non-secret declarative truth (repo subdirs, internal endpoint) and safe to commit.
 *
 * Invariants (plan 不变量 6 + 阶段1):
 *  - One declaration site (this config), everything else derives from it.
 *  - Bad config (missing field / duplicate / malformed endpoint) → FAIL LOUD at load.
 *  - Unknown / ambiguous PROJECT_ID at resolve time → FAIL CLOSED (returns null; the caller
 *    refuses to derive a route and logs — never falls back to an arbitrary project).
 *
 * Stage 1 ships INDEPENDENTLY of index-service multi-repo: `endpoint` may still point at
 * today's single-repo bridge, proving the routing layer on its own.
 */

import { readFileSync } from "fs";
import { resolve } from "path";

export interface ProjectConfig {
  endpoint: string;        // CODEGRAPH_MCP_URL for this project's bridge
  repos: string[];         // repo subdirs this project's agent may query
}

export interface ResolvedRoute {
  projectId: string;
  endpoint: string;
  repos: string[];
}

export interface ProjectsConfig {
  projects: Record<string, ProjectConfig>;
}

// http(s)://host[:port]/path — deliberately permissive on host (an in-VPC private IP or a
// Route53 internal name are both valid), strict on scheme so a typo'd endpoint fails loud.
const ENDPOINT_RE = /^https?:\/\/[^\s/]+(?:\/[^\s]*)?$/;
const REPO_NAME_RE = /^[a-z0-9-]+$/;   // same charset the index-service path/unit/pgrep use

/**
 * Validate a parsed projects-config object. Throws Error (fail-loud) with a specific
 * message on ANY structural problem, so a misconfig is caught at gateway startup, not as a
 * silent mis-route at request time. Returns the validated config unchanged on success.
 */
export function validateProjectsConfig(raw: unknown): ProjectsConfig {
  if (!raw || typeof raw !== "object") throw new Error("projects config must be an object");
  const cfg = raw as Record<string, unknown>;
  const projects = cfg.projects;
  if (!projects || typeof projects !== "object") throw new Error("projects config: missing 'projects' object");
  if (Object.keys(projects as object).length === 0) throw new Error("projects config: 'projects' is empty");

  // Validate each project entry.
  for (const [pid, pv] of Object.entries(projects as Record<string, unknown>)) {
    if (!pv || typeof pv !== "object") throw new Error(`project '${pid}': must be an object`);
    const { endpoint, repos } = pv as Record<string, unknown>;
    if (typeof endpoint !== "string" || !ENDPOINT_RE.test(endpoint)) {
      throw new Error(`project '${pid}': endpoint must be an http(s) URL, got ${JSON.stringify(endpoint)}`);
    }
    if (!Array.isArray(repos) || repos.length === 0) {
      throw new Error(`project '${pid}': repos must be a non-empty array`);
    }
    const seen = new Set<string>();
    for (const r of repos) {
      if (typeof r !== "string" || !REPO_NAME_RE.test(r)) {
        throw new Error(`project '${pid}': repo name must match ${REPO_NAME_RE} (got ${JSON.stringify(r)})`);
      }
      if (seen.has(r)) throw new Error(`project '${pid}': duplicate repo '${r}'`);
      seen.add(r);
    }
  }

  return { projects: projects as Record<string, ProjectConfig> };
}

/**
 * Load + validate the project-routing config. The REAL config is DEPLOYMENT-SPECIFIC (which
 * repo subdirs, which internal endpoint) so it lives at .local/projects.json (gitignored,
 * alongside .local/deploy-config which already holds REPO_SUBDIR / INDEX_DNS_NAME) — NOT in
 * the committed tree. config/projects.example.json is the committed schema template.
 * .local/ is at the repo root; bot-gateway/ is a sibling, so ../../.local from dist/.
 *
 * Throws (fail-loud) on a missing file or invalid config so the gateway refuses to start
 * rather than mis-route at request time. The optional `_doc` key is ignored by
 * validateProjectsConfig. Exposed for tests (pathOverride).
 */
export function loadProjectsConfig(pathOverride?: string): ProjectsConfig {
  const path = pathOverride ?? resolve(__dirname, "..", "..", ".local", "projects.json");
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    // MISSING file is distinct from a MALFORMED one. A gateway deployed without
    // .local/projects.json (e.g. the file wasn't provisioned to the host yet) should
    // degrade gracefully — serve with no projectId — not crash-loop. The caller catches
    // this sentinel and logs a warning. A PRESENT-but-invalid config is fail-loud below.
    const err = e as NodeJS.ErrnoException;
    if (err && err.code === "ENOENT") throw new ProjectsConfigMissing(path);
    throw new Error(`project-routing: cannot read ${path}: ${String(e)}`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new Error(`project-routing: ${path} is not valid JSON: ${String(e)}`);
  }
  return validateProjectsConfig(parsed);
}

/** Thrown by loadProjectsConfig when the config file is ABSENT (vs. present-but-invalid).
 *  The gateway treats absent as "no routing configured → serve without projectId" (soft),
 *  but present-but-malformed as fail-loud (an operator error that must block startup). */
export class ProjectsConfigMissing extends Error {
  constructor(path: string) {
    super(`project-routing: ${path} not found (copy config/projects.example.json there to enable project routing)`);
    this.name = "ProjectsConfigMissing";
  }
}

/**
 * Resolve THIS gateway's project to its route.
 *  - explicit projectId given → that project (FAIL CLOSED if it isn't declared).
 *  - projectId empty/undefined AND exactly one project declared → that sole project
 *    (zero-config single-project case — today's deployment).
 *  - projectId empty AND multiple projects → null (ambiguous; the operator must set
 *    PROJECT_ID — never guess which project a gateway serves).
 * Returns null (FAIL CLOSED) rather than throwing so the caller logs + serves without a
 * projectId instead of crashing per request.
 */
export function resolveRoute(cfg: ProjectsConfig, projectId: string | undefined | null): ResolvedRoute | null {
  const ids = Object.keys(cfg.projects);
  let pid: string | undefined;
  if (projectId) {
    pid = projectId;
  } else if (ids.length === 1) {
    pid = ids[0];   // sole project → unambiguous default
  } else {
    return null;    // ambiguous: multiple projects but no PROJECT_ID → fail closed
  }
  const project = cfg.projects[pid];
  if (!project) return null;   // explicit PROJECT_ID naming an undeclared project → fail closed
  return { projectId: pid, endpoint: project.endpoint, repos: [...project.repos] };
}
