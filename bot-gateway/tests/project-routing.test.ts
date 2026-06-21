import { validateProjectsConfig, resolveRoute, loadProjectsConfig, ProjectsConfigMissing } from "../src/project-routing";
import { writeFileSync, mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

// Schema (single-host multi-project): each project declares a `port` (its bridge's listen
// port on the index host); the endpoint is DERIVED as http://127.0.0.1:<port>/mcp (gateway and
// bridge are co-located). No `endpoint` field is accepted (pre-launch — no back-compat).
const MULTI = {
  projects: {
    "game-a": { port: 8080, repos: ["code-5x", "code-5x-svc"] },
    "game-b": { port: 8081, repos: ["backend"] },
  },
};
const SOLE = {
  projects: {
    "source-truth": { port: 8080, repos: ["code-5x"] },
  },
};

describe("validateProjectsConfig — fail-loud on bad config", () => {
  it("accepts a well-formed config", () => {
    expect(() => validateProjectsConfig(MULTI)).not.toThrow();
  });

  it("ignores a leading _doc key (committed templates carry one)", () => {
    expect(() => validateProjectsConfig({ _doc: ["notes"], ...SOLE })).not.toThrow();
  });

  it("rejects a non-object", () => {
    expect(() => validateProjectsConfig(null)).toThrow(/must be an object/);
    expect(() => validateProjectsConfig("x")).toThrow(/must be an object/);
  });

  it("rejects missing/empty projects", () => {
    expect(() => validateProjectsConfig({})).toThrow(/missing 'projects'/);
    expect(() => validateProjectsConfig({ projects: {} })).toThrow(/'projects' is empty/);
  });

  it("rejects a missing port (port is required pre-launch)", () => {
    const bad = { projects: { p: { repos: ["r"] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/port/i);
  });

  it("rejects a non-integer / non-positive port", () => {
    expect(() => validateProjectsConfig({ projects: { p: { port: "8080", repos: ["r"] } } })).toThrow(/port/i);
    expect(() => validateProjectsConfig({ projects: { p: { port: 0, repos: ["r"] } } })).toThrow(/port/i);
    expect(() => validateProjectsConfig({ projects: { p: { port: 1.5, repos: ["r"] } } })).toThrow(/port/i);
  });

  it("rejects duplicate ports across projects", () => {
    const bad = { projects: { a: { port: 8080, repos: ["x"] }, b: { port: 8080, repos: ["y"] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/duplicate port/i);
  });

  it("rejects empty/missing repos", () => {
    const bad = { projects: { p: { port: 8080, repos: [] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/repos must be a non-empty array/);
  });

  it("rejects an illegal repo name (charset guard against injection into path/unit/pgrep)", () => {
    for (const bad of ["../etc", "Code5x", "a b", "repo;rm", "a_b"]) {
      const cfg = { projects: { p: { port: 8080, repos: [bad] } } };
      expect(() => validateProjectsConfig(cfg)).toThrow(/repo name must match/);
    }
  });

  it("rejects a duplicate repo within a project", () => {
    const bad = { projects: { p: { port: 8080, repos: ["r", "r"] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/duplicate repo/);
  });
});

describe("resolveRoute — explicit projectId, sole-project default, fail-closed", () => {
  const multi = validateProjectsConfig(MULTI);
  const sole = validateProjectsConfig(SOLE);

  it("resolves an explicit projectId to its DERIVED loopback endpoint + repos", () => {
    const r = resolveRoute(multi, "game-a");
    expect(r).not.toBeNull();
    expect(r!.projectId).toBe("game-a");
    expect(r!.endpoint).toBe("http://127.0.0.1:8080/mcp");
    expect(r!.repos).toEqual(["code-5x", "code-5x-svc"]);
  });

  it("derives a distinct endpoint per project port", () => {
    expect(resolveRoute(multi, "game-b")!.endpoint).toBe("http://127.0.0.1:8081/mcp");
  });

  it("defaults to the SOLE project when no projectId is given (zero-config single-project)", () => {
    const r = resolveRoute(sole, "");
    expect(r).not.toBeNull();
    expect(r!.projectId).toBe("source-truth");
    expect(resolveRoute(sole, undefined)!.projectId).toBe("source-truth");
    expect(resolveRoute(sole, null)!.projectId).toBe("source-truth");
  });

  it("returns null (FAIL CLOSED) when multiple projects + no projectId — never guesses", () => {
    expect(resolveRoute(multi, "")).toBeNull();
    expect(resolveRoute(multi, undefined)).toBeNull();
  });

  it("returns null (FAIL CLOSED) for an explicit projectId that isn't declared", () => {
    expect(resolveRoute(multi, "game-z")).toBeNull();
    expect(resolveRoute(sole, "game-z")).toBeNull();
  });

  it("returns a COPY of repos (caller can't mutate the shared config)", () => {
    const r = resolveRoute(multi, "game-b")!;
    r.repos.push("injected");
    expect(resolveRoute(multi, "game-b")!.repos).toEqual(["backend"]);  // original intact
  });
});

describe("loadProjectsConfig — file loading", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "proj-routing-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it("loads + validates a real file", () => {
    const p = join(dir, "projects.json");
    writeFileSync(p, JSON.stringify(SOLE));
    const cfg = loadProjectsConfig(p);
    expect(Object.keys(cfg.projects)).toEqual(["source-truth"]);
  });

  it("throws ProjectsConfigMissing (SOFT) when the file is absent", () => {
    expect(() => loadProjectsConfig(join(dir, "nope.json"))).toThrow(ProjectsConfigMissing);
  });

  it("fails loud (NOT ProjectsConfigMissing) on present-but-malformed JSON", () => {
    const p = join(dir, "bad.json");
    writeFileSync(p, "{ not json");
    expect(() => loadProjectsConfig(p)).toThrow(/not valid JSON/);
    expect(() => loadProjectsConfig(p)).not.toThrow(ProjectsConfigMissing);
  });

  it("fails loud on present-but-invalid config (missing projects)", () => {
    const p = join(dir, "invalid.json");
    writeFileSync(p, JSON.stringify({ foo: 1 }));
    expect(() => loadProjectsConfig(p)).toThrow(/missing 'projects'/);
  });
});
