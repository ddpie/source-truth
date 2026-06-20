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
      "服务在 db.internal:3306 上",          // short internal hostname kept (low recon, useful in citation)
    ]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("redacts an Azure Storage AccountKey (bare `key` excluded, account_key included) (cross-review)", () => {
    const out = redactSensitive("AccountKey=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA== 用于存储");
    expect(out).not.toContain("Zm9vYmFyYmF6");
    expect(out).toContain("[已隐藏]");
    // a benign game field whose name merely ends in `key` must SURVIVE (no bare-`key` rule)
    expect(redactSensitive("foreign_key=hero_id")).toBe("foreign_key=hero_id");
    expect(redactSensitive("sort_key=level_asc")).toBe("sort_key=level_asc");
  });

  it("redacts EC2 auto-assigned internal DNS (embeds the private IP) but not a plain *.internal host", () => {
    const out = redactSensitive("backend at ip-10-0-13-42.ap-northeast-1.compute.internal:8080");
    expect(out).not.toContain("10-0-13-42");
    expect(out).toContain("[已隐藏]");
    // a plain short internal hostname is intentionally kept (benign-host design decision)
    expect(redactSensitive("服务在 db.internal:3306 上")).toBe("服务在 db.internal:3306 上");
  });

  it("redacts an internal S3 bucket URI (reconnaissance-useful naming)", () => {
    const out = redactSensitive("artifacts in s3://source-truth-artifacts-prod/bin/codegraph-server staged");
    expect(out).not.toContain("source-truth-artifacts-prod");
    expect(out).toContain("[已隐藏]");
  });

  it("S3 redaction does NOT over-consume following CJK prose / markdown (cross-review P1)", () => {
    // Chinese has no spaces, so a broad `[^\s]*` path class would swallow the rest of the
    // sentence after an inline s3:// citation. The path must stop at CJK punctuation.
    const cjk = redactSensitive("构建产物上传到 s3://my-bucket/bin/server，部署脚本会从这里拉取。");
    expect(cjk).not.toContain("my-bucket");
    expect(cjk).toContain("部署脚本会从这里拉取");   // trailing sentence survives
    expect(cjk).toContain("，");
    // a markdown link's closing paren must survive (path class excludes `()`)
    const md = redactSensitive("见 [产物](s3://my-bucket/path/file.bin) 第3行");
    expect(md).not.toContain("my-bucket");
    expect(md).toContain(") 第3行");
  });

  it("does NOT redact IP-like game data (versions / coordinates) — no bare RFC1918 rule", () => {
    for (const safe of ["版本 10.0.13.42 上线", "坐标 (10.0.13.42)"]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("redacts a GitHub PAT", () => {
    const out = redactSensitive("token ghp_" + "a".repeat(36) + " 用于拉代码");
    expect(out).not.toContain("ghp_" + "a".repeat(36));
    expect(out).toContain("[已隐藏]");
  });

  it("redacts newer secret prefixes: github_pat_ / sk_live_ / sk-proj- (cross-review)", () => {
    const ghpat = "github_pat_11ABCDE0000_" + "a".repeat(60);
    expect(redactSensitive(ghpat)).not.toContain(ghpat);
    const stripe = "sk_live_4eC39HqLyjWDarjtT1zdp7dc";
    expect(redactSensitive(stripe)).not.toContain(stripe);
    const openai = "sk-proj-" + "a".repeat(24);
    expect(redactSensitive(openai)).not.toContain(openai);
  });

  it("does NOT over-redact a short sk- token that is not a key", () => {
    // "sk-3" (a game term) is below the 20-char body floor → must survive.
    const text = "技能 sk-3 的冷却是 5 秒。";
    expect(redactSensitive(text)).toBe(text);
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

  it("redacts a bare JWT (eyJ.eyJ.sig) with no key prefix", () => {
    const jwt = "eyJhbGciOiJIUzI1Ni9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36";
    const out = redactSensitive(`Authorization header: ${jwt}`);
    expect(out).not.toContain(jwt);
    expect(out).toContain("[已隐藏]");
  });

  it("redacts vendor tokens with no key prefix (Slack/Google/npm/PyPI)", () => {
    for (const tok of [
      "xoxb-2345678901-2345678901234-AbCdEfGhIjKlMnOpQrStUvWx",
      "AIzaSyD-1234567890abcdefghijklmnopqrstuv",
      "npm_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
      "pypi-AgEIcHlwaS5vcmcAAAAAAAAAAA",
    ]) {
      expect(redactSensitive(`配置里有 ${tok} 这一行`)).not.toContain(tok);
    }
  });

  it("redacts Feishu access tokens in their key context (tenant/app/user_access_token=)", () => {
    for (const line of [
      "tenant_access_token=t-g204o8m5kf9d83jdkfjghd83extra",
      "app_access_token: a-abc123def456ghi789jkl012mno",
      'user_access_token="u-zyxw9876543210abcdefghij00"',
      "access_token=t-g204o8m5kf9d83jdkfjghd83extra",
    ]) {
      const out = redactSensitive(`调用失败：${line} 过期了`);
      expect(out).toContain("[已隐藏]");
      expect(out).not.toMatch(/t-g204o8m5|a-abc123def|u-zyxw98765/);
    }
  });

  it("does NOT over-redact snake_case / kebab identifiers that merely start t-/a-/u-", () => {
    // The token rule is anchored to an access_token key context, so identifiers
    // that coincidentally start t-/a-/u- (incl. underscore-joined snake_case with
    // no early hyphen) survive untouched — they're config names planners ask about.
    for (const safe of [
      "a-very-long-kebab-case-component-name",
      "u-boat-simulator-game-mode-config",
      "the t-test statistic was significant",
      "t-distribution_table_with_long_suffix_here",
      "a-z_compression_lookup_table_v2_field",
    ]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("exact-redacts the process's own FEISHU_APP_SECRET even with no key= prefix", () => {
    const prev = process.env.FEISHU_APP_SECRET;
    process.env.FEISHU_APP_SECRET = "lWAOtestSecretValue123456";
    try {
      const out = redactSensitive("报错信息里混进了 lWAOtestSecretValue123456 这个串");
      expect(out).not.toContain("lWAOtestSecretValue123456");
      expect(out).toContain("[已隐藏]");
    } finally {
      if (prev === undefined) delete process.env.FEISHU_APP_SECRET;
      else process.env.FEISHU_APP_SECRET = prev;
    }
  });

  it("redacts a Basic-auth header (base64 of user:pass)", () => {
    const b64 = "YWRtaW46c3VwZXJzZWNyZXRwYXNzd29yZA==";
    const out = redactSensitive(`Authorization: Basic ${b64}`);
    expect(out).not.toContain(b64);
    expect(out).toContain("Basic [已隐藏]");
  });

  it("does NOT touch the English word 'Basic' in ordinary prose (anchor to header)", () => {
    // Basic-auth redaction is anchored to "Authorization:" — a bare "Basic <word>"
    // is normal prose ("Basic mechanics") and must survive untouched, or the
    // non-technical answer gets mangled mid-sentence.
    for (const prose of [
      "Basic mechanics overview of the system",
      "Basic configuration loads first",
      "Basic 机制：连击伤害提升到 1.5 倍",
    ]) {
      expect(redactSensitive(prose)).toBe(prose);
    }
  });

  it("redacts the FULL value when a secret contains base64 chars (/ + =)", () => {
    // The old value class [A-Za-z0-9._-]+ stopped at the first '/' and leaked the
    // tail. AWS secret access keys and base64 tokens routinely contain / + =.
    for (const [line, leakNeedle] of [
      ["password=YWRtaW46c3VwZXJ/c2VjcmV0+cGFzcw==", "c2VjcmV0"],
      ["AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "K7MDENG"],
    ] as const) {
      expect(redactSensitive(line)).not.toContain(leakNeedle);
    }
  });

  it("redacts pwd= / pass= / private_key= keyed secrets", () => {
    for (const line of [
      "pwd=My_Str0ng_Pass99x",
      "pass=My_Str0ng_Pass99x",
      "private_key=My_Str0ng_Pass99xZ",
      "db_password: hunter2hunter2hunter2",
    ]) {
      const out = redactSensitive(line);
      expect(out).toContain("[已隐藏]");
      expect(out).not.toMatch(/My_Str0ng_Pass99x|hunter2hunter2hunter2/);
    }
  });

  it("redacts a connection-string password containing '/' (was a total leak)", () => {
    // password group once excluded '/', so it couldn't reach the closing '@' and
    // the WHOLE match failed → the entire password leaked.
    const out = redactSensitive("mongodb://u:pa/sssecretword@h:27017/db");
    expect(out).not.toContain("sssecretword");
    expect(out).toContain("@h:27017/db");
  });

  it("does NOT over-redact game-balance numbers whose field merely contains 'pass'", () => {
    // This product surfaces NUMBERS for planners; a value must not be redacted
    // just because the field name contains the substring 'pass'.
    for (const safe of ["passing_score=85", "passenger_count=120", "the password policy needs 8 chars"]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("does NOT over-redact a NUMERIC value even when the field name embeds a secret word", () => {
    // token_reward / access_key_count / max_password_attempts are game-config
    // NUMBERS planners ask about — a real secret is never all-digits, so a numeric
    // value is preserved even though the field name contains token/access_key/etc.
    for (const safe of [
      "token_reward=50000000",
      "access_key_count=99999999",
      "item_pass_rate=87654321",
      "max_password_attempts=10000000",
    ]) {
      expect(redactSensitive(safe)).toBe(safe);
    }
  });

  it("STILL redacts a non-numeric secret value when the field embeds a secret word", () => {
    // The numeric-value carve-out must not let an actual key/token through.
    for (const [line, secret] of [
      ["session_secret=Xj3kLmN0pQrStUvWx", "Xj3kLmN0pQrStUvWx"],
      ["api_token=A1b2C3d4E5f6G7h8", "A1b2C3d4E5f6G7h8"],
    ] as const) {
      expect(redactSensitive(line)).not.toContain(secret);
    }
  });

  it("redacts AWS SigV4 / STS / presigned-URL credentials (no AWS creds should ever surface)", () => {
    const sig = "Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260619/ap-northeast-1/bedrock/aws4_request, SignedHeaders=host, Signature=abcd1234ef567890";
    expect(redactSensitive(sig)).not.toContain("AKIAIOSFODNN7EXAMPLE");
    expect(redactSensitive(sig)).not.toContain("abcd1234ef567890");
    expect(redactSensitive("x-amz-security-token: IQoJb3JpZ2luX2VjEC8aDmFwLW5vcnRoL1MQ==")).not.toContain("IQoJb3JpZ2luX2Vj");
    expect(redactSensitive("AWS_SESSION_TOKEN=FwoGZXIvYXdzEXAMPLEabc123def456")).not.toContain("FwoGZXIvYXdzEXAMPLE");
    const url = "https://s3.amazonaws.com/b/k?X-Amz-Signature=deadbeef1234&X-Amz-Credential=AKIA/x";
    expect(redactSensitive(url)).not.toContain("deadbeef1234");
  });

  it("does NOT over-redact code-QA content next to the new AWS patterns", () => {
    for (const real of [
      "负重上限 = 力量 × 1.5，见 FormulaHelper.cs:75。",
      "掉落数量 token_reward=50000000 是配置值。",
      "比率是 3:4，在 http://10.1.1.97:8080/mcp 读取。",
    ]) {
      expect(redactSensitive(real)).toBe(real);
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

  it("keeps benign steps 1:1 (no markup → no drop)", () => {
    expect(redactSteps(["先定位函数", "读取配置", "得出结论"]).length).toBe(3);
    expect(redactSteps([])).toEqual([]);
  });

  // REGRESSION (observed live on a sonnet card): the MCP-init-race makes the model
  // write <invoke> tool-call XML into its NARRATION, which landed RAW in the 分析过程
  // panel (body/evidence were stripped, steps were not).
  it("strips leaked tool-call markup from a step, keeping the real narration", () => {
    const steps = [
      "先找一下怪物相关的配置表和数值设定逻辑。<function_calls>\n<invoke name=\"codegraph_search_files\">\n<parameter name=\"pattern\">monster</parameter>\n</invoke>\n</function_calls>",
    ];
    const out = redactSteps(steps);
    expect(out).toHaveLength(1);
    expect(out[0]).toBe("先找一下怪物相关的配置表和数值设定逻辑。");
    expect(out[0]).not.toContain("invoke");
    expect(out[0]).not.toContain("function_calls");
  });

  it("drops a step that is PURE tool-call markup (nothing real left)", () => {
    const steps = [
      "真正的分析narration。",
      "<function_calls>\n<invoke name=\"codegraph_glob_files\">\n<parameter name=\"pattern\">**/*.cs</parameter>\n</invoke>\n</function_calls>",
    ];
    const out = redactSteps(steps);
    expect(out).toEqual(["真正的分析narration。"]); // pure-markup step removed
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

  it("PRESERVES object keys so chart field bindings survive (xField/yField must keep matching data keys)", () => {
    // A VChart spec binds series via xField/yField VALUES that name the data-record
    // KEYS. Redacting keys would desync them → axes render but no bars/lines (tooltip
    // still shows data) — the observed "empty plot" bug. Keys must pass through verbatim;
    // only string VALUES are scrubbed (the real leak surface).
    const spec = {
      type: "bar",
      data: { values: [{ "等级": "Lv1", "攻击": 100 }, { "等级": "Lv2", "攻击": 150 }] },
      xField: "等级",
      yField: "攻击",
    };
    const out = redactDeep(spec) as typeof spec;
    // Keys preserved exactly → xField/yField still match.
    expect(Object.keys(out.data.values[0])).toEqual(["等级", "攻击"]);
    expect(out.xField).toBe("等级");
    expect(out.yField).toBe("攻击");
    expect(out.data.values[0]["等级"]).toBe("Lv1"); // still bound
    expect(out.data.values[0]["攻击"]).toBe(100);
  });

  it("still scrubs a secret/path that appears as a string VALUE in chart data", () => {
    const spec = { data: { values: [{ name: "/mnt/repo/Hero.cs", secret: "appSecret=Xj3kLmN0pQrStUvWxYz12345678" }] } };
    const out = redactDeep(spec) as { data: { values: Array<Record<string, string>> } };
    expect(out.data.values[0].name).not.toContain("/mnt/repo/");      // value scrubbed
    expect(out.data.values[0].secret).not.toContain("Xj3kLmN0pQrStUvWxYz12345678");
    expect(Object.keys(out.data.values[0])).toEqual(["name", "secret"]); // keys intact
  });
});
