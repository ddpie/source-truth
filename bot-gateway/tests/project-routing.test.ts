import { validateProjectsConfig, resolveRoute } from "../src/project-routing";

const GOOD = {
  projects: {
    "game-a": { endpoint: "http://index-a.internal:8080/mcp", repos: ["code-5x", "code-5x-svc"] },
    "game-b": { endpoint: "http://10.1.1.20:8081/mcp", repos: ["backend"] },
  },
  bots: { "cli_aaa": "game-a", "cli_bbb": "game-b" },
};

describe("validateProjectsConfig — fail-loud on bad config", () => {
  it("accepts a well-formed config", () => {
    expect(() => validateProjectsConfig(GOOD)).not.toThrow();
  });

  it("rejects a non-object", () => {
    expect(() => validateProjectsConfig(null)).toThrow(/must be an object/);
    expect(() => validateProjectsConfig("x")).toThrow(/must be an object/);
  });

  it("rejects missing projects/bots", () => {
    expect(() => validateProjectsConfig({ bots: {} })).toThrow(/missing 'projects'/);
    expect(() => validateProjectsConfig({ projects: {} })).toThrow(/missing 'bots'/);
  });

  it("rejects a malformed endpoint", () => {
    const bad = { projects: { p: { endpoint: "ftp://x", repos: ["r"] } }, bots: {} };
    expect(() => validateProjectsConfig(bad)).toThrow(/endpoint must be an http/);
    const bad2 = { projects: { p: { endpoint: "not a url", repos: ["r"] } }, bots: {} };
    expect(() => validateProjectsConfig(bad2)).toThrow(/endpoint must be an http/);
  });

  it("rejects empty/missing repos", () => {
    const bad = { projects: { p: { endpoint: "http://x/mcp", repos: [] } }, bots: {} };
    expect(() => validateProjectsConfig(bad)).toThrow(/repos must be a non-empty array/);
  });

  it("rejects an illegal repo name (charset guard against injection into path/unit/pgrep)", () => {
    for (const bad of ["../etc", "Code5x", "a b", "repo;rm", "a_b"]) {
      const cfg = { projects: { p: { endpoint: "http://x/mcp", repos: [bad] } }, bots: {} };
      expect(() => validateProjectsConfig(cfg)).toThrow(/repo name must match/);
    }
  });

  it("rejects a duplicate repo within a project", () => {
    const bad = { projects: { p: { endpoint: "http://x/mcp", repos: ["r", "r"] } }, bots: {} };
    expect(() => validateProjectsConfig(bad)).toThrow(/duplicate repo/);
  });

  it("rejects a bot pointing at an unknown project (no silent mis-route)", () => {
    const bad = { projects: { p: { endpoint: "http://x/mcp", repos: ["r"] } }, bots: { cli_x: "nope" } };
    expect(() => validateProjectsConfig(bad)).toThrow(/unknown project 'nope'/);
  });
});

describe("resolveRoute — fail-closed on unknown bot", () => {
  const cfg = validateProjectsConfig(GOOD);

  it("resolves a known bot to its project endpoint + repos", () => {
    const r = resolveRoute(cfg, "cli_aaa");
    expect(r).not.toBeNull();
    expect(r!.projectId).toBe("game-a");
    expect(r!.endpoint).toBe("http://index-a.internal:8080/mcp");
    expect(r!.repos).toEqual(["code-5x", "code-5x-svc"]);
  });

  it("returns null (fail-closed) for an unknown bot — never falls back to a project", () => {
    expect(resolveRoute(cfg, "cli_unknown")).toBeNull();
  });

  it("returns null for empty/undefined bot id", () => {
    expect(resolveRoute(cfg, "")).toBeNull();
    expect(resolveRoute(cfg, undefined)).toBeNull();
    expect(resolveRoute(cfg, null)).toBeNull();
  });

  it("returns a COPY of repos (caller can't mutate the shared config)", () => {
    const r = resolveRoute(cfg, "cli_bbb")!;
    r.repos.push("injected");
    expect(resolveRoute(cfg, "cli_bbb")!.repos).toEqual(["backend"]);  // original intact
  });
});
