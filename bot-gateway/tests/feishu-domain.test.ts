/**
 * feishu-domain.test.ts — the tenant-domain switch.
 *
 * The failure this guards is asymmetric and quiet: the REST base URL honoured a domain setting
 * while the event long-connection did not, so an international Lark app authenticated fine on
 * REST calls and then never received a single event. Nothing surfaced the mismatch — the gateway
 * looked healthy. So the invariant worth pinning is not "lark maps to larksuite" on its own, it
 * is that BOTH sides derive from the same input.
 */

const REST_MODULE = "../src/feishu-http";

function restBaseFor(env: Record<string, string | undefined>): string {
  const saved = process.env;
  // Swap in a fresh copy rather than deleting computed keys off the live object: a dynamic
  // delete is both an eslint violation here and easy to get subtly wrong on restore.
  const next: NodeJS.ProcessEnv = { ...saved };
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) next[k] = undefined;
    else next[k] = v;
  }
  process.env = next;
  let base: string;
  try {
    jest.resetModules();
    // The module reads env at import time, which is why it has to be re-imported per case.
    base = (require(REST_MODULE) as { FEISHU_API_BASE_FOR_TEST?: string }).FEISHU_API_BASE_FOR_TEST
      ?? "";
  } finally {
    process.env = saved;
  }
  return base;
}

describe("tenant domain", () => {
  it("defaults to Feishu (China) when unset", () => {
    expect(restBaseFor({ FEISHU_DOMAIN: undefined, FEISHU_API_BASE: undefined }))
      .toBe("https://open.feishu.cn");
  });

  it("selects the international Lark base for FEISHU_DOMAIN=lark", () => {
    expect(restBaseFor({ FEISHU_DOMAIN: "lark", FEISHU_API_BASE: undefined }))
      .toBe("https://open.larksuite.com");
  });

  it("is case- and whitespace-insensitive", () => {
    expect(restBaseFor({ FEISHU_DOMAIN: " LARK ", FEISHU_API_BASE: undefined }))
      .toBe("https://open.larksuite.com");
  });

  it("falls back to Feishu on an unrecognised value rather than breaking the gateway", () => {
    expect(restBaseFor({ FEISHU_DOMAIN: "bogus", FEISHU_API_BASE: undefined }))
      .toBe("https://open.feishu.cn");
  });

  it("lets an explicit FEISHU_API_BASE win, for a proxy or private deployment", () => {
    expect(restBaseFor({ FEISHU_DOMAIN: "lark", FEISHU_API_BASE: "https://proxy.internal" }))
      .toBe("https://proxy.internal");
  });

  it("derives the event socket domain from the SAME variable as the REST base", () => {
    // Static assertion: index.ts must pass a domain to WSClient, and it must come from
    // FEISHU_DOMAIN. Wiring only the REST side is the exact regression that shipped.
    const fs = require("node:fs") as typeof import("node:fs");
    const src = fs.readFileSync(require.resolve("../src/index.ts"), "utf8");
    const wsBlock = src.slice(src.indexOf("new lark.WSClient("));
    const ctor = wsBlock.slice(0, wsBlock.indexOf("loggerLevel"));
    expect(ctor).toMatch(/domain:/);
    expect(ctor).toMatch(/FEISHU_DOMAIN/);
    expect(src).toMatch(/FEISHU_DOMAIN\s*=\s*\(\(\)/); // validated once, at one declaration site
  });
});
