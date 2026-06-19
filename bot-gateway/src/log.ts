/**
 * Structured-log helpers with PII desensitization (AGENTS.md §Code style:
 * "用户标识用 hashUserId 脱敏").
 *
 * Feishu user/chat/message identifiers (open_chat_id, message_id, open_id) and
 * user-submitted question text are PII and must NOT reach stdout/CloudWatch in
 * the clear. hashUserId turns an identifier into a stable, non-reversible short
 * token so logs can still correlate events for one chat/user without exposing
 * who they are.
 *
 * Note: runtimeSessionId (a server-minted randomUUID, not user-derived) is a
 * safe correlation token and does not need hashing.
 */

import { createHash } from "node:crypto";

// Deployment salt so hashes can't be trivially rainbow-tabled across environments.
// Not a secret-grade control (logs are internal), just hygiene — but the fallback
// constant is PUBLIC (in the repo + AGENTS.md), so a missing env salt makes the
// known-format Feishu open_id hashes rainbow-tableable. We don't throw (this is an
// always-on gateway; a missing salt must not crash logging), but we WARN ONCE so
// the weakened de-identification is diagnosable rather than silent.
const SALT_FALLBACK = "source-truth";
const SALT = process.env.LOG_HASH_SALT ?? SALT_FALLBACK;
if (SALT === SALT_FALLBACK) {
  // eslint-disable-next-line no-console
  console.warn(JSON.stringify({
    event: "log_hash_salt_default",
    detail: "LOG_HASH_SALT unset — using the PUBLIC fallback salt; user-id hashes are weakly de-identified. Set LOG_HASH_SALT in the gateway env.",
  }));
}

/**
 * Stable, non-reversible short token for a user/chat/message identifier.
 * Empty/undefined → "anon" (so a missing id doesn't crash logging).
 */
export function hashUserId(id: string | undefined | null): string {
  if (!id) return "anon";
  return "u_" + createHash("sha256").update(SALT + ":" + id).digest("hex").slice(0, 12);
}
