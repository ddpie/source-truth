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

// Optional deployment salt so hashes can't be trivially rainbow-tabled across
// environments. Not a secret-grade control (logs are internal), just hygiene.
const SALT = process.env.LOG_HASH_SALT ?? "source-truth";

/**
 * Stable, non-reversible short token for a user/chat/message identifier.
 * Empty/undefined → "anon" (so a missing id doesn't crash logging).
 */
export function hashUserId(id: string | undefined | null): string {
  if (!id) return "anon";
  return "u_" + createHash("sha256").update(SALT + ":" + id).digest("hex").slice(0, 12);
}
