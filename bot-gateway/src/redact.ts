/**
 * Redact sensitive content from agent output before it reaches the Feishu group.
 *
 * POC doc #5 (不要泄露不该看到的东西): the answer text must never carry secrets,
 * tokens, private keys, or internal absolute mount paths. This is a gateway-side
 * safety net on top of the agent's system-prompt instruction — defense in depth.
 */

import { stripToolCallLeak } from "./strip-toolcall-leak";

const REDACTED = "[已隐藏]";

const PATTERNS: Array<[RegExp, string | ((...args: string[]) => string)]> = [
  // AWS access key IDs.
  [/AKIA[0-9A-Z]{16}/g, REDACTED],
  // AWS SigV4 Authorization header (Credential=AKIA…/… + Signature=<hex>). The
  // whole credential scope + signature is sensitive. Single char-classes ended by
  // required literals → no ReDoS.
  [/AWS4-HMAC-SHA256\s+Credential=[^\s,]+(?:,\s*SignedHeaders=[^\s,]+)?(?:,\s*Signature=[0-9a-f]+)?/gi, REDACTED],
  // AWS STS session token (x-amz-security-token header OR AWS_SESSION_TOKEN= dump):
  // a long opaque base64 blob with no fixed prefix → anchor to its key/header name
  // so we don't over-redact. The value class allows +/=_- (base64url + padding).
  [/((?:x-amz-security-token|aws_session_token|sessiontoken)["']?\s*[:=]\s*["']?)[A-Za-z0-9+/=_-]{20,}/gi,
    (_m, pre: string) => `${pre}${REDACTED}`],
  // Presigned-URL signing params in a query string (X-Amz-Signature / -Credential /
  // -Security-Token). Redact only the value up to the next '&' or delimiter.
  [/(X-Amz-(?:Signature|Credential|Security-Token)=)[^&\s"'`]+/gi,
    (_m, pre: string) => `${pre}${REDACTED}`],
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
  // GitHub FINE-GRAINED PAT (github_pat_ + base62/underscore). The classic gh[pousr]_
  // rule above does NOT cover this newer prefix (cross-review).
  [/github_pat_[A-Za-z0-9_]{60,}/g, REDACTED],
  // Stripe secret keys (sk_live_ / sk_test_ + 16+). Fixed prefix → near-zero FP.
  [/sk_(?:live|test)_[A-Za-z0-9]{16,}/g, REDACTED],
  // OpenAI keys (sk- / sk-proj- + 20+). Fixed `sk-` prefix; bound the body to
  // [A-Za-z0-9_-] and require length so it can't swallow a hyphenated identifier.
  [/sk-(?:proj-)?[A-Za-z0-9_-]{20,}/g, REDACTED],
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
  // `account[_-]?key` is included so an Azure Storage connection string's
  // `AccountKey=…` is anchored (bare `key` alone is NOT a member — it would
  // over-redact `foreign_key`, `sort_key`, `primary_key` game fields — but the
  // distinctive `accountkey`/`account_key` shape is a real credential, near-zero FP).
  [/([A-Za-z0-9_]{0,32}(?:secret|token|password|passwd|pwd|pass(?![a-z])|api[_-]?key|private[_-]?key|access[_-]?key|account[_-]?key)[A-Za-z0-9_]{0,32})(["']?\s*[:=]\s*["']?)(?![\d.,]+(?:["'\s,;)}\]]|$))([^\s"'`,;)}\]]{8,})/gi,
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
  // INTERNAL INFRASTRUCTURE TOPOLOGY (cross-review): the agent legitimately reads infra
  // config / IaC, so an internal AWS hostname or bucket URI can land in a citation. These
  // are recon-useful internal-topology disclosure (same class as the /mnt/repo path scrub
  // below) and have DISTINCTIVE shapes that don't collide with game data — so redact them.
  // Deliberately NARROW (no bare RFC1918 IP rule: "10.0.13.42"-shaped strings also appear
  // as version numbers / coordinates / ID tuples in game data → too high a false-positive
  // rate; the in-VPC index URL is a tool target that never reaches answer content anyway).
  // EC2 auto-assigned internal DNS: ip-10-0-13-42.<region>.compute.internal /
  // ip-…​.ec2.internal. This embeds the actual PRIVATE IP (10-0-13-42), so it's genuine
  // internal-topology disclosure — redact it. (We deliberately do NOT redact a plain
  // short internal hostname like `db.internal:3306`: that's low-recon-value and useful
  // in a citation — see the benign-host test. Only the IP-bearing EC2 DNS form is
  // scrubbed.) ReDoS-safe: fixed `ip-`, bounded numeric groups, single required tail.
  [/\bip-(?:\d{1,3}-){3}\d{1,3}(?:\.[a-z0-9-]{1,40}){0,3}\.(?:compute(?:-\d)?|ec2)\.internal\b/gi, REDACTED],
  // S3 bucket URIs — internal bucket naming is reconnaissance-useful. Single bounded
  // char-class for the bucket + an optional key path → no nested quantifier, no ReDoS.
  // The path class must NOT be a broad `[^\s"'`]*`: Chinese answer text (the product's
  // primary language) has no spaces, so a greedy class would swallow the rest of the
  // sentence after an inline `s3://…` citation into [已隐藏] (cross-review P1 — my own
  // test masked it with a trailing ASCII space). Restrict the path to real S3-key chars
  // (alnum, / _ - . and a few url-safe) and STOP at CJK / commas / 。 / parens / quotes /
  // markdown — same tight-termination discipline as the sibling presigned-URL pattern.
  // Exclude `()` from the path class too: a markdown link `[t](s3://b/k)` would
  // otherwise eat the closing `)`. S3 keys CAN contain parens, so this very slightly
  // under-redacts such a key's tail — but the bucket name (the recon-sensitive part) is
  // still scrubbed, and keeping markdown links intact matters more.
  [/\bs3:\/\/[a-z0-9][a-z0-9.-]{2,62}(?:\/[A-Za-z0-9!_.*'/-]*)?/g, REDACTED],
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
  // Strip a legacy /mnt/repo/ prefix to its repo-relative form. Paths are now
  // returned repo-relative by the index-service (no mount), so this is a
  // back-compat safety net: it still scrubs the prefix if it ever appears (e.g.
  // a path embedded in the indexed code's own content, or a stale cached answer),
  // keeping code citations (file:line) intact without exposing an internal path.
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
  // Strip leaked tool-call markup FIRST: on the MCP-init-race the model writes
  // <invoke>/<function_calls> XML into its NARRATION text, which lands in `steps`
  // and renders raw in the 分析过程 panel (the body/evidence get stripped elsewhere,
  // but the panel did not — observed live). Strip per step, then redact secrets, and
  // drop any step that was PURE markup (empty after stripping) so the panel shows
  // only real narration.
  return steps
    .map(stripToolCallLeak)
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map(redactSensitive);
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
