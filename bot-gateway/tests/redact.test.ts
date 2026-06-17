/**
 * Unit tests for redactSensitive — strips secrets/internal paths from agent
 * output before it reaches the Feishu group (POC doc #5: 不要泄露不该看到的东西).
 */

import { redactSensitive } from "../src/redact";

describe("redactSensitive", () => {
  it("redacts AWS access keys", () => {
    const out = redactSensitive("key is AKIA1234567890ABCDEF here");
    expect(out).not.toContain("AKIA1234567890ABCDEF");
    expect(out).toContain("[已隐藏]");
  });

  it("redacts bearer tokens and long hex secrets", () => {
    const out = redactSensitive("Authorization: Bearer abcdef0123456789abcdef0123456789");
    expect(out).not.toContain("abcdef0123456789abcdef0123456789");
  });

  it("redacts feishu app secrets after secret=/appSecret=", () => {
    const out = redactSensitive("appSecret=Xj3kLmN0pQrStUvWxYz12345678");
    expect(out).not.toContain("Xj3kLmN0pQrStUvWxYz12345678");
  });

  it("redacts private key blocks", () => {
    const out = redactSensitive("-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----");
    expect(out).not.toContain("MIIabc");
  });

  it("strips the /mnt/repo prefix to a safe relative form", () => {
    const out = redactSensitive("see /mnt/repo/agent-container/agent_lib.py:42");
    expect(out).toContain("agent-container/agent_lib.py:42");
    expect(out).not.toContain("/mnt/repo/");
  });

  it("leaves normal answer text untouched", () => {
    const text = "resolve_match 函数在 match_resolver.py 第 5 行，作用是扫描消除。";
    expect(redactSensitive(text)).toBe(text);
  });
});
