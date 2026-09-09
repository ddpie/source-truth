/**
 * Project routing — the single trusted source mapping a project to its repo set and the
 * index-service endpoint serving them (multi-repo-isolation plan, stage 1).
 *
 * Config shape (deployment-specific `.local/projects.json`; committed template at
 * `config/projects.example.json` — JSON, not YAML, matching the config/i18n.json
 * convention and avoiding a new yaml dependency):
 *   {
 *     "projects": {
 *       "<projectId>": { "port": 8080,
 *                        "repos": [ { "subdir": "repoA", "git": "…", "ref": "…" }, … ] }
 *     }
 *   }
 * ONE projects.json is consumed by BOTH the gateway (needs the subdir SET for scope) and the
 * deploy orchestration (needs git/ref per repo). The gateway reads each repo object's `subdir`
 * and ignores git/ref (those are validated index-side by render_manifest). Each project's bridge
 * listens on its own `port` on the shared index host; the agent endpoint is DERIVED as
 * http://127.0.0.1:<port>/mcp (gateway + bridge are co-located).
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
 */

import { readFileSync } from "fs";
import { resolve } from "path";

export interface ProjectConfig {
  port: number;            // this project's bridge listen port (host-unique; required)
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

  // Validate each project entry. Ports must be host-unique (each project's bridge binds its
  // own port on the shared index host); a duplicate would make two projects' bridges collide.
  const seenPorts = new Set<number>();
  const out: Record<string, ProjectConfig> = {};
  for (const [pid, pv] of Object.entries(projects as Record<string, unknown>)) {
    if (!pv || typeof pv !== "object") throw new Error(`project '${pid}': must be an object`);
    const { port, repos } = pv as Record<string, unknown>;
    // Upper bound matters beyond "is it a valid port": the gateway derives its health port as
    // bridge + 10000 (see health.ts deriveHealthPort), so anything above 55535 would overflow
    // past 65535. An out-of-range port made listen() throw synchronously and crash the gateway.
    if (typeof port !== "number" || !Number.isInteger(port) || port <= 0 || port > 55535) {
      throw new Error(`project '${pid}': port must be an integer in 1..55535 (health port is derived as port+10000), got ${JSON.stringify(port)}`);
    }
    // The 10000+ band is reserved for those derived health ports. Declaring a bridge port there
    // would let one project's bridge steal another project's health port (the bridge binds hard
    // and wins; the health server then fails soft and that project loses its endpoint).
    if (port >= 10000) {
      throw new Error(`project '${pid}': port ${port} falls in the 10000+ range reserved for derived health ports — use a bridge port below 10000`);
    }
    if (seenPorts.has(port)) throw new Error(`projects config: duplicate port ${port} across projects`);
    seenPorts.add(port);
    // The endpoint is DERIVED (gateway + bridge are co-located on the index host), never
    // declared — validate the derived URL so a bad port still fails ENDPOINT_RE loudly.
    const endpoint = `http://127.0.0.1:${port}/mcp`;
    if (!ENDPOINT_RE.test(endpoint)) throw new Error(`project '${pid}': derived endpoint invalid (${endpoint})`);
    if (!Array.isArray(repos) || repos.length === 0) {
      throw new Error(`project '${pid}': repos must be a non-empty array`);
    }
    // repos entries are OBJECTS {subdir, git, ref?} (one projects.json shared with deploy).
    // The gateway only needs each repo's `subdir` (the scope set); git/ref are deploy-side and
    // validated index-side by render_manifest, so they're not re-checked here.
    const seen = new Set<string>();
    const subdirs: string[] = [];
    for (const r of repos) {
      if (!r || typeof r !== "object") {
        throw new Error(`project '${pid}': each repo must be an object {subdir, git, …}, got ${JSON.stringify(r)}`);
      }
      const subdir = (r as Record<string, unknown>).subdir;
      if (typeof subdir !== "string" || !REPO_NAME_RE.test(subdir)) {
        throw new Error(`project '${pid}': repo subdir must match ${REPO_NAME_RE} (got ${JSON.stringify(subdir)})`);
      }
      if (seen.has(subdir)) throw new Error(`project '${pid}': duplicate repo '${subdir}'`);
      seen.add(subdir);
      subdirs.push(subdir);
    }
    out[pid] = { port, repos: subdirs };
  }

  return { projects: out };
}

/**
 * Resolve the project-routing config path. The REAL config is DEPLOYMENT-SPECIFIC (which repo
 * subdirs, which internal endpoint) so it is NOT in the committed tree; config/projects.example.json
 * is the committed schema template.
 *
 * Path resolution, in order:
 *  1. PROJECTS_CONFIG_PATH env (an ABSOLUTE path the deploy writes) — the production path. The
 *     deployed gateway lives at /opt/bot-gateway, so a `../../.local`-from-dist walk would land
 *     at /opt/.local (wrong); deploy writes the real absolute location into the env instead.
 *  2. Fallback: <repo-root>/.local/projects.json — for LOCAL dev where the gateway runs from the
 *     repo (ts-node), .local/ is a sibling of bot-gateway/ (../../.local from src/ or dist/).
 */
function resolveConfigPath(): string {
  const fromEnv = process.env.PROJECTS_CONFIG_PATH;
  if (fromEnv && fromEnv.trim()) return fromEnv.trim();
  return resolve(__dirname, "..", "..", ".local", "projects.json");
}

/**
 * Load + validate the project-routing config (path from resolveConfigPath unless overridden).
 * Throws ProjectsConfigMissing on an ABSENT file (soft — caller serves without projectId) and
 * a plain Error on a PRESENT-but-invalid one (fail-loud — blocks startup). The optional `_doc`
 * key is ignored by validateProjectsConfig. Exposed for tests (pathOverride).
 */
export function loadProjectsConfig(pathOverride?: string): ProjectsConfig {
  const path = pathOverride ?? resolveConfigPath();
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
    // Non-ENOENT (EACCES permission, EISDIR is-a-directory, …) is a real misconfig → fail loud.
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
  // Endpoint is derived from the port (gateway + bridge co-located on the index host).
  return { projectId: pid, endpoint: `http://127.0.0.1:${project.port}/mcp`, repos: [...project.repos] };
}
