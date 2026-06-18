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
  // Bearer tokens.
  [/Bearer\s+[A-Za-z0-9._-]{16,}/g, `Bearer ${REDACTED}`],
  // secret= / appSecret= / token= / password= followed by a long value.
  [/((?:app)?secret|token|password|passwd|api[_-]?key)(["']?\s*[:=]\s*["']?)([A-Za-z0-9._-]{12,})/gi,
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
  // {0,39} covers them with no blowup.
  [/([a-zA-Z][a-zA-Z0-9+.-]{0,39}:\/\/[^\s:@/]*):([^\s:@/]+)@/g,
    (_m, pre: string) => `${pre}:${REDACTED}@`],
  // GitHub personal access tokens (ghp_/gho_/ghs_/ghr_ + 36+ chars), no key prefix.
  [/gh[pousr]_[A-Za-z0-9]{36,}/g, REDACTED],
];

export function redactSensitive(text: string): string {
  let out = text;
  for (const [re, repl] of PATTERNS) {
    out = typeof repl === "function"
      ? out.replace(re, repl as (...args: string[]) => string)
      : out.replace(re, repl);
  }
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
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = redactDeep(v);
    return out as unknown as T;
  }
  return value;
}
