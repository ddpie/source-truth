/**
 * Unit tests for redactSensitive — strips secrets/internal paths from agent
 * output before it reaches the Feishu group (POC doc #5: 不要泄露不该看到的东西).
 */

import { redactSensitive, redactSteps, redactDeep } from "../src/redact";

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

  it("redacts inline password in connection strings, keeps scheme/user/host", () => {
    for (const [url, pass] of [
      ["jdbc:mysql://gameuser:Sup3rSecretDbPass@db.prod:3306/game", "Sup3rSecretDbPass"],
      ["mongodb://admin:My_Str0ng_Pass99@cluster0.mongodb.net/players", "My_Str0ng_Pass99"],
      ["redis://:LongRedisPassword123@cache:6379/0", "LongRedisPassword123"],
    ] as const) {
      const out = redactSensitive(`配置：${url}`);
      expect(out).not.toContain(pass);            // password gone
      expect(out).toContain("[已隐藏]");
      expect(out.split("@")[1]).toContain(url.split("@")[1]); // host/db preserved
    }
  });

  it("does NOT touch benign URLs / host:port / file:line / CJK colons", () => {
    for (const safe of [
      "http://10.1.1.5:8080/mcp",          // in-VPC index endpoint (no userinfo)
      "https://example.com/path?x=1",
      "见 config/Hero.json:42 的 ResolveMatch()",
      "暴击率约为 3:4 的比例",
      "服务在 db.internal:3306 上",
    ]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("redacts a GitHub PAT", () => {
    const out = redactSensitive("token ghp_" + "a".repeat(36) + " 用于拉代码");
    expect(out).not.toContain("ghp_" + "a".repeat(36));
    expect(out).toContain("[已隐藏]");
  });

  it("leaves normal answer text untouched", () => {
    const text = "resolve_match 函数在 match_resolver.py 第 5 行，作用是扫描消除。";
    expect(redactSensitive(text)).toBe(text);
  });

  it("redacts a LONG connection-string password (>256 chars, e.g. a token/JWT)", () => {
    // A {1,256} cap once made this leak: a 320-char password never reached the
    // closing '@', so the whole pattern failed to match and the secret passed
    // through. Long tokens-as-password (JWT/RDS-IAM/SAS) are realistic.
    const longPw = "T0ken".repeat(80); // 400 chars, all in [^\s:@/]
    const out = redactSensitive(`jdbc:postgresql://app:${longPw}@prod-db:5432/game`);
    expect(out).not.toContain(longPw);
    expect(out).toContain("[已隐藏]");
    expect(out).toContain("@prod-db:5432/game"); // host/db preserved
  });

  it("does not catastrophically backtrack (ReDoS) on adversarial input", () => {
    // The connection-string pattern once had unbounded quantifiers around "://"
    // that backtracked exponentially on "xxx://aaa…" with no closing "@" (18s on
    // 100k chars). Bounded quantifiers fix it. The agent can read a long minified
    // file, so a slow redactor would freeze the streaming card. Assert it stays
    // fast on the worst cases.
    const worst = [
      "x".repeat(50000) + "://" + "a".repeat(50000),
      "redis://" + "u".repeat(100000),
      "ghp_" + "a".repeat(100000),
    ];
    for (const s of worst) {
      const t0 = Date.now();
      redactSensitive(s);
      expect(Date.now() - t0).toBeLessThan(1000); // was ~18000ms before the fix
    }
  });
});

describe("redactSteps", () => {
  it("redacts secrets/paths in every reasoning step (panel is group-visible)", () => {
    const steps = [
      "正在定位 calcDamage 函数",
      "读取 /mnt/repo/config/secrets.json",
      "appSecret=Xj3kLmN0pQrStUvWxYz12345678",
    ];
    const out = redactSteps(steps);
    expect(out[0]).toBe("正在定位 calcDamage 函数"); // benign step untouched
    expect(out[1]).not.toContain("/mnt/repo/");
    expect(out[2]).not.toContain("Xj3kLmN0pQrStUvWxYz12345678");
  });

  it("returns a same-length array (1:1 mapping)", () => {
    expect(redactSteps(["a", "b", "c"]).length).toBe(3);
    expect(redactSteps([])).toEqual([]);
  });
});

describe("redactDeep (chart specs)", () => {
  it("scrubs secrets/paths in every string leaf of a chart spec", () => {
    const spec = {
      type: "bar",
      title: { text: "数值表 /mnt/repo/config/Hero.json" },
      data: {
        values: [
          { label: "appSecret=Xj3kLmN0pQrStUvWxYz12345678", value: 42 },
          { label: "正常等级 1", value: 100 },
        ],
      },
    };
    const out = redactDeep(spec);
    expect(out.title.text).not.toContain("/mnt/repo/");
    expect(out.title.text).toContain("数值表 config/Hero.json");
    expect(out.data.values[0].label).not.toContain("Xj3kLmN0pQrStUvWxYz12345678");
    // Numbers and structure are preserved (only strings are touched).
    expect(out.data.values[0].value).toBe(42);
    expect(out.data.values[1].label).toBe("正常等级 1");
    expect(out.type).toBe("bar");
  });

  it("preserves non-string scalars and shape", () => {
    const spec = { type: "line", n: 7, flag: true, nil: null, arr: [1, 2, 3] };
    expect(redactDeep(spec)).toEqual(spec);
  });
});
