/**
 * Project routing — the single trusted source mapping a Feishu bot to its project,
 * that project's repo set, and the index-service endpoint serving them
 * (multi-repo-isolation plan, stage 1).
 *
 * `config/projects.json` shape (JSON, not YAML — matches the existing config/i18n.json
 * convention and avoids a new yaml dependency; the plan's schema is what's load-bearing,
 * not the file extension):
 *   {
 *     "projects": {
 *       "<projectId>": { "endpoint": "http://host:port/mcp", "repos": ["repoA", "repoB"] }
 *     },
 *     "bots": { "<bot_id>": "<projectId>" }
 *   }
 *
 * Invariants (plan 不变量 6 + 阶段1):
 *  - One declaration site (this file's config), everything else derives from it.
 *  - Bad config (missing field / duplicate / malformed endpoint) → FAIL LOUD at load.
 *  - Unknown bot_id at resolve time → FAIL CLOSED (returns null; the caller refuses to
 *    serve and logs — never falls back to an arbitrary project).
 *
 * Stage 1 ships INDEPENDENTLY of index-service multi-repo: `endpoint` may still point at
 * today's single-repo bridge, proving the routing layer on its own.
 */

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
  bots: Record<string, string>;   // bot_id → projectId
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
  const bots = cfg.bots;
  if (!projects || typeof projects !== "object") throw new Error("projects config: missing 'projects' object");
  if (!bots || typeof bots !== "object") throw new Error("projects config: missing 'bots' object");

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

  // Validate the bot→project map: every bot points at a declared project; no dup bot_id
  // (object keys are unique by JSON parsing, but a value pointing at an unknown project is
  // the real failure mode here).
  for (const [botId, pid] of Object.entries(bots as Record<string, unknown>)) {
    if (typeof pid !== "string") throw new Error(`bot '${botId}': projectId must be a string`);
    if (!(pid in (projects as object))) {
      throw new Error(`bot '${botId}': points at unknown project '${pid}'`);
    }
  }

  return { projects: projects as Record<string, ProjectConfig>, bots: bots as Record<string, string> };
}

/**
 * Resolve a bot_id to its route. Returns null (FAIL CLOSED) for an unknown bot — the caller
 * must then refuse to serve + log, never fall back to an arbitrary project (plan 阶段1).
 */
export function resolveRoute(cfg: ProjectsConfig, botId: string | undefined | null): ResolvedRoute | null {
  if (!botId) return null;
  const projectId = cfg.bots[botId];
  if (!projectId) return null;
  const project = cfg.projects[projectId];
  if (!project) return null;   // defensive (validate() rules this out, but resolve must not throw)
  return { projectId, endpoint: project.endpoint, repos: [...project.repos] };
}
