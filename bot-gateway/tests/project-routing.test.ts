import { validateProjectsConfig, resolveRoute, loadProjectsConfig, ProjectsConfigMissing } from "../src/project-routing";
import { writeFileSync, mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const MULTI = {
  projects: {
    "game-a": { endpoint: "http://index-a.internal:8080/mcp", repos: ["code-5x", "code-5x-svc"] },
    "game-b": { endpoint: "http://10.1.1.20:8081/mcp", repos: ["backend"] },
  },
};
const SOLE = {
  projects: {
    "source-truth": { endpoint: "http://index.source-truth.internal:8080/mcp", repos: ["code-5x"] },
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

  it("rejects a malformed endpoint", () => {
    const bad = { projects: { p: { endpoint: "ftp://x", repos: ["r"] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/endpoint must be an http/);
    const bad2 = { projects: { p: { endpoint: "not a url", repos: ["r"] } } };
    expect(() => validateProjectsConfig(bad2)).toThrow(/endpoint must be an http/);
  });

  it("rejects empty/missing repos", () => {
    const bad = { projects: { p: { endpoint: "http://x/mcp", repos: [] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/repos must be a non-empty array/);
  });

  it("rejects an illegal repo name (charset guard against injection into path/unit/pgrep)", () => {
    for (const bad of ["../etc", "Code5x", "a b", "repo;rm", "a_b"]) {
      const cfg = { projects: { p: { endpoint: "http://x/mcp", repos: [bad] } } };
      expect(() => validateProjectsConfig(cfg)).toThrow(/repo name must match/);
    }
  });

  it("rejects a duplicate repo within a project", () => {
    const bad = { projects: { p: { endpoint: "http://x/mcp", repos: ["r", "r"] } } };
    expect(() => validateProjectsConfig(bad)).toThrow(/duplicate repo/);
  });
});

describe("resolveRoute — explicit projectId, sole-project default, fail-closed", () => {
  const multi = validateProjectsConfig(MULTI);
  const sole = validateProjectsConfig(SOLE);

  it("resolves an explicit projectId to its endpoint + repos", () => {
    const r = resolveRoute(multi, "game-a");
    expect(r).not.toBeNull();
    expect(r!.projectId).toBe("game-a");
    expect(r!.endpoint).toBe("http://index-a.internal:8080/mcp");
    expect(r!.repos).toEqual(["code-5x", "code-5x-svc"]);
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
