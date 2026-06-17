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
