/**
 * Redact sensitive content from agent output before it reaches the Feishu group.
 *
 * POC doc #5 (不要泄露不该看到的东西): the answer text must never carry secrets,
 * tokens, private keys, or internal absolute mount paths. This is a gateway-side
 * safety net on top of the agent's system-prompt instruction — defense in depth.
 */

const REDACTED = "[已隐藏]";

const PATTERNS: Array<[RegExp, string | ((...args: string[]) => string)]> = [
  // AWS access key IDs.
  [/AKIA[0-9A-Z]{16}/g, REDACTED],
  // PEM private key blocks (multi-line).
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, REDACTED],
  // JWTs (header.payload.signature). Both leading segments start with the
  // base64url of '{"' = "eyJ"; each segment is terminated by a required literal
  // '.' it can't consume, so no ReDoS. Bare JWTs (no key= prefix) are the common
  // shape in auth-header constants / fixtures / env dumps the agent reads.
  [/eyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/g, REDACTED],
  // Bearer tokens.
  [/Bearer\s+[A-Za-z0-9._-]{16,}/g, `Bearer ${REDACTED}`],
  // Basic-auth headers: "Basic <base64>" decodes straight to user:password.
  // ANCHORED to an Authorization header (covers Proxy-Authorization too, whose
  // suffix contains "Authorization:") + real base64 shape (core chars then 0-2
  // '=' padding). Without the anchor, a bare "Basic <word>" matched ordinary
  // prose ("Basic mechanics" → "Basic [已隐藏]") and corrupted answers — the
  // prefix "Basic" is a common English word, unlike the other fixed prefixes.
  [/(Authorization\s*:\s*)Basic\s+[A-Za-z0-9+/]{8,}={0,2}/gi,
    (_m, pre: string) => `${pre}Basic ${REDACTED}`],
  // High-distinctiveness, fixed-prefix vendor tokens (no key= needed; unique
  // prefixes → near-zero false positives). Each is a single char-class with a
  // length floor — no nested quantifier, no ReDoS.
  [/xox[baprs]-[A-Za-z0-9-]{10,}/g, REDACTED],     // Slack
  [/AIza[0-9A-Za-z_-]{35}/g, REDACTED],            // Google API key
  [/npm_[A-Za-z0-9]{36,}/g, REDACTED],             // npm access token
  [/pypi-[A-Za-z0-9_-]{16,}/g, REDACTED],          // PyPI API token
  // GitHub personal access tokens (ghp_/gho_/ghs_/ghr_ + 36+ chars), no key prefix.
  [/gh[pousr]_[A-Za-z0-9]{36,}/g, REDACTED],
  // Feishu/Lark access tokens: tenant_access_token (t-), app_access_token (a-),
  // user_access_token (u-). A BARE "t-<20+ chars>" prefix rule over-redacts benign
  // snake_case identifiers that happen to start t-/a-/u- (e.g.
  // "t-distribution_table_…", "a-z_lookup_…") — verified false positives. So
  // ANCHOR to a Feishu-token CONTEXT cue (the access-token key word right before
  // the value), mirroring the Basic-auth/key=value anchoring. Captures the keyword
  // + optional :/= separator, redacts only the value. Bodies allow [A-Za-z0-9_-]
  // here because the anchor already removes the false-positive risk. No nested
  // quantifier → no ReDoS.
  [/((?:tenant|app|user)?_?access_token["']?\s*[:=]\s*["']?)[tau]-[A-Za-z0-9_-]{12,}/gi,
    (_m, pre: string) => `${pre}${REDACTED}`],
  // key=value secrets. The KEY alternation covers pwd/pass/private_key in addition
  // to secret/token/password/api_key (client_secret/access_token already match via
  // the secret/token substrings). The VALUE class is "everything up to a
  // whitespace/quote/structural delimiter" so a base64 / path-style secret
  // (containing / + =) is redacted IN FULL — the old [A-Za-z0-9._-]+ stopped at
  // the first '/'+'=' and leaked the tail (AWS secret access keys, SAS tokens).
  // The value is a single negated char-class with a length floor → no ReDoS; the
  // recognized key prefix keeps it anchored so prose isn't over-redacted.
  // The KEY may carry surrounding identifier chars (bounded {0,32} → no ReDoS),
  // so AWS_SECRET_ACCESS_KEY / db_password / X_API_KEY all match via their inner
  // token. Bare "pass" is guarded by (?![a-z]) so it matches pass=/db_pass= but
  // NOT passing_score=/passenger=. The VALUE is guarded by (?![\d.,]+(?:\s|$|...))
  // — i.e. a PURELY-NUMERIC value is NOT redacted: real secrets are never
  // all-digits, but game-balance fields whose NAME embeds a token word
  // (token_reward=50000000, access_key_count=99999999) are exactly the NUMBERS
  // this product must surface to planners. So we redact only non-numeric values
  // (actual keys/tokens), preserving numeric config. (A secret that is coincidentally
  // all-digits is implausible; the conn-string / vendor-prefix patterns still
  // cover other shapes.)
  [/([A-Za-z0-9_]{0,32}(?:secret|token|password|passwd|pwd|pass(?![a-z])|api[_-]?key|private[_-]?key|access[_-]?key)[A-Za-z0-9_]{0,32})(["']?\s*[:=]\s*["']?)(?![\d.,]+(?:["'\s,;)}\]]|$))([^\s"'`,;)}\]]{8,})/gi,
    (_m, k: string, sep: string) => `${k}${sep}${REDACTED}`],
  // Connection-string inline password: scheme://user:PASSWORD@host (jdbc:mysql://,
  // mongodb://, redis://, https:// with userinfo …). The password sits between
  // ':' and '@' with no `password=` key prefix, so the keyed pattern above misses
  // it. Redact ONLY the password segment; keep scheme/user/host so the citation
  // stays readable. Crafted to NOT touch the in-VPC index URL (http://10.x:8080/mcp,
  // no userinfo), plain URLs, host:port, file:line refs, or CJK "比率 3:4".
  // The SCHEME is bounded ({0,39}) to avoid catastrophic backtracking (ReDoS):
  // the blowup came SOLELY from an unbounded scheme `[a-zA-Z0-9+.-]*` next to the
  // literal "://" (verified: bounding the scheme alone drops a 100k adversarial
  // "xxx://aaa…"-no-"@" from ~18s to ~20ms). The userinfo/password groups stay
  // UNBOUNDED on purpose: each is a single negated char-class terminated by a
  // required literal (":" / "@") it can't consume, so it can't backtrack
  // catastrophically — and a {1,256} cap on the password would silently LEAK a
  // password longer than 256 chars (long tokens/JWTs used as a connection
  // password are common) by failing the whole match. Real schemes are short, so
  // {0,39} covers them with no blowup. The password class EXCLUDES '@' (its
  // terminator) but ALLOWS '/' so a base64/AWS-secret-style password containing
  // '/' (e.g. wJalrXUt.../K7MDENG...) is fully redacted rather than failing the
  // whole match at the first '/' and leaking it; the userinfo (pre-':') still
  // excludes '/' so a plain "http://host/path" with no '@' can't false-match.
  [/([a-zA-Z][a-zA-Z0-9+.-]{0,39}:\/\/[^\s:@/]*):([^\s@]+)@/g,
    (_m, pre: string) => `${pre}:${REDACTED}@`],
];

export function redactSensitive(text: string): string {
  let out = text;
  for (const [re, repl] of PATTERNS) {
    out = typeof repl === "function"
      ? out.replace(re, repl as (...args: string[]) => string)
      : out.replace(re, repl);
  }
  // EXACT-match the process's OWN Feishu app secret. The app secret is ~32 chars
  // with NO fixed prefix/shape, so no general pattern can catch it without heavy
  // false positives — but we hold the exact value, so a literal replace is a
  // zero-false-positive, 100%-reliable catch for the single most sensitive string
  // the system possesses (covers a bare echo with no key= prefix). Length floor
  // avoids nuking a short/empty env value. Recomputed each call (cheap) so a
  // rotated secret is picked up without restart.
  const appSecret = process.env.FEISHU_APP_SECRET;
  if (appSecret && appSecret.length >= 12) out = out.split(appSecret).join(REDACTED);
  // Strip the internal EFS mount prefix; keep the meaningful relative path so
  // code citations (file:line) still work, just without exposing /mnt/repo.
  out = out.replace(/\/mnt\/repo\//g, "");
  return out;
}

/**
 * Redact every reasoning-panel step. The agent's narration steps are rendered
 * in the (group-visible) 分析过程 panel just like the conclusion, so they need
 * the SAME redaction — a secret/path leaking via a "thinking" step is no less a
 * leak than via the answer.
 */
export function redactSteps(steps: string[]): string[] {
  return steps.map(redactSensitive);
}

/**
 * Deep-redact every STRING leaf of an agent-generated chart spec (VChart). A
 * chart's titles / axis & series labels / data string values / tooltips are
 * rendered into the group-visible card just like the conclusion, so they need
 * the SAME scrubbing — a secret/path that lands in a chart field is no less a
 * leak. Walks the structure in place-safe fashion (returns a new value),
 * touching only strings so numbers/booleans/shape are preserved.
 */
export function redactDeep<T>(value: T): T {
  if (typeof value === "string") return redactSensitive(value) as unknown as T;
  if (Array.isArray(value)) return value.map((v) => redactDeep(v)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    // Redact only VALUES (recursively), NEVER object KEYS. A VChart data record's
    // keys ARE the chart's field names (e.g. {"等级":"Lv1","攻击":100}) and the spec's
    // xField/yField/seriesField/categoryField VALUES point at those keys by name.
    // If we redacted a key, the field-reference value (redacted independently)
    // would no longer match it → VChart binds nothing → the chart renders with AXES
    // but NO bars/lines, while the tooltip still shows the raw datum (the exact
    // "empty plot, hover shows data" bug). Field names are business labels the
    // agent authored from data it read, not file content — a secret/path in a
    // chart KEY is implausible, whereas a broken binding is a real, observed defect.
    // The genuine leak surface (data values, titles, axis/legend/tooltip text) is
    // all in string VALUES, which are still fully redacted.
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = redactDeep(v);
    }
    return out as unknown as T;
  }
  return value;
}
