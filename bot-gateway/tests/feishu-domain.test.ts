/**
 * The tenant switch: one env var must drive BOTH the event long-connection and the REST base.
 *
 * These assert VALUES, not source text. The first version of this file matched the WSClient call
 * site with regexes, which could not fail for an inverted ternary — `FEISHU_DOMAIN === "lark" ?
 * Domain.Feishu : Domain.Lark` satisfied both `/domain:/` and `/FEISHU_DOMAIN/` while meaning the
 * exact opposite. Since both transports now resolve through src/feishu-domain.ts, the agreement
 * is structural and what remains to pin is the mapping itself.
 */
import * as lark from "@larksuiteoapi/node-sdk";
import { resolveTenant, wsDomainFor, restBaseFor } from "../src/feishu-domain";

describe("tenant resolution", () => {
  it("treats unset and empty as the China tenant (the documented default)", () => {
    expect(resolveTenant(undefined)).toBe("feishu");
    expect(resolveTenant("")).toBe("feishu");
    expect(resolveTenant("   ")).toBe("feishu");
  });

  it("accepts both tenants case-insensitively and with surrounding whitespace", () => {
    expect(resolveTenant("lark")).toBe("lark");
    expect(resolveTenant("LARK")).toBe("lark");
    expect(resolveTenant(" Lark\n")).toBe("lark");
    expect(resolveTenant("feishu")).toBe("feishu");
    expect(resolveTenant("FeiShu")).toBe("feishu");
  });

  it("returns null for a value that was set but is unrecognised, so the caller can fail loudly", () => {
    // Not "falls back to feishu": a typo means the operator's app is on the other tenant, and a
    // silent fallback leaves a gateway that looks healthy and receives nothing.
    expect(resolveTenant("larksuite")).toBeNull();
    expect(resolveTenant("feishu.cn")).toBeNull();
    expect(resolveTenant("international")).toBeNull();
  });
});

describe("transport targets", () => {
  it("maps each tenant to its own SDK domain", () => {
    expect(wsDomainFor("lark")).toBe(lark.Domain.Lark);
    expect(wsDomainFor("feishu")).toBe(lark.Domain.Feishu);
  });

  it("never maps the two tenants to the same socket domain", () => {
    // This is the assertion an inverted ternary cannot survive, and the reason the old
    // source-text version of this test was worthless.
    expect(wsDomainFor("lark")).not.toBe(wsDomainFor("feishu"));
  });

  it("maps each tenant to its own REST base", () => {
    expect(restBaseFor("feishu")).toBe("https://open.feishu.cn");
    expect(restBaseFor("lark")).toBe("https://open.larksuite.com");
  });

  it("keeps the socket domain and the REST base on the SAME tenant", () => {
    // The original bug: REST honoured the override while the socket silently stayed on Feishu.
    for (const tenant of ["feishu", "lark"] as const) {
      const isLark = tenant === "lark";
      expect(wsDomainFor(tenant) === lark.Domain.Lark).toBe(isLark);
      expect(restBaseFor(tenant).includes("larksuite")).toBe(isLark);
    }
  });
});

describe("REST base wiring in feishu-http", () => {
  const load = (env: Record<string, string | undefined>) => {
    const saved = process.env;
    // Build the replacement env by omission rather than by deleting computed keys: an explicit
    // `undefined` in `env` means "this variable must be absent", and copying is both clearer and
    // free of the dynamic-delete lint.
    const next: NodeJS.ProcessEnv = {};
    for (const [k, v] of Object.entries(saved)) {
      if (!(k in env)) next[k] = v;
    }
    for (const [k, v] of Object.entries(env)) {
      if (v !== undefined) next[k] = v;
    }
    process.env = next;
    let base: string;
    try {
      jest.resetModules();
      base = require("../src/feishu-http").FEISHU_API_BASE_FOR_TEST as string;
    } finally {
      process.env = saved;
    }
    return base;
  };

  it("derives the base from the tenant", () => {
    expect(load({ FEISHU_DOMAIN: "lark", FEISHU_API_BASE: undefined })).toBe("https://open.larksuite.com");
    expect(load({ FEISHU_DOMAIN: "feishu", FEISHU_API_BASE: undefined })).toBe("https://open.feishu.cn");
    expect(load({ FEISHU_DOMAIN: undefined, FEISHU_API_BASE: undefined })).toBe("https://open.feishu.cn");
  });

  it("still lets an explicit FEISHU_API_BASE win, for a proxy or private deployment", () => {
    expect(load({ FEISHU_DOMAIN: "lark", FEISHU_API_BASE: "https://proxy.internal" })).toBe("https://proxy.internal");
  });

  it("falls back to the China base rather than crashing on an unrecognised value", () => {
    // feishu-http is imported by modules that must not fail to load; index.ts owns the fatal
    // check, so this layer degrades instead of throwing at import time.
    expect(load({ FEISHU_DOMAIN: "bogus", FEISHU_API_BASE: undefined })).toBe("https://open.feishu.cn");
  });
});
