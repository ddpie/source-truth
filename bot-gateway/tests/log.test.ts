/**
 * Unit tests for hashUserId — PII desensitization for structured logs
 * (AGENTS.md: 用户标识用 hashUserId 脱敏).
 */

import { hashUserId } from "../src/log";

describe("hashUserId", () => {
  it("is stable for the same id", () => {
    expect(hashUserId("oc_abc123")).toBe(hashUserId("oc_abc123"));
  });

  it("differs for different ids", () => {
    expect(hashUserId("oc_abc123")).not.toBe(hashUserId("oc_xyz789"));
  });

  it("does not leak the raw id (non-reversible, short token)", () => {
    const raw = "om_1234567890abcdef";
    const out = hashUserId(raw);
    expect(out).not.toContain(raw);
    expect(out.startsWith("u_")).toBe(true);
    expect(out.length).toBeLessThanOrEqual(16); // "u_" + 12 hex
  });

  it("maps empty/missing id to 'anon' (never crashes logging)", () => {
    expect(hashUserId("")).toBe("anon");
    expect(hashUserId(undefined)).toBe("anon");
    expect(hashUserId(null)).toBe("anon");
  });
});
